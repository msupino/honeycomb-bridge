import Foundation

/// A physical button, switch position or detent on the Alpha XPC or Bravo.
/// In Xbox mode each is one bit of payload bytes 3...10 (bit n = byte 3 + n/8, bit n % 8), learned per control.
enum ControlKind: String, Codable {
    case momentary   // pressed while held (buttons, hat directions, encoder ticks, flaps/trim)
    case toggle      // two-position switch: bit set = "on" position, bound to on/off commands
    case position    // one position of a multi-position selector (magneto, AP selector, gear lever)
}

struct HardwareControl: Identifiable, Hashable {
    let id: String
    let device: Device
    let label: String
    let kind: ControlKind
    var defaultOn = ""
    var defaultOff = ""
    var knownBit: Int? = nil   // provisional bit from captures (see BRAVO-BUTTONS.md)
    /// Derived control: the app sets `virtualBit` while none of `virtualOf` controls' bits are set
    /// (the magneto OFF position reports no bit of its own). Byte 10 never changes on the rig, so bit 63 is free.
    var virtualBit: Int? = nil
    var virtualOf: [String] = []
    enum Device: String, CaseIterable, Identifiable { case alpha = "Alpha", bravo = "Bravo", charlie = "Charlie"; var id: String { rawValue } }
}

enum ControlCatalog {
    static let all: [HardwareControl] = alpha + bravo
    static func control(_ id: String) -> HardwareControl? { all.first { $0.id == id } }

