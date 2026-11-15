import Foundation

struct MovementGroup: Identifiable {
    let id: Int
    let name: String
    let subtitle: String
    let symbol: String
    let offsets: [Int]
    var bytes: [UInt8] = []
    var changes = 0
    var lastChanged: Date?
    var history: [Double] = Array(repeating: 0, count: 90)
}

struct InputState {
    var groups = [
        MovementGroup(id: 0, name: "Alpha", subtitle: "Yoke & switches", symbol: "steeringwheel", offsets: [3, 4, 11, 12, 13, 14]),
        MovementGroup(id: 1, name: "Bravo", subtitle: "Levers & panel", symbol: "slider.vertical.3", offsets: [5, 7, 8, 9] + Array(17...28)),
        MovementGroup(id: 2, name: "Charlie", subtitle: "Rudder & toe brakes", symbol: "arrow.left.and.right", offsets: Array(29...32))
    ]
    var packets = 0
    var lastPayload: [UInt8]?
    var pendingChanges = [0, 0, 0]
    var lastInput: Date?

    static func payload(from line: Data) -> [UInt8]? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              event["event"] as? String == "usb_packet",
              (event["endpoint"] as? Int) == 0x81,
              let hex = event["hex"] as? String, hex.count % 2 == 0, hex.count <= 128 else { return nil }
        let chars = Array(hex.utf8)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let a = nibble(chars[i]), let b = nibble(chars[i + 1]) else { return nil }
            bytes.append(a * 16 + b)
        }
        guard bytes.count == 47, bytes[0] == 0x20, bytes[1] == 0, bytes[3] == 43 else { return nil }
        return Array(bytes.dropFirst(4))
    }

    mutating func accept(_ payload: [UInt8], at date: Date = Date()) {
        guard payload.count == 43 else { return }
        packets += 1
        lastInput = date
        for i in groups.indices {
            if let previous = lastPayload,
               groups[i].offsets.contains(where: { previous[$0] != payload[$0] }) {
                pendingChanges[i] += 1
                groups[i].lastChanged = date
            }
            groups[i].bytes = groups[i].offsets.map { payload[$0] }
        }
        lastPayload = payload
    }

    mutating func tick() {
        for i in groups.indices {
            groups[i].changes += pendingChanges[i]
            groups[i].history.append(min(1, Double(pendingChanges[i]) / 5))
            groups[i].history.removeFirst()
            pendingChanges[i] = 0
        }
    }
}
