import Foundation

/// Turns an Xbox-mode payload into the PC-mode state of the three virtual joysticks.
/// Button numbers are PC-mode, 0-based (Windows shows them +1):
/// Alpha per FlightGear's Honeycomb Alpha bindings, Bravo per RoystonS/honeycomb bravo-controls.md (see BRAVO-BUTTONS.md).
enum VirtualJoystickMapping {
    /// control id → PC button (0-based). Toggles map their "on" position here; `toggleOff` holds the other position.
    static let alphaButtons: [String: Int] = [
        "alpha.left.trigger": 0, "alpha.left.white": 1, "alpha.right.white": 2, "alpha.right.red": 3,
        "alpha.left.outer.down": 4, "alpha.left.outer.up": 5, "alpha.left.inner.down": 6, "alpha.left.inner.up": 7,
        "alpha.right.top.in": 8, "alpha.right.top.out": 9, "alpha.right.bottom.in": 10, "alpha.right.bottom.out": 11,
        "alpha.sw.master_alt": 12, "alpha.sw.master_bat": 14, "alpha.sw.avionics1": 16, "alpha.sw.avionics2": 18,
        "alpha.sw.beacon": 20, "alpha.sw.land": 22, "alpha.sw.taxi": 24, "alpha.sw.nav": 26, "alpha.sw.strobe": 28,
        "alpha.mag.off": 30, "alpha.mag.right": 31, "alpha.mag.left": 32, "alpha.mag.both": 33, "alpha.mag.start": 34,
    ]
    static let bravoButtons: [String: Int] = {
        var m: [String: Int] = [
            "bravo.ap.hdg": 0, "bravo.ap.nav": 1, "bravo.ap.apr": 2, "bravo.ap.rev": 3,
            "bravo.ap.alt": 4, "bravo.ap.vs": 5, "bravo.ap.ias": 6, "bravo.ap.master": 7,
            // Lever buttons: PC 9–12, 29, 30, 48 (1-based); which lever owns which is provisional.
            "bravo.lever1.a": 8, "bravo.lever2.a": 9, "bravo.lever2.b": 10, "bravo.lever3.a": 11,
            "bravo.lever3.b": 28, "bravo.lever4.a": 29, "bravo.lever4.b": 47,
            "bravo.knob.inc": 12, "bravo.knob.dec": 13, "bravo.flaps.down": 14, "bravo.flaps.up": 15,
            "bravo.trim.down": 21, "bravo.trim.up": 22, "bravo.gear.up": 30, "bravo.gear.down": 31,
            "bravo.lever6.detent": 32,
        ]
        for n in 1...5 { m["bravo.lever\(n).detent"] = 22 + n }          // PC 24–28
        for n in 1...7 { m["bravo.sw\(n)"] = 33 + 2 * (n - 1) }          // PC 34, 36 … 46 = up; next = down
        return m
    }()
    /// Selector buttons (PC 17–21: IAS, CRS, HDG, VS, ALT). The selector sends nothing in Xbox mode,
    /// so the virtual Bravo holds the position that matches the knob target.
    static let selectorButton: [KnobTarget: Int] = [.ias: 16, .crs: 17, .hdg: 18, .vs: 19, .alt: 20]

    static func map(_ payload: [UInt8], bindings: [String: ControlBinding], knobTarget: KnobTarget,
                    calibrations: [AxisCalibration], charlie: CharlieMode, charlieReversed: Bool) -> VirtualJoysticks? {
        guard payload.count == 43 else { return nil }
        let p = VirtualBits.apply(payload, bindings)
        func on(_ id: String) -> Bool { bindings[id]?.bit.map { ButtonBits.isSet(p, $0) } ?? false }
        func buttons(_ table: [String: Int]) -> UInt64 {
            var mask: UInt64 = 0
            for (id, n) in table {
                let pressed = on(id)
                if ControlCatalog.control(id)?.kind == .toggle {
                    mask |= 1 << UInt64(pressed ? n : n + 1)         // two-position switch: on = n, off = n + 1
                } else if pressed { mask |= 1 << UInt64(n) }
            }
            return mask
        }
        func calibrated(_ axis: FlightAxis) -> Float? { calibrations.first { $0.axis == axis }?.value(payload) }
        func bipolar(_ v: Double) -> UInt16 { UInt16((max(-1, min(1, v)) + 1) / 2 * 65535) }
        func unipolar(_ v: Double) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        func s16(_ o: Int) -> UInt16 { (UInt16(payload[o]) | UInt16(payload[o + 1]) << 8) ^ 0x8000 }  // int16 → offset binary
        func ten(_ o: Int) -> UInt16 { UInt16(UInt32(UInt16(payload[o + 1]) << 2 | UInt16(payload[o] >> 6)) * 65535 / 1023) }

        // Alpha: calibrated axes when learned (includes Reversed and the centre deadzone), raw otherwise.
        var alpha = VirtualJoysticks.Alpha()
        alpha.x = calibrated(.roll).map { bipolar(Double($0)) } ?? s16(11)
        alpha.y = calibrated(.pitch).map { bipolar(Double($0)) } ?? s16(13)
        alpha.buttons = buttons(alphaButtons)
        let (u, r, d, l) = (on("alpha.hat.up"), on("alpha.hat.right"), on("alpha.hat.down"), on("alpha.hat.left"))
        switch (u, r, d, l) {
        case (true, false, _, false): alpha.hat = 1
        case (true, true, _, _): alpha.hat = 2
        case (false, true, false, _): alpha.hat = 3
        case (_, true, true, _): alpha.hat = 4
        case (_, false, true, false): alpha.hat = 5
        case (_, _, true, true): alpha.hat = 6
        case (false, _, false, true): alpha.hat = 7
        case (true, _, _, true): alpha.hat = 8
        default: alpha.hat = 0
        }

        // Bravo: lever 1 = FlightStick throttle (u16 LE at 17), levers 2–6 = 10-bit extra axes at 19 … 27.
        var bravo = VirtualJoysticks.Bravo()
        bravo.axes = [UInt16(payload[17]) | UInt16(payload[18]) << 8] + [19, 21, 23, 25, 27].map(ten)
        bravo.buttons = buttons(bravoButtons) | 1 << UInt64(selectorButton[knobTarget]!)

        // Charlie: rudder and toe brakes share two fields in Xbox mode; follow the chosen Charlie mode.
        var pedals = VirtualJoysticks.Charlie()
        switch charlie {
        case .rudder:
            if let v = CharlieMode.rudder(payload, reversed: charlieReversed) { pedals.rudder = bipolar(v) }
        case .xbox:
            if let x = CharlieMode.xbox(payload, reversed: charlieReversed) {
                pedals.rudder = bipolar(x.rudder); pedals.leftBrake = unipolar(x.brakes); pedals.rightBrake = unipolar(x.brakes)
            }
        case .brakes:
            if let (lb, rb) = CharlieMode.fields(payload) {
                pedals.leftBrake = unipolar(charlieReversed ? rb : lb); pedals.rightBrake = unipolar(charlieReversed ? lb : rb)
            }
        case .calibrated:
            if let v = calibrated(.yaw) { pedals.rudder = bipolar(Double(v)) }
            if let v = calibrated(.leftBrake) { pedals.leftBrake = unipolar(Double(v)) }
            if let v = calibrated(.rightBrake) { pedals.rightBrake = unipolar(Double(v)) }
        }
        return VirtualJoysticks(alpha: alpha, bravo: bravo, charlie: pedals)
    }
}