    // Alpha XPC (layout per FlightGear's Honeycomb Alpha bindings): left grip = trigger, white top button,
    // hat, outer and inner up/down rockers; right grip = white and red top buttons, top and bottom
    // in/out rockers. Base: 9 two-position switches and the 5-position magneto key.
    static let alpha: [HardwareControl] = [
        .init(id: "alpha.hat.up", device: .alpha, label: "Hat ↑", kind: .momentary, defaultOn: "sim/general/hat_switch_up", knownBit: 72),
        .init(id: "alpha.hat.down", device: .alpha, label: "Hat ↓", kind: .momentary, defaultOn: "sim/general/hat_switch_down", knownBit: 73),
        .init(id: "alpha.hat.left", device: .alpha, label: "Hat ←", kind: .momentary, defaultOn: "sim/general/hat_switch_left", knownBit: 74),
        .init(id: "alpha.hat.right", device: .alpha, label: "Hat →", kind: .momentary, defaultOn: "sim/general/hat_switch_right", knownBit: 75),
        .init(id: "alpha.left.trigger", device: .alpha, label: "Trigger", kind: .momentary, defaultOn: "sim/autopilot/servos_off_any"),
        .init(id: "alpha.left.white", device: .alpha, label: "L white", kind: .momentary),
        .init(id: "alpha.left.outer.up", device: .alpha, label: "Outer ↑", kind: .momentary, defaultOn: "sim/flight_controls/pitch_trim_down"),
        .init(id: "alpha.left.outer.down", device: .alpha, label: "Outer ↓", kind: .momentary, defaultOn: "sim/flight_controls/pitch_trim_up"),
        .init(id: "alpha.left.inner.up", device: .alpha, label: "Inner ↑", kind: .momentary, defaultOn: "sim/general/zoom_in"),
        .init(id: "alpha.left.inner.down", device: .alpha, label: "Inner ↓", kind: .momentary, defaultOn: "sim/general/zoom_out"),
        .init(id: "alpha.right.white", device: .alpha, label: "R white", kind: .momentary),
        .init(id: "alpha.right.red", device: .alpha, label: "R red", kind: .momentary),
        .init(id: "alpha.right.top.in", device: .alpha, label: "Top ◀ in", kind: .momentary, defaultOn: "sim/flight_controls/aileron_trim_left"),
        .init(id: "alpha.right.top.out", device: .alpha, label: "Top out ▶", kind: .momentary, defaultOn: "sim/flight_controls/aileron_trim_right"),
        .init(id: "alpha.right.bottom.in", device: .alpha, label: "Bottom ◀ in", kind: .momentary, defaultOn: "sim/flight_controls/rudder_trim_left"),
        .init(id: "alpha.right.bottom.out", device: .alpha, label: "Bottom out ▶", kind: .momentary, defaultOn: "sim/flight_controls/rudder_trim_right"),
        .init(id: "alpha.sw.master_alt", device: .alpha, label: "ALT", kind: .toggle, defaultOn: "sim/electrical/generator_1_on", defaultOff: "sim/electrical/generator_1_off"),
        .init(id: "alpha.sw.master_bat", device: .alpha, label: "BAT", kind: .toggle, defaultOn: "sim/electrical/battery_1_on", defaultOff: "sim/electrical/battery_1_off"),
        .init(id: "alpha.sw.avionics1", device: .alpha, label: "AV BUS 1", kind: .toggle, defaultOn: "sim/systems/avionics_on", defaultOff: "sim/systems/avionics_off"),
        .init(id: "alpha.sw.avionics2", device: .alpha, label: "AV BUS 2", kind: .toggle),
        .init(id: "alpha.sw.beacon", device: .alpha, label: "BCN", kind: .toggle, defaultOn: "sim/lights/beacon_lights_on", defaultOff: "sim/lights/beacon_lights_off"),
        .init(id: "alpha.sw.land", device: .alpha, label: "LAND", kind: .toggle, defaultOn: "sim/lights/landing_lights_on", defaultOff: "sim/lights/landing_lights_off"),
        .init(id: "alpha.sw.taxi", device: .alpha, label: "TAXI", kind: .toggle, defaultOn: "sim/lights/taxi_lights_on", defaultOff: "sim/lights/taxi_lights_off"),
        .init(id: "alpha.sw.nav", device: .alpha, label: "NAV", kind: .toggle, defaultOn: "sim/lights/nav_lights_on", defaultOff: "sim/lights/nav_lights_off"),
        .init(id: "alpha.sw.strobe", device: .alpha, label: "STROBE", kind: .toggle, defaultOn: "sim/lights/strobe_lights_on", defaultOff: "sim/lights/strobe_lights_off"),
        .init(id: "alpha.mag.off", device: .alpha, label: "OFF", kind: .position, defaultOn: "sim/magnetos/magnetos_off_1",
              virtualBit: 63, virtualOf: ["alpha.mag.right", "alpha.mag.left", "alpha.mag.both", "alpha.mag.start"]),
        .init(id: "alpha.mag.right", device: .alpha, label: "R", kind: .position, defaultOn: "sim/magnetos/magnetos_right_1"),
        .init(id: "alpha.mag.left", device: .alpha, label: "L", kind: .position, defaultOn: "sim/magnetos/magnetos_left_1"),
        .init(id: "alpha.mag.both", device: .alpha, label: "BOTH", kind: .position, defaultOn: "sim/magnetos/magnetos_both_1"),
        .init(id: "alpha.mag.start", device: .alpha, label: "START", kind: .momentary, defaultOn: "sim/starters/engage_starter_1"),
    ]

