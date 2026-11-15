import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate for X-Plane").font(.system(size: 25, weight: .semibold, design: .rounded))
            Text("Start yoke and rudder centered, throttle at idle and brakes released. Learn one control at a time; leave all others still.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(FlightAxis.allCases) { axis in
                        let saved = model.calibrations.first { $0.axis == axis }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(axis.title).font(.system(size: 14, weight: .medium))
                                    Text("\(axis.group) · \(saved == nil ? "Not calibrated" : "Saved mapping")").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if saved != nil { Button("Reverse") { model.reverse(axis) }; Button("Clear") { model.remove(axis) } }
                                if model.learningAxis == axis { Button("Finish range") { model.finishLearning() }.buttonStyle(.borderedProminent) }
                                else { Button(saved == nil ? "Learn" : "Relearn") { model.beginLearning(axis) }.disabled(model.learningAxis != nil) }
                            }
                            if let definition = model.candidate?.axis == axis ? model.candidate : saved {
                                let value = Double(model.preview(definition))
                                ProgressView(value: axis.bipolar ? (value + 1) / 2 : value).tint(.cyan)
                                if model.candidate?.axis == axis {
                                    HStack {
                                        Text("Preview · confirm this follows the intended control").font(.system(size: 10)).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Reverse") { model.reverse(axis) }
                                        Button("Save mapping") { model.saveCandidate() }.buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }
                        .padding(14).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Buttons & switches").font(.system(size: 14, weight: .medium))
                        let bits = model.activeButtonBits()
                        Text(bits.isEmpty ? "No bits set" : "Bits set now: " + bits.map(String.init).joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced))
                        Text("Press or flip one control and note which bit changes. Bind it in HoneycombInput/buttons.txt as `<bit> <command> [off command]`, then choose Plugins → Honeycomb Input → Reload button map.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text(model.calibrationMessage).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Learning proposes a mapping; verify its direction and range. No simulator output is sent during learning.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.cancelLearning(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 730, height: 690)
    }
}
