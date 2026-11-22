import AppKit
import Darwin

/// Sends the virtual joystick state to the Honeycomb Virtual HID helper at 125 Hz and starts/stops the helper app.
final class VirtualJoystickSender: @unchecked Sendable {
    static let helperBundleID = "org.supino.honeycomb-vhid-test"
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Honeycomb.VirtualHID", qos: .userInteractive)
    private var state: VirtualJoysticks?
    private var enabled = false
    private var descriptor: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0

    init() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { if fd >= 0 { close(fd) }; return }
            self.descriptor = fd
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.send() }
            self.timer = timer; timer.resume()
        }
    }
    deinit { timer?.cancel(); if descriptor >= 0 { close(descriptor) } }

    func setEnabled(_ on: Bool) { lock.lock(); enabled = on; if !on { state = nil }; lock.unlock() }
    func update(_ s: VirtualJoysticks?) { lock.lock(); state = s; lock.unlock() }

    private func send() {
        lock.lock(); let s = state, on = enabled; lock.unlock()
        guard on, let s, descriptor >= 0 else { return }
        sequence &+= 1
        let packet = s.encode(sequence: sequence)
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET); target.sin_port = VirtualJoysticks.port.bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                packet.withUnsafeBytes { Darwin.sendto(descriptor, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    /// The helper ships inside the monitor (Contents/Helpers); a development build next to the project also works.
    static var helperURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Honeycomb Virtual HID.app")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: helperBundleID)
    }
    static func launchHelper(_ done: @escaping @Sendable (String?) -> Void) {
        guard let url = helperURL else { done("Honeycomb Virtual HID helper not found. Rebuild with build-monitor.sh."); return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in done(error?.localizedDescription) }
    }
    static func stopHelper() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID) { app.forceTerminate() }  // background tool without an AppKit run loop
    }
}
