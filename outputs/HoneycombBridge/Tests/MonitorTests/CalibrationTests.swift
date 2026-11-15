import XCTest
@testable import Monitor

final class CalibrationTests: XCTestCase {
    func testSignedAxisLearningAndCenter() throws {
        let baseline = [UInt8](repeating: 0, count: 43)
        var learner = CalibrationLearner(axis: .roll, baseline: baseline)
        let travel = Array(stride(from: -30000, through: 30000, by: 1000))
        for value in travel + travel.reversed() {
            var payload = baseline
            let bits = UInt16(bitPattern: Int16(value))
            payload[11] = UInt8(truncatingIfNeeded: bits); payload[12] = UInt8(truncatingIfNeeded: bits >> 8)
            learner.accept(payload)
        }
        let mapping = try XCTUnwrap(learner.candidate())
        XCTAssertEqual(mapping.offset, 11); XCTAssertEqual(mapping.width, 2)
        XCTAssertTrue(mapping.signed); XCTAssertFalse(mapping.bigEndian)
        XCTAssertEqual(mapping.value(baseline), 0)
    }
    func testIndependentEightBitBrakeLearning() throws {
        let baseline = [UInt8](repeating: 0, count: 43)
        var learner = CalibrationLearner(axis: .leftBrake, baseline: baseline)
        for value in stride(from: 0, through: 255, by: 5) {
            var payload = baseline; payload[31] = UInt8(value); learner.accept(payload)
        }
        let mapping = try XCTUnwrap(learner.candidate())
        XCTAssertEqual(mapping.offset, 31); XCTAssertEqual(mapping.width, 1)
        XCTAssertEqual(mapping.value(baseline), 0)
        var pressed = baseline; pressed[31] = 255
        XCTAssertEqual(mapping.value(pressed), 1)
    }
    func testNoMovementAndBadCalibrationDoNotProduceInput() {
        let baseline = [UInt8](repeating: 0, count: 43)
        var learner = CalibrationLearner(axis: .yaw, baseline: baseline)
        for _ in 0..<20 { learner.accept(baseline) }
        XCTAssertNil(learner.candidate())
        let invalid = AxisCalibration(axis: .pitch, offset: 42, width: 2, signed: true, bigEndian: false, minimum: -1, maximum: 1, center: 0, inverted: false)
        XCTAssertNil(invalid.value(baseline))
    }
    func testPackedTenBitBravoLeverLearnsLinearly() throws {
        // Bravo levers: 10-bit value v stored as byte[o] = (v & 3) << 6, byte[o+1] = v >> 2.
        let baseline = [UInt8](repeating: 0, count: 43)
        XCTAssertEqual(FlightAxis.prop.group, "Bravo"); XCTAssertEqual(FlightAxis.mixture.group, "Bravo")
        var learner = CalibrationLearner(axis: .prop, baseline: baseline)
        func packed(_ v: Int) -> [UInt8] { var p = baseline; p[23] = UInt8((v & 3) << 6); p[24] = UInt8(v >> 2); return p }
        for v in stride(from: 0, through: 1023, by: 7) { learner.accept(packed(v)) }
        learner.accept(packed(1023))
        let mapping = try XCTUnwrap(learner.candidate())
        XCTAssertEqual(mapping.offset, 23); XCTAssertEqual(mapping.width, 2); XCTAssertFalse(mapping.bigEndian)
        XCTAssertEqual(try XCTUnwrap(mapping.value(packed(1023))), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(mapping.value(packed(512))), 0.5, accuracy: 0.01)
    }
}
