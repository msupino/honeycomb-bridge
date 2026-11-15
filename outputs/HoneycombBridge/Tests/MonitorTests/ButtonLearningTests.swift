import XCTest
@testable import Monitor

final class ButtonLearningTests: XCTestCase {
    func testBitAddressing() {
        var p = [UInt8](repeating: 0, count: 43)
        p[7] = 0x08                                  // byte 7 bit 3 = bit 35
        XCTAssertTrue(ButtonBits.isSet(p, 35)); XCTAssertFalse(ButtonBits.isSet(p, 34))
        XCTAssertEqual(ButtonBits.changed([UInt8](repeating: 0, count: 43), p), [35])
        XCTAssertFalse(ButtonBits.isSet(p, 64))
    }
    func testLearnerPrefersSingleNewlySetBit() throws {
        var base = [UInt8](repeating: 0, count: 43); base[9] = 0x01   // bit 48 held
        let learner = ButtonLearner(controlID: "bravo.ap.hdg", baseline: base)
        XCTAssertNil(learner.detect(base))
        var p = base; p[5] = 0x04                    // bit 18 set
        XCTAssertEqual(learner.detect(p)?.bit, 18)
        p[9] = 0                                     // bit 48 cleared in same packet
        let found = try XCTUnwrap(learner.detect(p))
        XCTAssertEqual(found.bit, 18); XCTAssertEqual(found.others, [48])
    }
    func testCatalogIDsUniqueAndKnownBits() {
        let ids = ControlCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ControlCatalog.control("bravo.sw1")?.knownBit, 35)
        XCTAssertEqual(ControlCatalog.control("bravo.sw7")?.knownBit, 41)
        XCTAssertEqual(ControlCatalog.control("bravo.sw6")?.defaultOff, "sim/ice/pitot_heat0_off")
        XCTAssertEqual(ControlCatalog.control("bravo.lever6.detent")?.knownBit, 53)
    }
    func testExportFormat() {
        let text = ButtonMapExport.render([
            "bravo.sw1": ControlBinding(bit: 35, on: "sim/lights/beacon_lights_on", off: "sim/lights/beacon_lights_off", provisional: true),
            "bravo.ap.hdg": ControlBinding(bit: 18, on: "sim/autopilot/heading", off: "ignored"),
            "bravo.ap.nav": ControlBinding(bit: nil, on: "sim/autopilot/NAV", off: ""),
            "bravo.ap.apr": ControlBinding(bit: 20, on: "", off: ""),
        ])
        XCTAssertTrue(text.contains("35 sim/lights/beacon_lights_on sim/lights/beacon_lights_off   # Bravo BCN (provisional)"))
        XCTAssertTrue(text.contains("18 sim/autopilot/heading   # Bravo HDG"))
        XCTAssertFalse(text.contains("ignored")); XCTAssertFalse(text.contains("NAV")); XCTAssertFalse(text.contains("\n20 "))
    }
}
