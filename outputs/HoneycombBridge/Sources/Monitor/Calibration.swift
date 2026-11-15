import Foundation

enum FlightAxis: Int, Codable, CaseIterable, Identifiable {
    case pitch, roll, yaw, throttle, leftBrake, rightBrake, prop, mixture
    var id: Int { rawValue }
    var title: String { ["Pitch", "Roll", "Rudder", "Throttle · all engines", "Left toe brake", "Right toe brake", "Prop · all engines", "Mixture · all engines"][rawValue] }
    var group: String { self == .pitch || self == .roll ? "Alpha" : [.throttle, .prop, .mixture].contains(self) ? "Bravo" : "Charlie" }
    var bipolar: Bool { rawValue < 3 }
    var offsets: [Int] { group == "Alpha" ? Array(11...14) : group == "Bravo" ? Array(17...28) : Array(29...32) }
}

/// In Xbox mode the Hub reports Charlie as two one-way 10-bit fields (payload 29/30 and 31/32).
/// Rudder travel and the toe brakes land in the same two fields, so the user picks how to use them.
enum CharlieMode: String, CaseIterable, Identifiable, Codable {
    case rudder = "Rudder", brakes = "Toe brakes", calibrated = "Calibrated mappings"
    var id: String { rawValue }
    static func fields(_ p: [UInt8]) -> (Double, Double)? {
        guard p.count >= 33 else { return nil }
        return (Double(Int(p[30]) << 2 | Int(p[29] >> 6)) / 1023, Double(Int(p[32]) << 2 | Int(p[31] >> 6)) / 1023)
    }
    /// Rudder = field 31 − field 29 (−1…1); reversed swaps direction.
    static func rudder(_ p: [UInt8], reversed: Bool) -> Double? {
        guard let (a, b) = fields(p) else { return nil }
        let v = max(-1, min(1, b - a)); return reversed ? -v : v
    }
}

struct AxisCalibration: Codable, Identifiable {
    var id: Int { axis.rawValue }
    let axis: FlightAxis
    let offset: Int
    let width: Int
    let signed: Bool
    let bigEndian: Bool
    let minimum: Double
    let maximum: Double
    let center: Double
    var inverted: Bool

    func raw(_ payload: [UInt8]) -> Double? {
        guard offset >= 0, (width == 1 || width == 2), offset + width <= payload.count else { return nil }
        if width == 1 { return signed ? Double(Int8(bitPattern: payload[offset])) : Double(payload[offset]) }
        let bits = bigEndian ? UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]) : UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
        return signed ? Double(Int16(bitPattern: bits)) : Double(bits)
    }
    func value(_ payload: [UInt8]) -> Float? {
        guard let raw = raw(payload), maximum > minimum, minimum.isFinite, maximum.isFinite, center.isFinite else { return nil }
        if axis.bipolar {
            guard center > minimum, center < maximum else { return nil }
            let result = raw >= center ? (raw - center) / (maximum - center) : (raw - center) / (center - minimum)
            // Small centre deadzone (2%) absorbs sensor jitter around neutral, then rescales to keep full travel.
            let deadzone = 0.02
            let shaped = abs(result) <= deadzone ? 0 : (result - (result > 0 ? deadzone : -deadzone)) / (1 - deadzone)
            let clipped = min(1, max(-1, shaped))
            return Float(inverted ? -clipped : clipped)
        }
        let result = min(1, max(0, (raw - minimum) / (maximum - minimum)))
        return Float(inverted ? 1 - result : result)
    }
}

struct CalibrationLearner {
    let axis: FlightAxis
    let baseline: [UInt8]
    var samples: [[UInt8]] = []
    mutating func accept(_ payload: [UInt8]) {
        if payload.count == 43 && samples.count < 8000 { samples.append(payload) }
    }
    func candidate() -> AxisCalibration? {
        guard samples.count >= 8 else { return nil }
        var best: (Double, AxisCalibration)?
        for offset in axis.offsets {
            for width in [1, 2] where width == 1 || axis.offsets.contains(offset + 1) {
                let activeBytes = (offset..<offset + width).filter { position in Set(samples.map { $0[position] }).count > 1 }.count
                guard activeBytes == width else { continue }
                for signed in [false, true] {
                    for bigEndian in width == 1 ? [false] : [false, true] {
                        let provisional = AxisCalibration(axis: axis, offset: offset, width: width, signed: signed, bigEndian: bigEndian, minimum: 0, maximum: 1, center: 0, inverted: false)
                        let values = samples.compactMap { provisional.raw($0) }
                        guard let low = values.min(), let high = values.max(), high > low,
                              Set(values).count >= 8, let center = provisional.raw(baseline) else { continue }
                        if axis.bipolar && !(center > low && center < high) { continue }
                        let variation = zip(values, values.dropFirst()).reduce(0.0) { $0 + abs($1.1 - $1.0) }
                        let score = Double(Set(values).count) / (1 + variation / (high - low))
                        let inverted = !axis.bipolar && abs(center - high) < abs(center - low)
                        let candidate = AxisCalibration(axis: axis, offset: offset, width: width, signed: signed, bigEndian: bigEndian, minimum: low, maximum: high, center: center, inverted: inverted)
                        if best == nil || score > best!.0 { best = (score, candidate) }
                    }
                }
            }
        }
        return best?.1
    }
}
