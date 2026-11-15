import SwiftUI

/// Live control positions decoded from the 43-byte Xbox-mode payload.
/// Field layout measured on the test rig (see XPLANE-BRIDGE.md):
///   Alpha roll  = signed 16-bit LE at 11, pitch = signed 16-bit LE at 13
///   Bravo lever n (0...5) = 10-bit packed at 17 + 2n  (byte[o] bits 7-6 = low 2 bits, byte[o+1] = high 8 bits)
///   Charlie: two 10-bit packed fields at 29 and 31 (provisionally left/right toe brake)
/// Saved calibrations, when present, take precedence over these raw decodes.
struct ControlsSnapshot: Equatable {
    var roll: Double = 0, pitch: Double = 0
    var rudder: Double?            // only from a saved calibration; raw rudder field not yet confirmed
    var leftBrake: Double = 0, rightBrake: Double = 0
    var levers = [Double](repeating: 0, count: 6)
    var rollCalibrated = false, pitchCalibrated = false, brakesCalibrated = false

    static func signed16(_ p: [UInt8], _ o: Int) -> Double { Double(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) }
    static func packed10(_ p: [UInt8], _ o: Int) -> Double { Double(Int(p[o + 1]) << 2 | Int(p[o] >> 6)) / 1023 }

    init() {}
    init(payload p: [UInt8], calibrations: [AxisCalibration], charlie: CharlieMode = .calibrated, charlieReversed: Bool = false) {
        guard p.count == 43 else { return }
        func calibrated(_ axis: FlightAxis) -> Double? { calibrations.first { $0.axis == axis }?.value(p).map(Double.init) }
        roll = max(-1, min(1, Self.signed16(p, 11) / 32767))
        pitch = max(-1, min(1, Self.signed16(p, 13) / 32767))
        if let v = calibrated(.roll) { roll = v; rollCalibrated = true }
        if let v = calibrated(.pitch) { pitch = v; pitchCalibrated = true }
        rudder = calibrated(.yaw)
        leftBrake = Self.packed10(p, 29); rightBrake = Self.packed10(p, 31)
        if let l = calibrated(.leftBrake) { leftBrake = l; brakesCalibrated = true }
        if let r = calibrated(.rightBrake) { rightBrake = r }
        switch charlie {
        case .rudder: rudder = CharlieMode.rudder(p, reversed: charlieReversed); leftBrake = 0; rightBrake = 0; brakesCalibrated = true
        case .brakes:
            if let (l, r) = CharlieMode.fields(p) { leftBrake = charlieReversed ? r : l; rightBrake = charlieReversed ? l : r }
            rudder = nil; brakesCalibrated = true
        case .calibrated: break
        }
        levers = (0..<6).map { Self.packed10(p, 17 + 2 * $0) }
    }
}

struct ControlsPanel: View {
    let controls: ControlsSnapshot
    let connected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            panel("Alpha · yoke", tint: .cyan) { YokeView(roll: controls.roll, pitch: controls.pitch, tint: .cyan, live: connected) }
            panel("Bravo · levers", tint: .orange) { LeversView(values: controls.levers, tint: .orange, live: connected) }
            panel("Charlie · pedals", tint: .mint) { PedalsView(controls: controls, tint: .mint, live: connected) }
        }
        .frame(height: 230)
    }
    private func panel<Content: View>(_ title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.12), lineWidth: 1))
    }
}

private func percent(_ v: Double) -> String { String(format: "%+.0f%%", v * 100) }

