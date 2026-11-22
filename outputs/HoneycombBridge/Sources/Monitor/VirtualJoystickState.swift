import Foundation

/// State of the three virtual PC-mode joysticks that the Honeycomb Virtual HID helper presents to macOS
/// (CoreHID HIDVirtualDevice), so simulators see the original USB devices:
/// Alpha 294B:1900, Bravo 294B:1901, Charlie 294B:1903.
///
/// Honeycomb Monitor sends it to the helper as one "HCV1" datagram per tick on 127.0.0.1:49877
/// (little-endian):
///   "HCV1", u32 sequence,
///   u8 alpha present,   u16 x, u16 y, u8 hat (0 = centred, 1…8 = N, NE, E, … NW), u64 buttons (PC 0…34),
///   u8 bravo present,   6 × u16 lever axes, u64 buttons (PC 0…47),
///   u8 charlie present, u16 left brake, u16 right brake, u16 rudder.
/// Axis values are 0…65535 (rudder centre 32768); the helper scales them to each device's logical range.
/// This file is shared by the monitor and the helper app.
struct VirtualJoysticks: Equatable {
    struct Alpha: Equatable { var x: UInt16 = 32768, y: UInt16 = 32768; var hat: UInt8 = 0; var buttons: UInt64 = 0 }
    struct Bravo: Equatable { var axes = [UInt16](repeating: 0, count: 6); var buttons: UInt64 = 0 }
    struct Charlie: Equatable { var leftBrake: UInt16 = 0, rightBrake: UInt16 = 0, rudder: UInt16 = 32768 }
    var alpha: Alpha?
    var bravo: Bravo?
    var charlie: Charlie?

    static let port: UInt16 = 49877
    static let length = 8 + (1 + 2 + 2 + 1 + 8) + (1 + 12 + 8) + (1 + 6)