    // Bravo: autopilot row, selector + encoder, six levers with detents and lever buttons,
    // flaps lever, trim wheel, gear lever and seven toggle switches.
    static let bravo: [HardwareControl] = [
        .init(id: "bravo.ap.hdg", device: .bravo, label: "HDG", kind: .momentary, defaultOn: "sim/autopilot/heading"),
        .init(id: "bravo.ap.nav", device: .bravo, label: "NAV", kind: .momentary, defaultOn: "sim/autopilot/NAV"),
        .init(id: "bravo.ap.apr", device: .bravo, label: "APR", kind: .momentary, defaultOn: "sim/autopilot/approach"),
        .init(id: "bravo.ap.rev", device: .bravo, label: "REV", kind: .momentary, defaultOn: "sim/autopilot/back_course"),
        .init(id: "bravo.ap.alt", device: .bravo, label: "ALT", kind: .momentary, defaultOn: "sim/autopilot/altitude_hold"),
        .init(id: "bravo.ap.vs", device: .bravo, label: "VS", kind: .momentary, defaultOn: "sim/autopilot/vertical_speed"),
        .init(id: "bravo.ap.ias", device: .bravo, label: "IAS", kind: .momentary, defaultOn: "sim/autopilot/level_change"),
        .init(id: "bravo.ap.master", device: .bravo, label: "AUTOPILOT", kind: .momentary, defaultOn: "sim/autopilot/servos_toggle"),
        .init(id: "bravo.sel.alt", device: .bravo, label: "ALT", kind: .position),
        .init(id: "bravo.sel.vs", device: .bravo, label: "VS", kind: .position),
        .init(id: "bravo.sel.hdg", device: .bravo, label: "HDG", kind: .position),
        .init(id: "bravo.sel.crs", device: .bravo, label: "CRS", kind: .position),
        .init(id: "bravo.sel.ias", device: .bravo, label: "IAS", kind: .position),
        .init(id: "bravo.knob.inc", device: .bravo, label: "Knob +", kind: .momentary, defaultOn: "sim/autopilot/heading_up"),
        .init(id: "bravo.knob.dec", device: .bravo, label: "Knob −", kind: .momentary, defaultOn: "sim/autopilot/heading_down"),
        .init(id: "bravo.flaps.down", device: .bravo, label: "Flaps ↓", kind: .momentary, defaultOn: "sim/flight_controls/flaps_down"),
        .init(id: "bravo.flaps.up", device: .bravo, label: "Flaps ↑", kind: .momentary, defaultOn: "sim/flight_controls/flaps_up"),
        .init(id: "bravo.trim.down", device: .bravo, label: "Trim fwd", kind: .momentary, defaultOn: "sim/flight_controls/pitch_trim_down"),
        .init(id: "bravo.trim.up", device: .bravo, label: "Trim back", kind: .momentary, defaultOn: "sim/flight_controls/pitch_trim_up"),
        .init(id: "bravo.gear.up", device: .bravo, label: "Gear UP", kind: .position, defaultOn: "sim/flight_controls/landing_gear_up"),
        .init(id: "bravo.gear.down", device: .bravo, label: "Gear DN", kind: .position, defaultOn: "sim/flight_controls/landing_gear_down"),
    ] + (1...6).map { n in
        HardwareControl(id: "bravo.lever\(n).detent", device: .bravo, label: "L\(n) detent", kind: .momentary, knownBit: 47 + n)
    } + [
        .init(id: "bravo.lever1.a", device: .bravo, label: "L1 A", kind: .momentary),
        .init(id: "bravo.lever2.a", device: .bravo, label: "L2 A", kind: .momentary),
        .init(id: "bravo.lever2.b", device: .bravo, label: "L2 B", kind: .momentary),
        .init(id: "bravo.lever3.a", device: .bravo, label: "L3 A", kind: .momentary),
        .init(id: "bravo.lever3.b", device: .bravo, label: "L3 B", kind: .momentary),
        .init(id: "bravo.lever4.a", device: .bravo, label: "L4 A", kind: .momentary),
        .init(id: "bravo.lever4.b", device: .bravo, label: "L4 B", kind: .momentary),
        .init(id: "bravo.lever5.a", device: .bravo, label: "L5 A", kind: .momentary),
    ] + zip(1...7, [("beacon", "BCN"), ("landing", "LAND"), ("taxi", "TAXI"), ("nav", "NAV"), ("strobe", "STROBE"), ("pitot", "PITOT"), ("avionics", "AVIONICS")]).map { n, s in
        let on = s.0 == "pitot" ? "sim/ice/pitot_heat0_on" : s.0 == "avionics" ? "sim/systems/avionics_on" : "sim/lights/\(s.0)_lights_on"
        return HardwareControl(id: "bravo.sw\(n)", device: .bravo, label: s.1, kind: .toggle, defaultOn: on,
                               defaultOff: on.replacingOccurrences(of: "_on", with: "_off"), knownBit: 34 + n)
    }
}

/// A learned bit plus the X-Plane command(s) for one control.
struct ControlBinding: Codable, Equatable {
    var bit: Int?
    var on: String
    var off: String
    var provisional = false
}

enum ButtonBits {
    /// Bits 0–63: payload bytes 3–10 (FlightStick extra buttons). Bits 64–87: payload bytes 0–2
    /// (navigation buttons, d-pad/hat, fire buttons).
    static let count = 88
    static func byteIndex(_ bit: Int) -> Int { bit < 64 ? 3 + bit / 8 : (bit - 64) / 8 }
    static func isSet(_ payload: [UInt8], _ bit: Int) -> Bool {
        guard (0..<count).contains(bit), payload.count > byteIndex(bit) else { return false }
        return payload[byteIndex(bit)] & (1 << UInt8(bit % 8)) != 0
    }
    /// Bits that differ between two payloads, lowest first.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
        (0..<count).filter { isSet(a, $0) != isSet(b, $0) }
    }
}

