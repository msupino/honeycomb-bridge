import Foundation
import Darwin

final class SimulatorSender: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Honeycomb.Simulator", qos: .userInteractive)
    private var payload: [UInt8]?
    private var mappings: [AxisCalibration] = []
    private var enabled = false
    private var sourceRunning = false
    private var descriptor: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private var lastAck = Date.distantPast
    private var lastMask: UInt32 = 0
    private var previousStatus = ""
    var onStatus: (@Sendable (String) -> Void)?

    init() {
        queue.async { [weak self] in
            guard let self else { return }
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            guard descriptor >= 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                if descriptor >= 0 { close(descriptor) }; self.onStatus?("Local bridge could not start"); return
            }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
            local.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { close(descriptor); self.onStatus?("Local bridge could not start"); return }
            self.descriptor = descriptor
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.send() }
            self.timer = timer; timer.resume()
        }
    }
    deinit { timer?.cancel(); if descriptor >= 0 { close(descriptor) } }
    func configure(_ mappings: [AxisCalibration], enabled: Bool) {
        lock.lock(); self.mappings = mappings; self.enabled = enabled; lock.unlock()
    }
    func setSourceRunning(_ running: Bool) {
        lock.lock(); sourceRunning = running; if !running { payload = nil }; lock.unlock()
    }
    func update(_ payload: [UInt8]) { lock.lock(); self.payload = payload; sourceRunning = true; lock.unlock() }
    private func send() {
        guard descriptor >= 0 else { return }
        lock.lock(); let latest = payload, definitions = mappings, active = enabled && sourceRunning; let outputEnabled = enabled; lock.unlock()
        sequence &+= 1
        var mask: UInt32 = 0, values = [Float](repeating: 0, count: FlightAxis.allCases.count), buttons: UInt64 = 0
        if active, let latest {
            for definition in definitions {
                if let value = definition.value(latest) { values[definition.axis.rawValue] = value; mask |= 1 << definition.axis.rawValue }
            }
            // Raw button/switch bits: payload bytes 3...10 -> bits 0...63 (mapped to commands by the plugin's buttons.txt).
            if latest.count >= 11 { for i in 0..<8 { buttons |= UInt64(latest[3 + i]) << (8 * i) }; mask |= 1 << 8 }
        }
        var packet = Data([72, 67, 66, 50]) // "HCB2"
        func append(_ value: UInt32) { var network = value.bigEndian; withUnsafeBytes(of: &network) { packet.append(contentsOf: $0) } }
        append(mask); append(sequence); append(0)
        for value in values { append(value.bitPattern) }
        append(UInt32(truncatingIfNeeded: buttons)); append(UInt32(truncatingIfNeeded: buttons >> 32))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(49876).bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                packet.withUnsafeBytes { Darwin.sendto(descriptor, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        for _ in 0..<64 {
            var reply = [UInt8](repeating: 0, count: 64), source = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    reply.withUnsafeMutableBytes { Darwin.recvfrom(descriptor, $0.baseAddress, $0.count, 0, address, &size) }
                }
            }
            if count < 0 { break }
            guard count == 12, source.sin_addr.s_addr == inet_addr("127.0.0.1"), source.sin_port == UInt16(49876).bigEndian,
                  Array(reply.prefix(4)) == [72, 67, 65, 49] else { continue }
            lastMask = reply[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; lastAck = Date()
        }
        let status: String
        if !outputEnabled { status = "X-Plane output off" }
        else if !active { status = "Waiting for device input" }
        else if Date().timeIntervalSince(lastAck) > 0.5 { status = "Waiting for X-Plane plugin" }
        else if lastMask == 0 { status = "Plugin found · enable its input menu" }
        else { status = "X-Plane accepting \((lastMask & 0xff).nonzeroBitCount) of \((mask & 0xff).nonzeroBitCount) axes\(lastMask & 0x100 != 0 ? " · buttons" : "")" }
        if status != previousStatus { previousStatus = status; onStatus?(status) }
    }
}