struct YokeView: View {
    let roll: Double, pitch: Double, tint: Color, live: Bool
    var body: some View {
        HStack(spacing: 14) {
            // Pitch/roll field: dot shows stick position.
            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                    Path { p in p.move(to: CGPoint(x: s / 2, y: 6)); p.addLine(to: CGPoint(x: s / 2, y: s - 6))
                        p.move(to: CGPoint(x: 6, y: s / 2)); p.addLine(to: CGPoint(x: s - 6, y: s / 2)) }
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    Circle().fill(tint.opacity(live ? 0.95 : 0.3)).frame(width: 14, height: 14)
                        .shadow(color: tint.opacity(live ? 0.6 : 0), radius: 6)
                        .position(x: s / 2 + roll * (s / 2 - 10), y: s / 2 + pitch * (s / 2 - 10))
                }
                .frame(width: s, height: s)
            }
            .aspectRatio(1, contentMode: .fit)
            VStack(spacing: 10) {
                // Yoke wheel rotated by roll (±90°).
                YokeShape().fill(tint.opacity(live ? 0.9 : 0.3))
                    .frame(width: 96, height: 58)
                    .rotationEffect(.degrees(roll * 90))
                    .offset(y: pitch * 14)
                    .animation(.linear(duration: 0.03), value: roll)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Roll  \(percent(roll))"); Text("Pitch \(percent(pitch))")
                }
                .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: 110)
        }
    }
}

struct LeversView: View {
    let values: [Double], tint: Color, live: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(values.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.white.opacity(0.05)).frame(width: 8).frame(maxWidth: .infinity)
                            Capsule().fill(tint.opacity(live ? 0.35 : 0.1)).frame(width: 8, height: max(4, g.size.height * values[i])).frame(maxWidth: .infinity)
                            RoundedRectangle(cornerRadius: 4).fill(tint.opacity(live ? 0.95 : 0.3)).frame(width: 30, height: 14)
                                .offset(y: -max(0, (g.size.height - 14) * values[i]))
                        }
                    }
                    Text("\(Int((values[i] * 100).rounded()))").font(.system(size: 10, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                    Text("L\(i + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct PedalsView: View {
    let controls: ControlsSnapshot, tint: Color, live: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(controls.rudder == nil ? "Rudder · learn in Calibrate to display" : "Rudder \(percent(controls.rudder!))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                GeometryReader { g in
                    let r = controls.rudder ?? 0
                    ZStack {
                        Capsule().fill(Color.white.opacity(0.05))
                        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1)
                        Capsule().fill(tint.opacity(live && controls.rudder != nil ? 0.95 : 0.25)).frame(width: 22, height: 14)
                            .offset(x: r * (g.size.width / 2 - 11))
                    }
                }
                .frame(height: 14)
            }
            HStack(alignment: .bottom, spacing: 28) {
                brake("Left toe", controls.leftBrake)
                brake("Right toe", controls.rightBrake)
            }
            .frame(maxWidth: .infinity)
            if !controls.brakesCalibrated {
                Text("Raw fields 29/31 · provisional").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
    private func brake(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                    RoundedRectangle(cornerRadius: 6).fill(tint.opacity(live ? 0.8 : 0.2)).frame(height: max(3, g.size.height * value))
                }
            }
            .frame(width: 44)
            Text("\(title) \(Int((value * 100).rounded()))%").font(.system(size: 10, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Aircraft yoke seen from the pilot seat: centre hub on a column, a crossbar, and two upturned grips.
struct YokeShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func x(_ v: Double) -> Double { r.minX + v * w }
        func y(_ v: Double) -> Double { r.minY + v * h }
        var p = Path()
        // Column below the hub
        p.addRoundedRect(in: CGRect(x: x(0.44), y: y(0.55), width: w * 0.12, height: h * 0.45), cornerSize: CGSize(width: 2, height: 2))
        // Hub
        p.addRoundedRect(in: CGRect(x: x(0.36), y: y(0.38), width: w * 0.28, height: h * 0.28), cornerSize: CGSize(width: 5, height: 5))
        // Crossbar
        p.addRoundedRect(in: CGRect(x: x(0.08), y: y(0.44), width: w * 0.84, height: h * 0.16), cornerSize: CGSize(width: 4, height: 4))
        // Grips
        p.addRoundedRect(in: CGRect(x: x(0.0), y: y(0.0), width: w * 0.14, height: h * 0.60), cornerSize: CGSize(width: 6, height: 6))
        p.addRoundedRect(in: CGRect(x: x(0.86), y: y(0.0), width: w * 0.14, height: h * 0.60), cornerSize: CGSize(width: 6, height: 6))
        return p
    }
}
