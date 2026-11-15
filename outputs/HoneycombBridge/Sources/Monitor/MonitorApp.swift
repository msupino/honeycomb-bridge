import SwiftUI
import Combine
import AppKit

@main
struct MonitorApp: App {
    @StateObject private var model = MonitorModel()
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--validate-capture"), index + 1 < CommandLine.arguments.count {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                var state = InputState()
                for line in data.split(separator: 10) {
                    if let payload = InputState.payload(from: Data(line)) { state.accept(payload) }
                }
                state.tick()
                let result: [String: Any] = ["packets": state.packets, "changes": Dictionary(uniqueKeysWithValues: state.groups.map { ($0.name, $0.changes) })]
                let output = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                FileHandle.standardOutput.write(output + Data([10])); exit(0)
            } catch { FileHandle.standardError.write(Data("Capture validation failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
    }
    var body: some Scene {
        Window("Honeycomb Monitor", id: "monitor") {
            MonitorView(model: model)
                .frame(minWidth: 980, minHeight: 700)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width: 1160, height: 760)
        .windowStyle(.hiddenTitleBar)
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @State private var showCalibration = false
    private let timer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("HONEYCOMB / LIVE LAB").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2.5).foregroundStyle(.secondary)
                    Text("Three devices. One connection.").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Alpha XPC in Xbox mode · Bravo and Charlie through the Xbox Hub")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { model.running ? model.stop() : model.start() }) {
                    Label(model.running ? "Stop capture" : "Connect", systemImage: model.running ? "stop.fill" : "cable.connector")
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).tint(model.running ? Color.white.opacity(0.14) : .cyan)
                .padding(.top, 21)
            }
            HStack(spacing: 10) {
                Circle().fill(model.running ? (model.input.packets > 0 ? Color.mint : .orange) : .gray).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(model.input.packets.formatted()) reports").monospacedDigit().font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                if model.verified { Label("Verified exchange", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(.mint) }
            }
            .padding(14).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 16) {
                Button("Calibrate for X-Plane…") { showCalibration = true }.buttonStyle(.bordered)
                Toggle("X-Plane output", isOn: Binding(get: { model.simulatorEnabled }, set: model.setSimulatorEnabled))
                    .toggleStyle(.switch).disabled(!model.running || model.calibrations.isEmpty)
                Spacer()
                Text(model.simulatorStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(model.input.groups) { group in
                    MovementCard(group: group, now: model.now, connected: model.running && model.input.packets > 0)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A movement monitor, before a simulator driver.").font(.system(size: 12, weight: .medium))
                    Text("Channels are grouped from the isolated tests. Names, ranges and calibration are still being verified.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show capture", action: model.showCapture).buttonStyle(.link).disabled(model.captureURL == nil)
            }
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(red: 0.065, green: 0.085, blue: 0.12), Color(red: 0.035, green: 0.045, blue: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .sheet(isPresented: $showCalibration) { CalibrationView(model: model) }
        .onReceive(timer) { _ in model.flush() }
        .onDisappear { model.stop() }
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    }
}

struct MovementCard: View {
    let group: MovementGroup
    let now: Date
    let connected: Bool
    private var tint: Color { [Color.cyan, Color.orange, Color.mint][group.id] }
    private var moving: Bool { connected && group.lastChanged.map { now.timeIntervalSince($0) < 0.45 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: group.symbol).font(.system(size: 20)).frame(width: 42, height: 42)
                    .foregroundStyle(tint).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(group.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(moving ? "Moving" : connected ? "Still" : group.bytes.isEmpty ? "Waiting" : "Paused")
                    .font(.system(size: 27, weight: .medium, design: .rounded)).foregroundStyle(moving ? tint : Color.white.opacity(0.65))
                Spacer()
                Text("\(group.changes.formatted()) changes").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("ACTIVITY").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
                Canvas { context, size in
                    var line = Path()
                    for (i, value) in group.history.enumerated() {
                        let point = CGPoint(x: Double(i) / Double(group.history.count - 1) * size.width, y: size.height - 4 - value * (size.height - 9))
                        if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    context.stroke(line, with: .color(tint.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.16), tint.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                .frame(height: 40)
            }
            Divider().overlay(Color.white.opacity(0.04))
            VStack(alignment: .leading, spacing: 12) {
                Text("OBSERVED CHANNELS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: group.offsets.count > 8 ? 4 : 8) {
                    ForEach(Array(group.offsets.enumerated()), id: \.offset) { index, offset in
                        let value = group.bytes.indices.contains(index) ? Double(group.bytes[index]) / 255 : 0
                        VStack(spacing: 6) {
                            GeometryReader { geometry in
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.045))
                                    RoundedRectangle(cornerRadius: 4).fill(tint.opacity(connected ? 0.7 : 0.15))
                                        .frame(height: max(3, geometry.size.height * value))
                                }
                            }
                            .frame(height: 60)
                            Text("\(index + 1)").font(.system(size: group.offsets.count > 8 ? 8 : 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .help("Observed payload byte \(offset): \(group.bytes.indices.contains(index) ? Int(group.bytes[index]) : 0)")
                    }
                }
            }
            Text(group.lastChanged.map { "Last movement \(max(0, Int(now.timeIntervalSince($0))))s ago" } ?? "Move this device to see activity")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(moving ? 0.065 : 0.035), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(moving ? 0.5 : 0.12), lineWidth: 1))
    }
}
