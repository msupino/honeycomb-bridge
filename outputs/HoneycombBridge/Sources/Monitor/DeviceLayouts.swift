import SwiftUI

enum DeviceTab: String, CaseIterable, Identifiable { case alpha = "Alpha XPC", bravo = "Bravo", charlie = "Charlie", activity = "Activity"; var id: String { rawValue } }

/// Panel with the three hardware layouts plus the activity cards, and an inspector for learning buttons.
struct DevicesPanel: View {
    @ObservedObject var model: MonitorModel
    @State private var tab: DeviceTab = .alpha
    var connected: Bool { model.running && model.input.packets > 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) { ForEach(DeviceTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 420).labelsHidden()
                Spacer()
                Button("Export buttons.txt…", action: model.exportButtonMap).buttonStyle(.bordered)
            }
            ScrollView(.vertical) {
                switch tab {
                case .alpha: AlphaLayout(model: model, live: connected)
                case .bravo: BravoLayout(model: model, live: connected)
                case .charlie: CharlieLayout(model: model, live: connected)
                case .activity:
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(model.input.groups) { MovementCard(group: $0, now: model.now, connected: connected) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if tab == .alpha || tab == .bravo { GroupLearnBar(model: model, device: tab == .alpha ? .alpha : .bravo); ControlInspector(model: model) }
        }
        .onAppear {
            if let i = CommandLine.arguments.firstIndex(of: "--tab"), i + 1 < CommandLine.arguments.count,
               let t = DeviceTab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(CommandLine.arguments[i + 1].lowercased()) }) { tab = t }
        }
    }
}

// MARK: - Shared pieces

private let panelFill = Color.white.opacity(0.035)

struct Plate<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// One learnable control. Lit when its bit is set; dashed when no bit is learned yet; orange while learning.
struct ControlChip: View {
    @ObservedObject var model: MonitorModel
    let id: String
    var label: String? = nil
    var width: CGFloat = 64, height: CGFloat = 30
    var tint: Color = .cyan
    var round = false
    var body: some View {
        let control = ControlCatalog.control(id)
        let binding = model.bindings[id]
        let active = model.isActive(id)
        let learning = model.learningControl == id
        let selected = model.selectedControl == id
        let learned = binding?.bit != nil
        let shape = RoundedRectangle(cornerRadius: round ? height / 2 : 7)
        Button { model.selectedControl = id } label: {
            Text(label ?? control?.label ?? id)
                .font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(active ? Color.black : Color.white.opacity(learned ? 0.9 : 0.5))
                .frame(width: width, height: height)
                .background(shape.fill(active ? tint : Color.white.opacity(0.06)))
                .overlay(shape.stroke(learning ? Color.orange : selected ? Color.white : tint.opacity(learned ? 0.45 : 0.25),
                                      style: StrokeStyle(lineWidth: learning || selected ? 2 : 1, dash: learned ? [] : [3, 3])))
                .overlay(alignment: .topTrailing) {
                    if binding?.provisional == true { Circle().fill(Color.yellow).frame(width: 5, height: 5).padding(3) }
                }
        }
        .buttonStyle(.plain)
        .help("\(control?.device.rawValue ?? "") \(control?.label ?? id) · \(binding?.bit.map { "bit \($0)" } ?? "not learned")")
    }
}

/// Two-position rocker/toggle drawn as a switch; the lit half follows the learned bit.
struct ToggleSwitchView: View {
    @ObservedObject var model: MonitorModel
    let id: String
    var tint: Color = .cyan
    var body: some View {
        let on = model.isActive(id)
        let learned = model.bindings[id]?.bit != nil
        VStack(spacing: 5) {
            Button { model.selectedControl = id } label: {
                ZStack(alignment: on ? .top : .bottom) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)).frame(width: 26, height: 50)
                    RoundedRectangle(cornerRadius: 4).fill(learned ? (on ? tint : Color.white.opacity(0.35)) : Color.white.opacity(0.12))
                        .frame(width: 22, height: 24).padding(2)
                }
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.learningControl == id ? Color.orange : model.selectedControl == id ? Color.white : tint.opacity(learned ? 0.4 : 0.2),
                                                                   style: StrokeStyle(lineWidth: model.selectedControl == id || model.learningControl == id ? 2 : 1, dash: learned ? [] : [3, 3])))
                .overlay(alignment: .topTrailing) {
                    if model.bindings[id]?.provisional == true { Circle().fill(Color.yellow).frame(width: 5, height: 5).offset(x: 3, y: -3) }
                }
            }
            .buttonStyle(.plain)
            Text(ControlCatalog.control(id)?.label ?? id).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Alpha XPC

