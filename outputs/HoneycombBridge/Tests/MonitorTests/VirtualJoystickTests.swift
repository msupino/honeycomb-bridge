import XCTest
@testable import Monitor

final class VirtualJoystickTests: XCTestCase {
    func testCodecRoundTripAndRejects() throws {
        let s = VirtualJoysticks(alpha: .init(x: 1, y: 65535, hat: 8, buttons: 1 << 34),
                                 bravo: .init(axes: [0, 1, 2, 3, 4, 65535], buttons: 1 << 47),
                                 charlie: .init(leftBrake: 7, rightBrake: 8, rudder: 9))
        let data = s.encode(sequence: 42)
        XCTAssertEqual(data.count, VirtualJoysticks.length)
        let (seq, back) = try XCTUnwrap(VirtualJoysticks.decode(data))
        XCTAssertEqual(seq, 42); XCTAssertEqual(back, s)
        let partial = VirtualJoysticks(alpha: .init(), bravo: nil, charlie: nil)
        XCTAssertEqual(VirtualJoysticks.decode(partial.encode(sequence: 1))?.state, partial)
        XCTAssertNil(VirtualJoysticks.decode(data.dropLast()))
        var bad = [UInt8](data); bad[13] = 9                   // alpha hat out of range
        XCTAssertNil(VirtualJoysticks.decode(Data(bad)))
        bad = [UInt8](data); bad[0] = 0x58
        XCTAssertNil(VirtualJoysticks.decode(Data(bad)))
    }

    func testReportsMatchDescriptors() {
        let a = VirtualJoystickLayout.report(VirtualJoystickLayout.alpha, buttons: UInt64.max, hat: 3, axes: [65535, 0])
        // id + 5 button bytes (35 bits, top 5 masked) + hat + 2 axes
        XCTAssertEqual([UInt8](a), [1, 0xff, 0xff, 0xff, 0xff, 0x07, 3, 0xff, 0x0f, 0, 0])
        let c = VirtualJoystickLayout.report(VirtualJoystickLayout.charlie, buttons: 0, axes: [0, 32768, 65535])
        XCTAssertEqual([UInt8](c), [1, 0, 0, 0x00, 0x02, 0xff, 0x03])          // 0, 512, 1023
        XCTAssertEqual(VirtualJoystickLayout.report(VirtualJoystickLayout.bravo, buttons: 0, axes: []).count, 1 + 6 + 12)
        let d = [UInt8](VirtualJoystickLayout.alpha.descriptor)
        XCTAssertEqual(Array(d.prefix(8)), [0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01]); XCTAssertEqual(d.last, 0xC0)
    }

    func testMappingButtonsSwitchesSelectorAndAxes() throws {
        var bindings: [String: ControlBinding] = [:]
        for c in ControlCatalog.all { bindings[c.id] = ControlBinding(bit: c.knownBit ?? c.virtualBit, on: "", off: "") }
        bindings["alpha.left.trigger"]?.bit = 64; bindings["alpha.sw.master_bat"]?.bit = 1
        bindings["alpha.mag.right"]?.bit = 9; bindings["alpha.mag.left"]?.bit = 10; bindings["alpha.mag.both"]?.bit = 11; bindings["alpha.mag.start"]?.bit = 12
        bindings["bravo.gear.down"]?.bit = 43; bindings["bravo.ap.hdg"]?.bit = 17
        var p = [UInt8](repeating: 0, count: 43)
        p[0] = 0x01                     // bit 64 trigger
        p[3] = 0x02                     // bit 1 BAT on; ALT (bit 0, unbound here → off)
        p[1] = 0x03                     // hat up + down → treat as centred-ish; hat bits 72/73
        p[8] = 0x08                     // bit 43 gear down
        p[11] = 0x00; p[12] = 0x40      // roll +16384
        p[17] = 0xff; p[18] = 0xff      // lever 1 full
        p[20] = 0xff; p[19] = 0xc0      // lever 2 = 1023 (10-bit)
        let s = try XCTUnwrap(VirtualJoystickMapping.map(p, bindings: bindings, knobTarget: .alt, calibrations: [],
                                                         charlie: .rudder, charlieReversed: false))
        let a = try XCTUnwrap(s.alpha), b = try XCTUnwrap(s.bravo), c = try XCTUnwrap(s.charlie)
        XCTAssertNotEqual(a.buttons & 1 << 0, 0)                          // trigger
        XCTAssertNotEqual(a.buttons & 1 << 14, 0); XCTAssertEqual(a.buttons & 1 << 15, 0)   // BAT on
        XCTAssertNotEqual(a.buttons & 1 << 30, 0)                         // magneto OFF (derived)
        XCTAssertEqual(a.x, 0xC000)                                       // raw int16 16384 → offset binary
        XCTAssertNotEqual(b.buttons & 1 << 31, 0); XCTAssertEqual(b.buttons & 1 << 30, 0)   // gear down
        XCTAssertNotEqual(b.buttons & 1 << 20, 0)                         // selector ALT from knob target
        XCTAssertEqual(b.axes[0], 0xffff); XCTAssertEqual(b.axes[1], 0xffff)
        XCTAssertEqual(c.rudder, 32767)                                   // pedals untouched → centre
    }

    func testHatEightWay() throws {
        var bindings: [String: ControlBinding] = [:]
        for c in ControlCatalog.all { bindings[c.id] = ControlBinding(bit: c.knownBit, on: "", off: "") }
        func hat(_ byte1: UInt8) -> UInt8? {
            var p = [UInt8](repeating: 0, count: 43); p[1] = byte1
            return VirtualJoystickMapping.map(p, bindings: bindings, knobTarget: .hdg, calibrations: [], charlie: .brakes, charlieReversed: false)?.alpha?.hat
        }
        // bits 72 up, 73 down, 74 left, 75 right
        XCTAssertEqual(hat(0), 0); XCTAssertEqual(hat(0b0001), 1); XCTAssertEqual(hat(0b1001), 2); XCTAssertEqual(hat(0b1000), 3)
        XCTAssertEqual(hat(0b1010), 4); XCTAssertEqual(hat(0b0010), 5); XCTAssertEqual(hat(0b0110), 6); XCTAssertEqual(hat(0b0100), 7)
        XCTAssertEqual(hat(0b0101), 8)
    }
}
