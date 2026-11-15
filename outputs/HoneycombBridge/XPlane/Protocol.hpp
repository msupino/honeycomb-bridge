#pragma once
#include <array>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>

// App -> plugin datagram, all 32-bit words in network byte order (56 bytes):
//   "HCB2", mask, sequence, reserved(0), 8 x float axis values, buttons low word, buttons high word.
// mask bits 0..7: axis i valid; bit 8: button words valid.
// Axes: 0 pitch, 1 roll, 2 yaw (-1..1); 3 throttle, 4 left brake, 5 right brake, 6 prop, 7 mixture (0..1).
// Buttons: bit n = payload byte (3 + n / 8), bit (n % 8) of the Xbox-mode input payload.
constexpr size_t kAxisCount = 8;
constexpr size_t kFrameLength = 16 + 4 * kAxisCount + 8;
constexpr uint32_t kButtonsValid = 1u << 8;
constexpr uint32_t kMaskAll = (1u << kAxisCount) - 1 | kButtonsValid;

struct HoneycombFrame {
    uint32_t mask = 0;
    uint32_t sequence = 0;
    std::array<float, kAxisCount> values{};
    uint64_t buttons = 0;
};
inline uint32_t readNetwork32(const unsigned char *p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | uint32_t(p[3]);
}
inline void writeNetwork32(unsigned char *p, uint32_t n) {
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}
inline bool decodeHoneycomb(const unsigned char *data, size_t length, HoneycombFrame &frame) {
    if (length != kFrameLength || std::memcmp(data, "HCB2", 4) || readNetwork32(data + 12)) return false;
    HoneycombFrame parsed;
    parsed.mask = readNetwork32(data + 4); parsed.sequence = readNetwork32(data + 8);
    if (parsed.mask & ~kMaskAll) return false;
    for (size_t i = 0; i < kAxisCount; i++) {
        uint32_t bits = readNetwork32(data + 16 + 4 * i); float value;
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value) || value > 1 || value < (i < 3 ? -1 : 0)) return false;
        parsed.values[i] = value;
    }
    const unsigned char *b = data + 16 + 4 * kAxisCount;
    parsed.buttons = uint64_t(readNetwork32(b)) | uint64_t(readNetwork32(b + 4)) << 32;
    frame = parsed; return true;
}