/// Watches payloads after "Learn" and picks the first bit that changes from the baseline.
struct ButtonLearner {
    let controlID: String
    let baseline: [UInt8]
    /// Returns the changed bits once any change. With several, a single newly *set* bit is preferred;
    /// otherwise the lowest is used and the caller reports the ambiguity.
    func detect(_ payload: [UInt8]) -> (bit: Int, others: [Int])? {
        let bits = ButtonBits.changed(baseline, payload)
        guard let first = bits.first else { return nil }
        let newlySet = bits.filter { ButtonBits.isSet(payload, $0) }
        let pick = newlySet.count == 1 ? newlySet[0] : first
        return (pick, bits.filter { $0 != pick })
    }
}

enum VirtualBits {
    /// Payload with derived controls' bits set/cleared from the learned bits of the controls they depend on.
    static func apply(_ payload: [UInt8], _ bindings: [String: ControlBinding]) -> [UInt8] {
        var q = payload
        for c in ControlCatalog.all {
            guard let vb = c.virtualBit, q.count > 3 + vb / 8 else { continue }
            let bits = c.virtualOf.compactMap { bindings[$0]?.bit }
            let mask = UInt8(1 << (vb % 8))
            if bits.count == c.virtualOf.count && !bits.contains(where: { ButtonBits.isSet(payload, $0) }) { q[3 + vb / 8] |= mask }
            else { q[3 + vb / 8] &= ~mask }
        }
        return q
    }
}

