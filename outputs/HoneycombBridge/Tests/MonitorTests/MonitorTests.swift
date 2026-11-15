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
}
