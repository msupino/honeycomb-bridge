import CoreHID
import IOKit.hid
import Darwin
import Foundation

// Honeycomb Virtual HID: receives "HCV1" state from Honeycomb Monitor (127.0.0.1:49877) and presents the
// Alpha, Bravo and Charlie to macOS as PC-mode USB joysticks (CoreHID HIDVirtualDevice; needs the
// com.apple.developer.hid.virtual.device entitlement and its provisioning profile).
//
//   Honeycomb Virtual HID              run (normally started by Honeycomb Monitor)
//   Honeycomb Virtual HID --self-test  create the devices, sweep every axis and button for 10 s, exit

func log(_ s: String) { FileHandle.standardError.write(Data("[virtual-hid] \(s)\n".utf8)) }

final class Delegate: HIDVirtualDeviceDelegate {
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        Data([1] + [UInt8](repeating: 0, count: max(0, min(maxSize, 32) - 1)))
    }
}

/// One virtual device; created on first use, removed (like unplugging) after `staleAfter` without input.
final class VirtualUnit {
    let layout: VirtualJoystickLayout.Device
    let location: UInt64
    private var device: HIDVirtualDevice?
    private var lastReport: Data?
    private var lastSent = ContinuousClock.now
    init(_ layout: VirtualJoystickLayout.Device, location: UInt64) { self.layout = layout; self.location = location }

    func send(_ report: Data) async {
        if device == nil {
            let props = HIDVirtualDevice.Properties(descriptor: layout.descriptor, vendorID: VirtualJoystickLayout.vendorID, productID: layout.productID,
                                                    transport: .usb, product: layout.product, manufacturer: "Honeycomb Aeronautical",
                                                    serialNumber: "HCB-VIRTUAL-\(String(layout.productID, radix: 16))", locationID: location)
            guard let d = HIDVirtualDevice(properties: props) else { log("could not create \(layout.product) (entitlement or profile missing?)"); return }
            await d.activate(delegate: Delegate())
            device = d; lastReport = nil; log("\(layout.product) connected")
        }
        // Send on change, and at least every 100 ms so readers that poll stay current.
        guard report != lastReport || ContinuousClock.now - lastSent > .milliseconds(100), let device else { return }
        do { try await device.dispatchInputReport(data: report, timestamp: .now); lastReport = report; lastSent = .now }
        catch { log("\(layout.product) report failed: \(error)") }
    }
    func remove() { if device != nil { device = nil; log("\(layout.product) disconnected") } }
}

let units = (alpha: VirtualUnit(VirtualJoystickLayout.alpha, location: 0x4843_0001),
             bravo: VirtualUnit(VirtualJoystickLayout.bravo, location: 0x4843_0002),
             charlie: VirtualUnit(VirtualJoystickLayout.charlie, location: 0x4843_0003))

@MainActor func apply(_ s: VirtualJoysticks) async {
    let r = VirtualJoystickLayout.reports(s)
    if let a = r.alpha { await units.alpha.send(a) } else { units.alpha.remove() }
    if let b = r.bravo { await units.bravo.send(b) } else { units.bravo.remove() }
    if let c = r.charlie { await units.charlie.send(c) } else { units.charlie.remove() }
}
@MainActor func removeAll() { units.alpha.remove(); units.bravo.remove(); units.charlie.remove() }

// Virtual HID devices need the "post events" privacy permission (System Settings → Privacy & Security →
// Accessibility). Ask once; macOS shows the prompt and remembers the answer for this app.
if IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted {
    log("requesting permission to post input events (Privacy & Security → Accessibility)")
    if !IOHIDRequestAccess(kIOHIDRequestTypePostEvent) {
        log("permission not granted yet: enable Honeycomb Virtual HID in System Settings → Privacy & Security → Accessibility, then restart virtual joysticks")
    }
}

if CommandLine.arguments.contains("--self-test") {
    log("self-test: 10 s sweep")
    let start = ContinuousClock.now
    var i = 0
    while ContinuousClock.now - start < .seconds(10) {
        let v = UInt16((i * 400) % 65536), n = i / 10
        await apply(VirtualJoysticks(alpha: .init(x: v, y: 65535 - v, hat: UInt8(n % 9), buttons: 1 << UInt64(n % 35)),
                                     bravo: .init(axes: Array(repeating: v, count: 6), buttons: 1 << UInt64(n % 48)),
                                     charlie: .init(leftBrake: v, rightBrake: 65535 - v, rudder: v)))
        i += 1; try? await Task.sleep(for: .milliseconds(10))
    }
    removeAll(); log("self-test done"); exit(0)
}

// Receive loop
let fd = socket(AF_INET, SOCK_DGRAM, 0)
var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
address.sin_port = VirtualJoysticks.port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard fd >= 0, bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { log("cannot listen on 127.0.0.1:\(VirtualJoysticks.port) (errno \(errno))"); exit(1) }
log("listening on 127.0.0.1:\(VirtualJoysticks.port)")

var lastPacket = ContinuousClock.now, connected = false
let staleAfter: Duration = .seconds(2), quitAfter: Duration = .seconds(60)
var buffer = [UInt8](repeating: 0, count: 256)
while true {
    var latest: VirtualJoysticks?
    while true {
        var source = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &source) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) } }
        if n < 0 { break }
        guard source.sin_addr.s_addr == inet_addr("127.0.0.1"), let (_, s) = VirtualJoysticks.decode(Data(buffer[0..<n])) else { continue }
        latest = s
    }
    if let latest { lastPacket = .now; connected = true; await apply(latest) }
    else if connected && ContinuousClock.now - lastPacket > staleAfter { removeAll(); connected = false }
    else if !connected && ContinuousClock.now - lastPacket > quitAfter { log("no input for \(quitAfter); exiting"); exit(0) }
    try? await Task.sleep(for: .milliseconds(2))
}
