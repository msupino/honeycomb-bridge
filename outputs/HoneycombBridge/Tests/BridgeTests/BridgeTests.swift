import XCTest
@testable import Bridge

final class BridgeTests: XCTestCase {
    func event(_ value: Int, kind: String = "value") throws -> Event {
        try JSONDecoder().decode(Event.self, from: Data("""
        {"event":"\(kind)","device":{"registry_id":123},"cookie":7,"usage_page":1,"usage":48,"logical_min":0,"logical_max":100,"value":\(value)}
        """.utf8))
    }
    func testObservedRangeClampingAndDisconnect() throws {
        let binding = Binding(registryID: 123, usagePage: 1, usage: 48, cookie: 7, kind: "axis", index: 0, invert: false)
        var mapper = try Mapper(bindings: [binding])
        XCTAssertTrue(try mapper.accept(event(0)))
        XCTAssertEqual(mapper.state.axes[0], -32767)
        XCTAssertFalse(try mapper.accept(event(-10)))
        XCTAssertTrue(try mapper.accept(event(200)))
        XCTAssertEqual(mapper.state.axes[0], 32767)
        XCTAssertTrue(try mapper.accept(event(0, kind: "hid_removed")))
        XCTAssertEqual(mapper.state, State())
    }
    func testSourceIsolationAndButton32() throws {
        var mapper = try Mapper(bindings: [Binding(registryID: 456, usagePage: 1, usage: 48, cookie: 7, kind: "button", index: 31, invert: false)])
        XCTAssertFalse(try mapper.accept(event(1)))
        mapper = try Mapper(bindings: [Binding(registryID: 123, usagePage: 1, usage: 48, cookie: 7, kind: "button", index: 31, invert: false)])
        XCTAssertTrue(try mapper.accept(event(1)))
        XCTAssertEqual(mapper.state.buttons, 0x80000000)
        XCTAssertEqual(Array(mapper.state.report.suffix(4)), [0, 0, 0, 128])
    }
    func testProbeBooleanCompatibility() throws {
        for (json, expected) in [("0", false), ("1", true), ("false", false), ("true", true)] {
            let flag = try JSONDecoder().decode(HIDFlag.self, from: Data(json.utf8))
            XCTAssertEqual(flag.value, expected)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(HIDFlag.self, from: Data("2".utf8)))
    }
    func testReportLayout() {
        var state = State(); state.axes[0] = -32767; state.axes[7] = 32767; state.buttons = 0x80000001
        XCTAssertEqual(state.report.count, 20)
        XCTAssertEqual(Array(state.report.prefix(2)), [1, 128])
        XCTAssertEqual(Array(state.report[14..<20]), [255, 127, 1, 0, 0, 128])
    }
    func testInvalidMappingAndRange() throws {
        let b = Binding(registryID: 123, usagePage: 1, usage: 48, cookie: 7, kind: "axis", index: 0, invert: false)
        XCTAssertThrowsError(try Mapper(bindings: [b, b]))
        var mapper = try Mapper(bindings: [b])
        let bad = try JSONDecoder().decode(Event.self, from: Data("""
        {"event":"value","device":{"registry_id":123},"cookie":7,"usage_page":1,"usage":48,"logical_min":1,"logical_max":1,"value":1}
        """.utf8))
        XCTAssertThrowsError(try mapper.accept(bad))
    }
}
