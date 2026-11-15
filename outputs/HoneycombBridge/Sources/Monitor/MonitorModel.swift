import AppKit
import SwiftUI

@MainActor
final class MonitorModel: ObservableObject {
    @Published var input = InputState()
    @Published var status = "Ready to connect"
    @Published var running = false
    @Published var error: String?
    @Published var verified = false
    @Published var captureURL: URL?
    @Published var now = Date()
    @Published var controls = ControlsSnapshot()
    @Published var charlieRaw = (0, 0)
    @Published var calibrations: [AxisCalibration] = []
    @Published private(set) var simulatorEnabled = false
    @Published var simulatorStatus = "X-Plane output off"
    @Published var learningAxis: FlightAxis?
    @Published var candidate: AxisCalibration?
    @Published var calibrationMessage = "Connect the controls first, then learn one control at a time."
    private var learner: CalibrationLearner?
    @Published var bindings: [String: ControlBinding] = [:]
    @Published var selectedControl: String?
    @Published var learningControl: String?
    @Published var buttonMessage = "Select a button or switch, then Learn and operate it."
    private var buttonLearner: ButtonLearner?
    private var groupLearner: GroupLearner?
    @Published var learningGroup: ControlGroup?
    @Published var groupDetected = 0
    private var bindingsURL: URL { profileURL.deletingLastPathComponent().appendingPathComponent("controls.json") }
    private let simulator = SimulatorSender()
    private var profileURL: URL {
        let parent = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return parent.appendingPathComponent("calibration.json")
    }
    init() {
        if let data = try? Data(contentsOf: profileURL), let saved = try? JSONDecoder().decode([AxisCalibration].self, from: data) {
            calibrations = saved.filter { $0.minimum < $0.maximum && $0.minimum.isFinite && $0.maximum.isFinite && $0.center.isFinite && ($0.width == 1 || $0.width == 2) && $0.offset >= 0 && $0.offset + $0.width <= 43 }
        }
        loadBindings()
        simulator.onStatus = { [weak self] status in Task { @MainActor [weak self] in self?.simulatorStatus = status } }
        updateSimulator()
    }
    private func updateSimulator() { simulator.configure(calibrations, enabled: simulatorEnabled) }
    func setSimulatorEnabled(_ enabled: Bool) { simulatorEnabled = enabled && !calibrations.isEmpty && running; updateSimulator() }
    func beginLearning(_ axis: FlightAxis) {
        guard running, let baseline = state.lastPayload else { calibrationMessage = "Connect and move a control once before learning."; return }
        setSimulatorEnabled(false); candidate = nil; learningAxis = axis
        learner = CalibrationLearner(axis: axis, baseline: baseline)
        calibrationMessage = "Move only \(axis.title) through its full range several times, then return to center or idle and finish."
    }
    func finishLearning() {
        guard let learner else { return }
        self.learner = nil; learningAxis = nil
        guard let found = learner.candidate() else { calibrationMessage = "Not enough distinct travel. Start centered or at idle, then sweep the full range and try again."; return }
        let used = Set(found.offset..<found.offset + found.width)
        if let clash = calibrations.first(where: { $0.axis != found.axis && !used.isDisjoint(with: Set($0.offset..<$0.offset + $0.width)) }) {
            calibrationMessage = "Bytes \(found.offset)–\(found.offset + found.width - 1) are already used by \(clash.axis.title). Forget that mapping if it is wrong, then learn again."; return
        }
        candidate = found; calibrationMessage = "Candidate found. Move the control and check the preview. Reverse it if needed, then save."
    }
    func cancelLearning() { learner = nil; learningAxis = nil; candidate = nil }
    func saveCandidate() {
        guard let candidate else { return }
        calibrations.removeAll { $0.axis == candidate.axis }; calibrations.append(candidate); self.candidate = nil
        persist(); calibrationMessage = "Saved. Check direction and travel before enabling simulator output."
    }
    func reverse(_ axis: FlightAxis) {
        if candidate?.axis == axis { candidate?.inverted.toggle() }
        else if let index = calibrations.firstIndex(where: { $0.axis == axis }) { calibrations[index].inverted.toggle(); persist() }
    }
    func remove(_ axis: FlightAxis) { calibrations.removeAll { $0.axis == axis }; persist() }
    /// Button/switch bit numbers currently set (payload bytes 3...10), as used in the plugin's buttons.txt.
    func activeButtonBits() -> [Int] {
        guard let payload = state.lastPayload, payload.count >= 11 else { return [] }
        return (0..<64).filter { payload[3 + $0 / 8] & (1 << UInt8($0 % 8)) != 0 }
    }
    // MARK: Buttons and switches
    private func loadBindings() {
        var result: [String: ControlBinding] = [:]
        for c in ControlCatalog.all { result[c.id] = ControlBinding(bit: c.knownBit, on: c.defaultOn, off: c.defaultOff, provisional: c.knownBit != nil) }
        if let data = try? Data(contentsOf: bindingsURL), let saved = try? JSONDecoder().decode([String: ControlBinding].self, from: data) {
            for (id, b) in saved where ControlCatalog.control(id) != nil { result[id] = b }
        }
        bindings = result
    }
    private func saveBindings() {
        do { try JSONEncoder().encode(bindings).write(to: bindingsURL, options: .atomic) }
        catch { buttonMessage = "Could not save controls: \(error.localizedDescription)" }
    }
    func isActive(_ id: String) -> Bool {
        guard let bit = bindings[id]?.bit, let payload = state.lastPayload else { return false }
        return ButtonBits.isSet(payload, bit)
    }
    func beginButtonLearning(_ id: String) {
        guard running, let baseline = state.lastPayload, let control = ControlCatalog.control(id) else { buttonMessage = "Connect (or replay a capture) before learning."; return }
        selectedControl = id; learningControl = id; buttonLearner = ButtonLearner(controlID: id, baseline: baseline)
        buttonMessage = control.kind == .toggle ? "Flip \(control.label) once." : control.kind == .position ? "Move to \(control.label)." : "Press \(control.label) once."
    }
    func cancelButtonLearning() { buttonLearner = nil; learningControl = nil; groupLearner = nil; learningGroup = nil }
    func beginGroupLearning(_ group: ControlGroup) {
        guard running, let baseline = state.lastPayload else { buttonMessage = "Connect before learning."; return }
        buttonLearner = nil; learningControl = nil
        groupLearner = GroupLearner(group: group, baseline: baseline); learningGroup = group; groupDetected = 0
        buttonMessage = group.instruction
    }
    func finishGroupLearning() {
        guard let learner = groupLearner else { return }
        groupLearner = nil; learningGroup = nil
        guard let map = learner.assignment() else {
            buttonMessage = "\(learner.group.title): expected \(learner.group.controls.count) changes, saw \(learner.order.count) (bits \(learner.order.map(String.init).joined(separator: ", "))). Nothing saved — try again, operating only these controls, once each, in order."
            return
        }
        for (id, bit) in map {
            for (other, b) in bindings where other != id && b.bit == bit && !learner.group.controls.contains(other) { bindings[other]?.bit = nil }
            bindings[id]?.bit = bit; bindings[id]?.provisional = false
        }
        for id in learner.group.controls where map[id] == nil { bindings[id]?.bit = nil; bindings[id]?.provisional = false }
        saveBindings()
        let summary = learner.group.controls.map { "\(ControlCatalog.control($0)?.label ?? $0)=\(map[$0].map(String.init) ?? "—")" }.joined(separator: "  ")
        buttonMessage = "\(learner.group.title) learned: \(summary)"
    }
    private func learnButton(_ payload: [UInt8]) {
        if groupLearner != nil {
            groupLearner?.accept(payload)
            let count = groupLearner?.order.count ?? 0
            if count != groupDetected { groupDetected = count }
            return
        }
        guard let learner = buttonLearner, let found = learner.detect(payload) else { return }
        let bit = found.bit
        buttonLearner = nil; learningControl = nil
        let id = learner.controlID
        let control = ControlCatalog.control(id)
        var taken: [String] = []
        for (other, b) in bindings where other != id && b.bit == bit { bindings[other]?.bit = nil; taken.append(ControlCatalog.control(other)?.label ?? other) }
        // For a toggle, the learned bit should be set in the "on" position; flipping off → note polarity.
        let setNow = ButtonBits.isSet(payload, bit)
        bindings[id, default: ControlBinding(bit: nil, on: control?.defaultOn ?? "", off: control?.defaultOff ?? "")].bit = bit
        bindings[id]?.provisional = false
        saveBindings()
        var message = "\(control?.label ?? id) = bit \(bit)."
        if control?.kind == .toggle { message += setNow ? " Bit sets in the position you moved to; that position sends the on command." : " Bit cleared when you moved it; the other position sends the on command — swap commands if needed." }
        if !found.others.isEmpty { message += " Other bits changed too (\(found.others.map(String.init).joined(separator: ", "))); relearn if this is wrong." }
        if !taken.isEmpty { message += " Removed from \(taken.joined(separator: ", "))." }
        buttonMessage = message
    }
    func setCommand(_ id: String, on: String? = nil, off: String? = nil) {
        if let on { bindings[id]?.on = on.trimmingCharacters(in: .whitespaces) }
        if let off { bindings[id]?.off = off.trimmingCharacters(in: .whitespaces) }
        saveBindings()
    }
    func swapCommands(_ id: String) {
        guard var b = bindings[id] else { return }
        (b.on, b.off) = (b.off, b.on); bindings[id] = b; saveBindings()
    }
    func clearBinding(_ id: String) { bindings[id]?.bit = nil; bindings[id]?.provisional = false; saveBindings() }
    func exportButtonMap() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "buttons.txt"
        let plugin = URL(fileURLWithPath: "/Volumes/Data/X-Plane 12/Resources/plugins/HoneycombInput")
        if FileManager.default.fileExists(atPath: plugin.path) { panel.directoryURL = plugin }
        panel.message = "Save into X-Plane 12/Resources/plugins/HoneycombInput, then use Plugins → Honeycomb Input → Reload button map."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ButtonMapExport.render(bindings).write(to: url, atomically: true, encoding: .utf8); buttonMessage = "Exported \(url.path)" }
        catch { buttonMessage = "Export failed: \(error.localizedDescription)" }
    }

    func preview(_ definition: AxisCalibration) -> Float { state.lastPayload.flatMap { definition.value($0) } ?? 0 }
    private func persist() {
        do { let data = try JSONEncoder().encode(calibrations); try data.write(to: profileURL, options: .atomic) }
        catch { calibrationMessage = "Could not save calibration: \(error.localizedDescription)" }
        updateSimulator()
    }
    private var state = InputState()
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var capture: FileHandle?
    private var stopping = false
    private var generation = UUID()

    func start() {
        guard process == nil else { return }
        state = InputState(); input = state; buffer = Data(); simulator.setSourceRunning(false)
        error = nil; verified = false; stopping = false; running = true
        status = "Connecting to the Alpha…"
        let token = UUID(); generation = token
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/honeycomb-usb-read")
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("honeycomb-usb-read")
        let helper = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : sibling
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            running = false; error = "The USB helper is missing. Rebuild the app with build-monitor.sh."; status = "Unable to connect"; return
        }
        do {
            let parent = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let directory = parent.appendingPathComponent("captures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("monitor-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).ndjson")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            capture = try FileHandle(forWritingTo: url); captureURL = url
            let task = Process(), stdout = Pipe(), stderr = Pipe()
            output = stdout; errors = stderr
            task.executableURL = helper
            task.arguments = ["--vid", "0x294b", "--pid", "0x1904", "--configuration", "1", "--interface", "0", "--endpoint", "0x81", "--gip-authenticate", "--seconds", "300"]
            task.standardOutput = stdout; task.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        try? self.capture?.close(); self.capture = nil
                    } else { self.receive(data) }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.error = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            task.terminationHandler = { [weak self] task in
                let exitStatus = task.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.process = nil; self.running = false; self.simulator.setSourceRunning(false); self.setSimulatorEnabled(false)
                    if self.stopping { self.status = "Capture stopped" }
                    else if exitStatus == 0 { self.status = "Session finished · connect to start again" }
                    else { self.status = "Connection ended"; if self.error == nil { self.error = "The device could not finish the session. Check the USB connection and capture details." } }
                    self.flush()
                }
            }
            process = task
            try task.run()
        } catch {
            process = nil; running = false; self.error = error.localizedDescription; status = "Unable to connect"
            output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
            try? capture?.close(); capture = nil
        }
    }

    func stop() {
        guard let process else { running = false; status = "Ready to connect"; return }
        simulator.setSourceRunning(false); setSimulatorEnabled(false)
        stopping = true; status = "Closing the USB connection…"
        if process.isRunning { process.interrupt() }
    }

    private func receive(_ data: Data) {
        do { try capture?.write(contentsOf: data) }
        catch { self.error = "Capture could not be saved: \(error.localizedDescription)"; stop() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if let payload = InputState.payload(from: line) {
                state.accept(payload); simulator.update(payload); learner?.accept(payload); learnButton(payload); status = "Receiving Xbox input"
            } else if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                switch event["event"] as? String {
                case "gip_auth_verified": verified = true; status = "Session verified · waiting for input"
                case "gip_auth_phase": status = "Establishing the input session…"
                case "gip_auth_failed": error = event["message"] as? String ?? "Session verification failed"
                case "error": error = event["message"] as? String ?? "USB connection failed"
                default: break
                }
            }
        }
        if buffer.count > 1_000_000 { error = "Unexpected capture data"; buffer.removeAll(); stop() }
    }

    func flush() {
        state.tick(); input = state; now = Date()
        let snapshot = state.lastPayload.map { ControlsSnapshot(payload: $0, calibrations: calibrations) } ?? ControlsSnapshot()
        if snapshot != controls { controls = snapshot }
        if let p = state.lastPayload, p.count == 43 {
            let raw = (Int(p[30]) << 2 | Int(p[29] >> 6), Int(p[32]) << 2 | Int(p[31] >> 6))
            if raw != charlieRaw { charlieRaw = raw }
        }
    }

    /// Plays a saved capture through the live display (no USB, no simulator output). Loops until stopped.
    func replay(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { error = "Could not read \(url.lastPathComponent)"; return }
        let payloads = data.split(separator: 10).compactMap { InputState.payload(from: Data($0)) }
        guard !payloads.isEmpty else { error = "No input packets in \(url.lastPathComponent)"; return }
        state = InputState(); running = true; status = "Replaying \(url.lastPathComponent)"
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.process == nil else { timer.invalidate(); return }
                self.state.accept(payloads[index]); self.learnButton(payloads[index]); index = (index + 1) % payloads.count
            }
        }
    }

    func showCapture() {
        if let captureURL { NSWorkspace.shared.activateFileViewerSelecting([captureURL]) }
    }
}
