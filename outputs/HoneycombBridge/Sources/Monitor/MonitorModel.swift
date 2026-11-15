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
    @Published var calibrations: [AxisCalibration] = []
    @Published private(set) var simulatorEnabled = false
    @Published var simulatorStatus = "X-Plane output off"
    @Published var learningAxis: FlightAxis?
    @Published var candidate: AxisCalibration?
    @Published var calibrationMessage = "Connect the controls first, then learn one control at a time."
    private var learner: CalibrationLearner?
    private let simulator = SimulatorSender()
    private var profileURL: URL {
        let parent = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return parent.appendingPathComponent("calibration.json")
    }
    init() {
        if let data = try? Data(contentsOf: profileURL), let saved = try? JSONDecoder().decode([AxisCalibration].self, from: data) {
            calibrations = saved.filter { $0.minimum < $0.maximum && $0.minimum.isFinite && $0.maximum.isFinite && $0.center.isFinite && ($0.width == 1 || $0.width == 2) && $0.offset >= 0 && $0.offset + $0.width <= 43 }
        }
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
        if calibrations.contains(where: { $0.axis != found.axis && !used.isDisjoint(with: Set($0.offset..<$0.offset + $0.width)) }) {
            calibrationMessage = "This movement overlaps an existing control. Move only the selected control and try again."; return
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
        guard let process else { return }
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
                state.accept(payload); simulator.update(payload); learner?.accept(payload); status = "Receiving Xbox input"
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
    }

    func showCapture() {
        if let captureURL { NSWorkspace.shared.activateFileViewerSelecting([captureURL]) }
    }
}
