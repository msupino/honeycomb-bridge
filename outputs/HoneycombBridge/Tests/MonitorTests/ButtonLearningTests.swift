import XCTest
@testable import Monitor

final class ButtonLearningTests: XCTestCase {
    func testBitAddressing() {
        var p = [UInt8](repeating: 0, count: 43)
        p[7] = 0x08                                  // byte 7 bit 3 = bit 35
        XCTAssertTrue(ButtonBits.isSet(p, 35)); XCTAssertFalse(ButtonBits.isSet(p, 34))
        XCTAssertEqual(ButtonBits.changed([UInt8](repeating: 0, count: 43), p), [35])
        XCTAssertFalse(ButtonBits.isSet(p, 64))
        p[1] = 0x01; p[2] = 0x02                     // byte 1 bit 0 = bit 72, byte 2 bit 1 = bit 81
        XCTAssertTrue(ButtonBits.isSet(p, 72)); XCTAssertTrue(ButtonBits.isSet(p, 81)); XCTAssertFalse(ButtonBits.isSet(p, 88))
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

final class GroupLearningTests: XCTestCase {
    private func payload(_ bits: [Int]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 43)
        for b in bits { p[3 + b / 8] |= 1 << UInt8(b % 8) }
        return p
    }
    func testMagnetoSweepAssignsEachPosition() throws {
        let group = try XCTUnwrap(ControlGroup.all.first { $0.id == "alpha.magneto" })
        var learner = GroupLearner(group: group, baseline: payload([4, 11]))            // OFF bit 4 held, 11 unrelated
        for step in [[5, 11], [6, 11], [7, 11], [7, 8, 11], [7, 11]] { learner.accept(payload(step)) } // R, L, BOTH, START, release
        let map = try XCTUnwrap(learner.assignment())
        XCTAssertEqual(map["alpha.mag.off"], 4); XCTAssertEqual(map["alpha.mag.right"], 5)
        XCTAssertEqual(map["alpha.mag.left"], 6); XCTAssertEqual(map["alpha.mag.both"], 7); XCTAssertEqual(map["alpha.mag.start"], 8)
    }
    func testMagnetoOffLearnedOnReturn() throws {
        let group = try XCTUnwrap(ControlGroup.all.first { $0.id == "alpha.magneto" })
        var learner = GroupLearner(group: group, baseline: payload([]))                  // OFF reports nothing at start
        for step in [[5], [6], [7], [8], [7], [6], [5], [], [4]] { learner.accept(payload(step)) } // R L BOTH START back… OFF
        let map = try XCTUnwrap(learner.assignment())
        XCTAssertEqual(map["alpha.mag.right"], 5); XCTAssertEqual(map["alpha.mag.start"], 8); XCTAssertEqual(map["alpha.mag.off"], 4)
    }
    func testMagnetoOffIsDerivedBit63() {
        let b: [String: ControlBinding] = ["alpha.mag.right": .init(bit: 9, on: "", off: ""), "alpha.mag.left": .init(bit: 10, on: "", off: ""),
                                           "alpha.mag.both": .init(bit: 11, on: "", off: ""), "alpha.mag.start": .init(bit: 12, on: "", off: "")]
        XCTAssertTrue(ButtonBits.isSet(VirtualBits.apply(payload([35]), b), 63))      // key at OFF: none of 9–12
        XCTAssertFalse(ButtonBits.isSet(VirtualBits.apply(payload([10]), b), 63))     // key at L
        XCTAssertFalse(ButtonBits.isSet(VirtualBits.apply(payload([]), [:]), 63))      // not learned yet: never set
    }
    func testFirstPositionWithoutBitAndMismatch() throws {
        let group = try XCTUnwrap(ControlGroup.all.first { $0.id == "bravo.selector" })
        var learner = GroupLearner(group: group, baseline: payload([]))
        for step in [[20], [21], [22], [23]] { learner.accept(payload(step)) }
        let map = try XCTUnwrap(learner.assignment())
        XCTAssertNil(map["bravo.sel.alt"]); XCTAssertEqual(map["bravo.sel.vs"], 20); XCTAssertEqual(map["bravo.sel.ias"], 23)
        var short = GroupLearner(group: group, baseline: payload([]))
        short.accept(payload([20]))
        XCTAssertNil(short.assignment())
    }
}
