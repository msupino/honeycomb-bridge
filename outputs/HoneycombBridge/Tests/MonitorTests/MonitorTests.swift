import XCTest
@testable import Monitor

final class MonitorTests: XCTestCase {
    func testProtocolFiltering() throws {
        let good = Data("{\"event\":\"usb_packet\",\"endpoint\":129,\"hex\":\"2000012b\(String(repeating: "00", count: 43))\"}".utf8)
        XCTAssertEqual(InputState.payload(from: good), [UInt8](repeating: 0, count: 43))
        for hex in ["2000012b00", "2001012b" + String(repeating: "00", count: 43), "2020012b" + String(repeating: "00", count: 43), "zz"] {
            let line = try JSONSerialization.data(withJSONObject: ["event":"usb_packet", "endpoint":129, "hex":hex])
            XCTAssertNil(InputState.payload(from: line))
        }
    }
    func testGroupIsolationAndBaseline() {
        var state = InputState(), payload = [UInt8](repeating: 0, count: 43)
        state.accept(payload); state.tick()
        XCTAssertEqual(state.groups.map(\.changes), [0, 0, 0])
        payload[11] = 1; state.accept(payload); state.tick()
        payload[17] = 2; state.accept(payload); state.tick()
        payload[29] = 3; state.accept(payload); state.tick()
        XCTAssertEqual(state.groups.map(\.changes), [1, 1, 1])
        state.accept(payload); state.tick()
        XCTAssertEqual(state.groups.map(\.changes), [1, 1, 1])
        XCTAssertEqual(state.packets, 5)
    }
    func testControlsSnapshotDecodesRigLayout() {
        var p = [UInt8](repeating: 0, count: 43)
        p[11] = 0xff; p[12] = 0x7f            // roll +32767
        p[13] = 0x00; p[14] = 0x80            // pitch -32768
        p[17] = 0xc0; p[18] = 0xff            // lever 1 = 1023
        p[21] = 0x00; p[22] = 0x80            // lever 3 = 512
        p[29] = 0xc0; p[30] = 0xff            // left toe = 1023
        let c = ControlsSnapshot(payload: p, calibrations: [])
        XCTAssertEqual(c.roll, 1, accuracy: 1e-6); XCTAssertEqual(c.pitch, -1, accuracy: 1e-6)
        XCTAssertEqual(c.levers[0], 1, accuracy: 1e-6); XCTAssertEqual(c.levers[2], 512.0 / 1023, accuracy: 1e-6)
        XCTAssertEqual(c.leftBrake, 1, accuracy: 1e-6); XCTAssertEqual(c.rightBrake, 0)
        XCTAssertNil(c.rudder)
        let yaw = AxisCalibration(axis: .yaw, offset: 19, width: 2, signed: false, bigEndian: false, minimum: 0, maximum: 65535, center: 32768, inverted: false)
        XCTAssertNotNil(ControlsSnapshot(payload: p, calibrations: [yaw]).rudder)
    }
}