struct AlphaLayout: View {
    @ObservedObject var model: MonitorModel
    let live: Bool
    var body: some View {
        VStack(spacing: 14) {
            Plate(title: "Yoke") {
                HStack(alignment: .center, spacing: 24) {
                    // Left grip
                    VStack(spacing: 8) {
                        Text("LEFT GRIP").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        ControlChip(model: model, id: "alpha.hat.up", label: "▲", width: 32, round: true)
                        HStack(spacing: 6) {
                            ControlChip(model: model, id: "alpha.hat.left", label: "◀", width: 32, round: true)
                            Circle().fill(Color.white.opacity(0.1)).frame(width: 18, height: 18)
                            ControlChip(model: model, id: "alpha.hat.right", label: "▶", width: 32, round: true)
                        }
                        ControlChip(model: model, id: "alpha.hat.down", label: "▼", width: 32, round: true)
                        HStack(spacing: 8) {
                            ControlChip(model: model, id: "alpha.left.trigger", label: "TRIGGER", width: 60, round: true)
                            ControlChip(model: model, id: "alpha.left.white", label: "WHITE", width: 50, round: true)
                        }
                        HStack(spacing: 10) {
                            VStack(spacing: 4) {
                                ControlChip(model: model, id: "alpha.left.outer.up", label: "▲", width: 34)
                                ControlChip(model: model, id: "alpha.left.outer.down", label: "▼", width: 34)
                                Text("OUTER").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            VStack(spacing: 4) {
                                ControlChip(model: model, id: "alpha.left.inner.up", label: "▲", width: 34)
                                ControlChip(model: model, id: "alpha.left.inner.down", label: "▼", width: 34)
                                Text("INNER").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(width: 150)
                    // Yoke graphic with live pitch/roll
                    VStack(spacing: 6) {
                        YokeShape().fill(Color.cyan.opacity(live ? 0.85 : 0.3))
                            .frame(width: 260, height: 150)
                            .rotationEffect(.degrees(model.controls.roll * 90))
                            .offset(y: model.controls.pitch * 18)
                            .frame(height: 190)
                        Text(String(format: "Roll %+.0f%%   Pitch %+.0f%%", model.controls.roll * 100, model.controls.pitch * 100))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text("Roll").font(.system(size: 10)).foregroundStyle(.secondary); ReverseToggle(model: model, axis: .roll)
                            Text("Pitch").font(.system(size: 10)).foregroundStyle(.secondary); ReverseToggle(model: model, axis: .pitch)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // Right grip
                    VStack(spacing: 8) {
                        Text("RIGHT GRIP").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        HStack(spacing: 8) {
                            ControlChip(model: model, id: "alpha.right.white", label: "WHITE", width: 50, round: true)
                            ControlChip(model: model, id: "alpha.right.red", label: "RED", width: 50, tint: .red, round: true)
                        }
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                ControlChip(model: model, id: "alpha.right.top.in", label: "◀ in", width: 46)
                                ControlChip(model: model, id: "alpha.right.top.out", label: "out ▶", width: 46)
                            }
                            Text("TOP ROCKER").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            HStack(spacing: 4) {
                                ControlChip(model: model, id: "alpha.right.bottom.in", label: "◀ in", width: 46)
                                ControlChip(model: model, id: "alpha.right.bottom.out", label: "out ▶", width: 46)
                            }
                            Text("BOTTOM ROCKER").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 150)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Plate(title: "Master · avionics · lights") {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(["alpha.sw.master_alt", "alpha.sw.master_bat"], id: \.self) { ToggleSwitchView(model: model, id: $0, tint: .red) }
                        Divider().frame(height: 60)
                        ForEach(["alpha.sw.avionics1", "alpha.sw.avionics2"], id: \.self) { ToggleSwitchView(model: model, id: $0) }
                        Divider().frame(height: 60)
                        ForEach(["alpha.sw.beacon", "alpha.sw.land", "alpha.sw.taxi", "alpha.sw.nav", "alpha.sw.strobe"], id: \.self) { ToggleSwitchView(model: model, id: $0) }
                    }
                }
                Plate(title: "Magneto") {
                    HStack(spacing: 6) {
                        ForEach(["alpha.mag.off", "alpha.mag.right", "alpha.mag.left", "alpha.mag.both", "alpha.mag.start"], id: \.self) {
                            ControlChip(model: model, id: $0, width: 46, tint: $0 == "alpha.mag.start" ? .orange : .cyan, round: true)
                        }
                    }
                }
                .frame(width: 300)
            }
        }
    }
}

// MARK: - Bravo

struct BravoLayout: View {
    @ObservedObject var model: MonitorModel
    let live: Bool
    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Plate(title: "Autopilot") {
                    HStack(spacing: 6) {
                        ForEach(["bravo.ap.hdg", "bravo.ap.nav", "bravo.ap.apr", "bravo.ap.rev", "bravo.ap.alt", "bravo.ap.vs", "bravo.ap.ias"], id: \.self) {
                            ControlChip(model: model, id: $0, width: 48, tint: .orange)
                        }
                        ControlChip(model: model, id: "bravo.ap.master", width: 84, tint: .orange)
                    }
                }
                Plate(title: "Knob → \(model.knobTarget.rawValue)") {
                    HStack(spacing: 12) {
                        VStack(spacing: 4) {
                            ForEach(["bravo.sel.alt", "bravo.sel.vs", "bravo.sel.hdg", "bravo.sel.crs", "bravo.sel.ias"], id: \.self) {
                                ControlChip(model: model, id: $0, width: 44, height: 20, tint: .orange, round: true)
                            }
                        }
                        VStack(spacing: 6) {
                            ControlChip(model: model, id: "bravo.knob.inc", label: "+", width: 36, tint: .orange, round: true)
                            Circle().stroke(Color.orange.opacity(0.4), lineWidth: 3).frame(width: 36, height: 36)
                            ControlChip(model: model, id: "bravo.knob.dec", label: "−", width: 36, tint: .orange, round: true)
                        }
                    }
                }
                .frame(width: 170)
            }
            HStack(alignment: .top, spacing: 14) {
                Plate(title: "Levers") {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(1...6, id: \.self) { n in
                            VStack(spacing: 5) {
                                HStack(spacing: 2) {
                                    if model.bindings["bravo.lever\(n).a"] != nil { ControlChip(model: model, id: "bravo.lever\(n).a", label: "A", width: 20, height: 18, tint: .orange, round: true) }
                                    if model.bindings["bravo.lever\(n).b"] != nil { ControlChip(model: model, id: "bravo.lever\(n).b", label: "B", width: 20, height: 18, tint: .red, round: true) }
                                }
                                .frame(height: 18)
                                LeverTrack(value: model.controls.levers[n - 1], live: live).frame(width: 36, height: 120)
                                Text("L\(n) \(Int((model.controls.levers[n - 1] * 100).rounded()))").font(.system(size: 9, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                                ControlChip(model: model, id: "bravo.lever\(n).detent", label: "detent", width: 44, height: 18, tint: .orange)
                            }
                        }
                    }
                }
                Plate(title: "Flaps · trim · gear") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 6) {
                            ControlChip(model: model, id: "bravo.flaps.up", label: "UP", width: 46, tint: .orange)
                            Text("FLAPS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            ControlChip(model: model, id: "bravo.flaps.down", label: "DN", width: 46, tint: .orange)
                        }
                        VStack(spacing: 6) {
                            ControlChip(model: model, id: "bravo.trim.down", label: "FWD", width: 46, tint: .orange)
                            Capsule().fill(Color.white.opacity(0.08)).frame(width: 18, height: 60)
                            ControlChip(model: model, id: "bravo.trim.up", label: "BACK", width: 46, tint: .orange)
                            Text("TRIM").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        VStack(spacing: 6) {
                            ControlChip(model: model, id: "bravo.gear.up", label: "UP", width: 46, tint: .orange)
                            Image(systemName: "circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.25))
                            ControlChip(model: model, id: "bravo.gear.down", label: "DOWN", width: 46, tint: .orange)
                            Text("GEAR").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 230)
            }
            Plate(title: "Switches") {
                HStack(spacing: 22) { ForEach(1...7, id: \.self) { ToggleSwitchView(model: model, id: "bravo.sw\($0)", tint: .orange) } }
            }
        }
    }
}

struct LeverTrack: View {
    let value: Double, live: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.05)).frame(width: 8).frame(maxWidth: .infinity)
                Capsule().fill(Color.orange.opacity(live ? 0.35 : 0.1)).frame(width: 8, height: max(4, g.size.height * value)).frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(live ? 0.95 : 0.3)).frame(width: 32, height: 14)
                    .offset(y: -max(0, (g.size.height - 14) * value))
            }
        }
    }
}