    func encode(sequence: UInt32) -> Data {
        var d = Data("HCV1".utf8)
        func u8(_ v: UInt8) { d.append(v) }
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        func u64(_ v: UInt64) { for i in 0..<8 { d.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        u32(sequence)
        let a = alpha ?? Alpha(); u8(alpha == nil ? 0 : 1); u16(a.x); u16(a.y); u8(a.hat); u64(a.buttons)
        let b = bravo ?? Bravo(); u8(bravo == nil ? 0 : 1); for i in 0..<6 { u16(i < b.axes.count ? b.axes[i] : 0) }; u64(b.buttons)
        let c = charlie ?? Charlie(); u8(charlie == nil ? 0 : 1); u16(c.leftBrake); u16(c.rightBrake); u16(c.rudder)
        return d
    }

    static func decode(_ data: Data) -> (sequence: UInt32, state: VirtualJoysticks)? {
        let p = [UInt8](data)
        guard p.count == length, Array(p[0..<4]) == Array("HCV1".utf8) else { return nil }
        var i = 4
        func u8() -> UInt8 { defer { i += 1 }; return p[i] }
        func u16() -> UInt16 { defer { i += 2 }; return UInt16(p[i]) | UInt16(p[i + 1]) << 8 }
        func u32() -> UInt32 { defer { i += 4 }; return (0..<4).reduce(0) { $0 | UInt32(p[i + $1]) << (8 * $1) } }
        func u64() -> UInt64 { defer { i += 8 }; return (0..<8).reduce(0) { $0 | UInt64(p[i + $1]) << (8 * $1) } }
        let sequence = u32()
        var s = VirtualJoysticks()
        let ap = u8(); let a = Alpha(x: u16(), y: u16(), hat: u8(), buttons: u64())
        if ap == 1 { s.alpha = a } else if ap != 0 { return nil }
        if a.hat > 8 { return nil }
        let bp = u8(); let b = Bravo(axes: (0..<6).map { _ in u16() }, buttons: u64())
        if bp == 1 { s.bravo = b } else if bp != 0 { return nil }
        let cp = u8(); let c = Charlie(leftBrake: u16(), rightBrake: u16(), rudder: u16())
        if cp == 1 { s.charlie = c } else if cp != 0 { return nil }
        return (sequence, s)
    }
}

/// HID report descriptors and input reports for the virtual devices. Elements follow the PC-mode
/// devices (usage pages, usages, button counts, logical ranges); the byte layout is this project's own.
/// Report ID 1: [1] [buttons, 1 bit each, padded to a byte] [hat nibble + pad, Alpha only] [axes, u16 LE].
enum VirtualJoystickLayout {
    struct Device {
        let productID: UInt32
        let product: String
        let buttons: Int
        let hat: Bool
        let axisUsages: [UInt8]
        let logicalMax: UInt16
        var descriptor: Data { VirtualJoystickLayout.descriptor(self) }
    }
    static let alpha = Device(productID: 0x1900, product: "Alpha Flight Controls", buttons: 35, hat: true, axisUsages: [0x30, 0x31], logicalMax: 4095)
    static let bravo = Device(productID: 0x1901, product: "Bravo Throttle Quadrant", buttons: 48, hat: false, axisUsages: [0x30, 0x31, 0x32, 0x33, 0x34, 0x35], logicalMax: 4095)
    static let charlie = Device(productID: 0x1903, product: "Charlie Rudder Pedal", buttons: 0, hat: false, axisUsages: [0x30, 0x31, 0x32], logicalMax: 1023)
    static let vendorID: UInt32 = 0x294B

    static func descriptor(_ d: Device) -> Data {
        var b: [UInt8] = [0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01]
        if d.buttons > 0 {
            b += [0x05, 0x09, 0x19, 0x01, 0x29, UInt8(d.buttons), 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, UInt8(d.buttons), 0x81, 0x02]
            if d.buttons % 8 != 0 { b += [0x75, 0x01, 0x95, UInt8(8 - d.buttons % 8), 0x81, 0x03] }
        }
        if d.hat {
            b += [0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
                  0x65, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03]
        }
        b += [0x05, 0x01, 0x15, 0x00, 0x26, UInt8(d.logicalMax & 0xff), UInt8(d.logicalMax >> 8), 0x75, 0x10, 0x95, UInt8(d.axisUsages.count)]
        for u in d.axisUsages { b += [0x09, u] }
        b += [0x81, 0x02, 0xC0]
        return Data(b)
    }

    /// Input report for one device; axis values 0…65535 are scaled to the device's logical range.
    static func report(_ d: Device, buttons: UInt64, hat: UInt8 = 0, axes: [UInt16]) -> Data {
        var r: [UInt8] = [1]
        let bytes = (d.buttons + 7) / 8
        for i in 0..<bytes { r.append(UInt8(truncatingIfNeeded: buttons >> (8 * i))) }
        if d.buttons % 8 != 0, bytes > 0 { r[bytes] &= UInt8((1 << (d.buttons % 8)) - 1) }
        if d.hat { r.append(hat <= 8 ? hat : 0) }
        for i in 0..<d.axisUsages.count {
            let v = i < axes.count ? axes[i] : 0
            let scaled = UInt16((UInt32(v) * UInt32(d.logicalMax) + 32767) / 65535)
            r.append(UInt8(scaled & 0xff)); r.append(UInt8(scaled >> 8))
        }
        return Data(r)
    }

    static func reports(_ s: VirtualJoysticks) -> (alpha: Data?, bravo: Data?, charlie: Data?) {
        (s.alpha.map { report(alpha, buttons: $0.buttons, hat: $0.hat, axes: [$0.x, $0.y]) },
         s.bravo.map { report(bravo, buttons: $0.buttons, axes: $0.axes) },
         s.charlie.map { report(charlie, buttons: 0, axes: [$0.leftBrake, $0.rightBrake, $0.rudder]) })
    }
}