enum ButtonMapExport {
    /// Renders buttons.txt for the X-Plane plugin from learned bindings.
    static func render(_ bindings: [String: ControlBinding]) -> String {
        var lines = ["# Generated by Honeycomb Monitor. Format: <bit> <command> [off command]", ""]
        for control in ControlCatalog.all {
            guard let b = bindings[control.id], let bit = b.bit, !b.on.isEmpty, !b.on.contains(" ") else { continue }
            let tail = control.kind == .toggle && !b.off.isEmpty && !b.off.contains(" ") ? " \(b.off)" : ""
            lines.append("\(bit) \(b.on)\(tail)   # \(control.device.rawValue) \(control.label)\(b.provisional ? " (provisional)" : "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Controls learned together in one pass: the user operates them in the listed order and each
/// control gets the k-th distinct bit to change.
struct ControlGroup: Identifiable {
    let id: String
    let title: String
    let device: HardwareControl.Device
    let controls: [String]
    let instruction: String
    /// The sweep ends back on the first control (e.g. magneto OFF → … → START → OFF).
    var returnsToStart = false

    static let all: [ControlGroup] = [
        .init(id: "alpha.magneto", title: "Magneto", device: .alpha,
              controls: ["alpha.mag.off", "alpha.mag.right", "alpha.mag.left", "alpha.mag.both", "alpha.mag.start"],
              instruction: "Start with the key at OFF. Turn it one step at a time: R, L, BOTH, START, then back to OFF. Then Finish. (OFF sends no bit; the app derives it when no other position is set.)", returnsToStart: true),
        .init(id: "alpha.hat", title: "Hat", device: .alpha,
              controls: ["alpha.hat.up", "alpha.hat.right", "alpha.hat.down", "alpha.hat.left"],
              instruction: "Press the hat up, right, down, left — one press each, in that order. Then Finish."),
        .init(id: "alpha.rockers", title: "Rocker switches", device: .alpha,
              controls: ["alpha.sw.master_alt", "alpha.sw.master_bat", "alpha.sw.avionics1", "alpha.sw.avionics2", "alpha.sw.beacon", "alpha.sw.land", "alpha.sw.taxi", "alpha.sw.nav", "alpha.sw.strobe"],
              instruction: "Start with all rockers OFF. Flip each one ON, left to right (ALT, BAT, AV 1, AV 2, BCN, LAND, TAXI, NAV, STROBE). Then Finish."),
        .init(id: "alpha.grips", title: "Grip buttons", device: .alpha,
              controls: ["alpha.left.trigger", "alpha.left.white", "alpha.left.outer.up", "alpha.left.outer.down", "alpha.left.inner.up", "alpha.left.inner.down",
                         "alpha.right.white", "alpha.right.red", "alpha.right.top.in", "alpha.right.top.out", "alpha.right.bottom.in", "alpha.right.bottom.out"],
              instruction: "Press once each, in order — left grip: trigger, white, outer rocker up, outer down, inner up, inner down; right grip: white, red, top rocker in, top out, bottom in, bottom out. Then Finish."),
        .init(id: "bravo.ap", title: "Autopilot row", device: .bravo,
              controls: ["bravo.ap.hdg", "bravo.ap.nav", "bravo.ap.apr", "bravo.ap.rev", "bravo.ap.alt", "bravo.ap.vs", "bravo.ap.ias", "bravo.ap.master"],
              instruction: "Press each autopilot button once, left to right: HDG, NAV, APR, REV, ALT, VS, IAS, AUTOPILOT. Then Finish."),
        .init(id: "bravo.selector", title: "Selector", device: .bravo,
              controls: ["bravo.sel.alt", "bravo.sel.vs", "bravo.sel.hdg", "bravo.sel.crs", "bravo.sel.ias"],
              instruction: "Start with the selector at ALT. Turn it one step at a time: VS, HDG, CRS, IAS. Then Finish."),
        .init(id: "bravo.knob", title: "Knob", device: .bravo, controls: ["bravo.knob.inc", "bravo.knob.dec"],
              instruction: "Turn the knob one click clockwise, then one click counter-clockwise. Then Finish."),
        .init(id: "bravo.flapstrimgear", title: "Flaps · trim · gear", device: .bravo,
              controls: ["bravo.flaps.up", "bravo.flaps.down", "bravo.trim.down", "bravo.trim.up", "bravo.gear.up", "bravo.gear.down"],
              instruction: "Start with gear DOWN. Flaps lever up then down, trim wheel one notch forward then back, gear lever UP, then DOWN again. Then Finish."),
        .init(id: "bravo.switches", title: "Switches", device: .bravo, controls: (1...7).map { "bravo.sw\($0)" },
              instruction: "Start with all seven switches down. Flip each one up, left to right. Then Finish."),
        .init(id: "bravo.detents", title: "Lever detents", device: .bravo, controls: (1...6).map { "bravo.lever\($0).detent" },
              instruction: "Start with all levers above the detent. Pull each lever below the detent, left to right. Then Finish."),
    ]
}

/// Records the order in which bits first change. Within one packet, cleared bits come before newly set
/// ones (leaving a position clears its bit as the next one sets).
struct GroupLearner {
    let group: ControlGroup
    private(set) var previous: [UInt8]
    private(set) var order: [Int] = []
    private(set) var firstWasCleared = false
    init(group: ControlGroup, baseline: [UInt8]) { self.group = group; previous = baseline }
    mutating func accept(_ payload: [UInt8]) {
        let changed = ButtonBits.changed(previous, payload)
        let cleared = changed.filter { !ButtonBits.isSet(payload, $0) }, set = changed.filter { ButtonBits.isSet(payload, $0) }
        for bit in cleared + set where !order.contains(bit) {
            if order.isEmpty { firstWasCleared = !ButtonBits.isSet(payload, bit) }
            order.append(bit)
        }
        previous = payload
    }
    /// Control → bit. All controls when the counts match; when exactly one bit is missing the first
    /// control (e.g. OFF with no bit of its own) is left unassigned. Otherwise nil.
    func assignment() -> [String: Int]? {
        let n = group.controls.count
        // Sweep that returns to its start: if the start position's bit wasn't held at the beginning
        // (the first change was a bit being set), that bit shows up last when the sweep comes back.
        if group.returnsToStart && !firstWasCleared && order.count == n {
            let rotated = Array(group.controls.dropFirst()) + [group.controls[0]]
            return Dictionary(uniqueKeysWithValues: zip(rotated, order))
        }
        if order.count == n { return Dictionary(uniqueKeysWithValues: zip(group.controls, order)) }
        if order.count == n - 1 { return Dictionary(uniqueKeysWithValues: zip(group.controls.dropFirst(), order)) }
        return nil
    }
}