// MARK: - Charlie

struct CharlieLayout: View {
    @ObservedObject var model: MonitorModel
    let live: Bool
    var body: some View {
        VStack(spacing: 14) {
            Plate(title: "Rudder pedals") {
                PedalsView(controls: model.controls, tint: .mint, live: live).frame(height: 240)
                Text(String(format: "Raw field 29/30: %4d   ·   raw field 31/32: %4d   (0–1023)", model.charlieRaw.0, model.charlieRaw.1))
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
            Plate(title: "Charlie mode") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("", selection: $model.charlieMode) { ForEach(CharlieMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                        Toggle("Reverse", isOn: $model.charlieReversed).toggleStyle(.switch)
                    }
                    Text("In Xbox mode the Hub merges Charlie into two one-way fields (29 and 31): rudder travel and toe brakes share them and cannot be separated. Rudder = field 31 − field 29. Toe brakes = 29 left, 31 right. Calibrated uses the learned mappings below.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.charlieMode == .calibrated {
            Plate(title: "Learn") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([FlightAxis.yaw, .leftBrake, .rightBrake]) { axis in AxisLearnRow(model: model, axis: axis) }
                    HStack { Spacer(); Button("Forget all pedal mappings", role: .destructive) { [FlightAxis.yaw, .leftBrake, .rightBrake].forEach(model.remove) }.disabled(model.learningAxis != nil) }
                    Text(model.calibrationMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Rudder: start centred, slide the pedals fully left and right without pressing the toe brakes. Brakes: press only that toe brake fully, several times, then release.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            }
        }
    }
}

/// Learn / finish / save row for one axis, sharing the calibration flow used by Calibrate for X-Plane.
struct AxisLearnRow: View {
    @ObservedObject var model: MonitorModel
    let axis: FlightAxis
    var body: some View {
        let saved = model.calibrations.first { $0.axis == axis }
        let shown = model.candidate?.axis == axis ? model.candidate : saved
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(axis.title).font(.system(size: 12, weight: .medium))
                Text(shown.map { "bytes \($0.offset)\($0.width == 2 ? "–\($0.offset + 1)" : "") · \($0.signed ? "signed" : "unsigned") · \($0.bigEndian ? "BE" : "LE")\(model.candidate?.axis == axis ? " · candidate" : "")" } ?? "not calibrated")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .leading)
            ProgressView(value: shown.map { d in let v = Double(model.preview(d)); return axis.bipolar ? (v + 1) / 2 : v } ?? 0).tint(.mint)
            if model.learningAxis == axis {
                Button("Finish") { model.finishLearning() }.buttonStyle(.borderedProminent)
            } else if model.candidate?.axis == axis {
                ReverseToggle(model: model, axis: axis)
                Button("Save") { model.saveCandidate() }.buttonStyle(.borderedProminent)
            } else {
                Button(saved == nil ? "Learn" : "Relearn") { model.beginLearning(axis) }.disabled(model.learningAxis != nil)
                if saved != nil { ReverseToggle(model: model, axis: axis); Button("Forget", role: .destructive) { model.remove(axis) } }
            }
        }
    }
}

// MARK: - Group learning

struct GroupLearnBar: View {
    @ObservedObject var model: MonitorModel
    let device: HardwareControl.Device
    var body: some View {
        HStack(spacing: 8) {
            if let group = model.learningGroup {
                Image(systemName: "record.circle").foregroundStyle(.orange)
                Text("\(group.title): \(model.groupDetected) of \(group.controls.count) detected").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(group.instruction).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { model.cancelButtonLearning() }
                Button("Finish") { model.finishGroupLearning() }.buttonStyle(.borderedProminent)
            } else {
                Text("LEARN ALL:").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(ControlGroup.all.filter { $0.device == device }) { group in
                    Button(group.title) { model.beginGroupLearning(group) }.controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(10).background(Color.orange.opacity(model.learningGroup == nil ? 0.03 : 0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Inspector

struct ControlInspector: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let id = model.selectedControl, let control = ControlCatalog.control(id) {
                let binding = model.bindings[id]
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(control.device.rawValue) · \(control.label)").font(.system(size: 13, weight: .semibold))
                    Text(binding?.bit.map { "bit \($0)\(binding?.provisional == true ? " · provisional" : "")" } ?? "not learned")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(width: 170, alignment: .leading)
                if model.learningControl == id {
                    Button("Cancel") { model.cancelButtonLearning() }
                } else {
                    Button(binding?.bit == nil ? "Learn" : "Relearn") { model.beginButtonLearning(id) }.buttonStyle(.borderedProminent).disabled(control.virtualBit != nil)
                }
                TextField("X-Plane command", text: Binding(get: { binding?.on ?? "" }, set: { model.setCommand(id, on: $0) }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                if control.kind == .toggle {
                    TextField("Off command", text: Binding(get: { binding?.off ?? "" }, set: { model.setCommand(id, off: $0) }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    Button("Swap") { model.swapCommands(id) }
                }
                Button("Clear") { model.clearBinding(id) }.disabled(binding?.bit == nil || control.virtualBit != nil)
            } else {
                Text("Click a control to learn its bit and set its X-Plane command. Dashed = not learned · yellow dot = provisional from captures.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) {
            Text(model.buttonMessage).font(.system(size: 10)).foregroundStyle(.secondary).offset(x: 12, y: 18)
        }
        .padding(.bottom, 18)
    }
}
