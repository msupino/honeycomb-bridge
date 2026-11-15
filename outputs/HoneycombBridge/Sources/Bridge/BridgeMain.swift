import Foundation
import CoreHID

actor ReportDelegate: HIDVirtualDeviceDelegate {
    private var report = State().report
    func update(_ data: Data) { report = data }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        throw BridgeError(message: "Output/feature reports are not supported")
    }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        guard type == .input, id == nil, maxSize >= report.count else {
            throw BridgeError(message: "Unsupported report request")
        }
        return report
    }
}

@main
struct BridgeMain {
    static func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    static func main() async {
        do { try await run() }
        catch { log("Error: \(error.localizedDescription)"); exit(1) }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments.isEmpty {
            print("""
            honeycomb-bridge --mapping FILE [--virtual]
            Reads probe NDJSON on stdin; writes normalized state NDJSON on stdout.
            Default: no virtual HID creation. --virtual requires Apple-approved HID
            Virtual Device entitlement, signing and matching provisioning on macOS 15+.
            """)
            return
        }
        var mapping: String?
        var virtual = false
        var i = 0
        while i < arguments.count {
            if arguments[i] == "--mapping", i + 1 < arguments.count {
                i += 1; mapping = arguments[i]
            } else if arguments[i] == "--virtual" { virtual = true }
            else { throw BridgeError(message: "Unknown/incomplete option: \(arguments[i])") }
            i += 1
        }
        guard let mapping else { throw BridgeError(message: "--mapping is required") }
        let bindings = try JSONDecoder().decode([Binding].self, from: Data(contentsOf: URL(fileURLWithPath: mapping)))
        var mapper = try Mapper(bindings: bindings)
        let delegate = ReportDelegate()
        var device: HIDVirtualDevice?
        if virtual {
            log("Attempting CoreHID virtual joystick creation. A build alone does not grant the required entitlement.")
            guard let created = HIDVirtualDevice(properties: .init(
                descriptor: joystickDescriptor, vendorID: 0, productID: 1,
                product: "Honeycomb Research Joystick", manufacturer: "Local prototype",
                uniqueID: UUID().uuidString)) else {
                throw BridgeError(message: "CoreHID refused virtual device creation. Check Apple-approved signing/provisioning and permissions; no virtual output is available.")
            }
            await created.activate(delegate: delegate)
            device = created
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func publish(_ state: State) async throws {
            if let device {
                await delegate.update(state.report)
                try await device.dispatchInputReport(data: state.report, timestamp: .now)
            }
            let data = try encoder.encode(state)
            FileHandle.standardOutput.write(data + Data([10]))
        }
        try await publish(mapper.state)
        if virtual { log("CoreHID accepted the initial report. Verify enumeration and motion in the target app separately.") }
        else { log("Log-only bridge active; no virtual joystick requested.") }
        do {
            while let line = readLine() {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
                if try mapper.accept(event) { try await publish(mapper.state) }
            }
        } catch {
            try? await publish(State())
            throw error
        }
        try await publish(State())
        withExtendedLifetime(device) {}
    }
}
