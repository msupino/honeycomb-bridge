import Foundation

struct Source: Decodable {
    let registryID: UInt64
    enum CodingKeys: String, CodingKey { case registryID = "registry_id" }
}

struct HIDFlag: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolean = try? container.decode(Bool.self) { value = boolean; return }
        let integer = try container.decode(Int.self)
        guard integer == 0 || integer == 1 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a boolean or 0/1")
        }
        value = integer == 1
    }
}

struct Event: Decodable {
    let event: String
    let device: Source?
    let usagePage: Int?
    let usage: Int?
    let cookie: Int?
    let value: Int?
    let logicalMin: Int?
    let logicalMax: Int?
    let isRelative: HIDFlag?
    enum CodingKeys: String, CodingKey {
        case event, device, usage, cookie, value
        case usagePage = "usage_page", logicalMin = "logical_min", logicalMax = "logical_max"
        case isRelative = "is_relative"
    }
}

struct Binding: Codable {
    let registryID: UInt64
    let usagePage: Int
    let usage: Int
    let cookie: Int
    let kind: String
    let index: Int
    let invert: Bool
}

struct State: Equatable, Encodable {
    var axes: [Int] = Array(repeating: 0, count: 8)
    var buttons: UInt32 = 0
    var report: Data {
        var result = Data()
        for axis in axes {
            let bits = UInt16(bitPattern: Int16(axis))
            result.append(UInt8(truncatingIfNeeded: bits))
            result.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        for shift in stride(from: 0, to: 32, by: 8) {
            result.append(UInt8(truncatingIfNeeded: buttons >> shift))
        }
        return result
    }
}

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Mapper {
    let bindings: [Binding]
    private(set) var state = State()

    init(bindings: [Binding]) throws {
        guard !bindings.isEmpty else { throw BridgeError(message: "Mapping must contain at least one binding") }
        var destinations = Set<String>()
        for b in bindings {
            guard (b.kind == "axis" && (0..<8).contains(b.index)) ||
                  (b.kind == "button" && (0..<32).contains(b.index)) else {
                throw BridgeError(message: "Expected axis index 0...7 or button index 0...31")
            }
            guard destinations.insert("\(b.kind):\(b.index)").inserted else {
                throw BridgeError(message: "Duplicate destination \(b.kind):\(b.index)")
            }
        }
        self.bindings = bindings
    }

    mutating func accept(_ event: Event) throws -> Bool {
        guard let device = event.device else { return false }
        let previous = state
        for b in bindings where b.registryID == device.registryID {
            if event.event == "hid_removed" {
                if b.kind == "axis" { state.axes[b.index] = 0 }
                else { state.buttons &= ~(UInt32(1) << b.index) }
                continue
            }
            guard event.event == "value", event.usagePage == b.usagePage,
                  event.usage == b.usage, event.cookie == b.cookie, let value = event.value else { continue }
            guard event.isRelative?.value != true else { throw BridgeError(message: "Relative HID elements need a different mapper") }
            if b.kind == "axis" {
                guard let low = event.logicalMin, let high = event.logicalMax, high > low else {
                    throw BridgeError(message: "Mapped axis has no usable HID logical range")
                }
                let unit = min(1, max(0, (Double(value) - Double(low)) / (Double(high) - Double(low))))
                let signed = Int(((unit * 2 - 1) * 32767).rounded())
                state.axes[b.index] = b.invert ? -signed : signed
            } else {
                let active = b.invert ? value == 0 : value != 0
                let mask = UInt32(1) << b.index
                if active { state.buttons |= mask } else { state.buttons &= ~mask }
            }
        }
        return state != previous
    }
}

let joystickDescriptor = Data([
    0x05, 0x01, 0x09, 0x04, 0xa1, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x33,
    0x09, 0x34, 0x09, 0x35, 0x09, 0x36, 0x09, 0x37,
    0x16, 0x01, 0x80, 0x26, 0xff, 0x7f,
    0x75, 0x10, 0x95, 0x08, 0x81, 0x02,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x20,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x20, 0x81, 0x02, 0xc0
])
