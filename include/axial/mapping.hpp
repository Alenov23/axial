#pragma once
// SpaceControl mapping engine (fork extension of Axial).
// Pure, allocation-free and deterministic so it can run on the HID input queue
// and be unit tested without a device. Pipeline per motion report:
//   raw -> calibrate (center, range) -> deadzone (rescaled) -> response curve
//       -> sensitivity -> smoothing -> 6x6 mix matrix -> axis enable / T,R toggles
//       -> axis lock (dominant / group) -> output speed & invert -> int16
// Axis order follows the device/event ABI: 0 X, 1 Y, 2 Z (translation),
// 3 RX (tilt), 4 RY (roll), 5 RZ (spin / twist).
#include "axial/core.hpp"
#include <array>
#include <cmath>

namespace sn {
enum class Curve : uint8_t { linear, expo, power, scurve };
enum class Lock : uint8_t { none, dominant, group };

// Nominal full-scale of 3Dconnexion devices (SpaceExplorer reports about +-350).
inline constexpr float nominalRange = 350.f;

struct InputTuning {
    float sensitivity = 1;   // multiplier, 0..10
    float deadzone = 0;      // raw units after calibration, 0..1000
    float curveAmount = 0;   // 0..1, shape strength for non-linear curves
    float smoothing = 0;     // time constant in ms, 0..500 (0 = off)
    float center = 0;        // calibration: raw value at rest
    float range = nominalRange; // calibration: raw value at full deflection
    Curve curve = Curve::linear;
};

struct Mapping {
    std::array<InputTuning,6> input{};
    // matrix[output][input], weights -4..4. Identity = straight-through.
    std::array<std::array<float,6>,6> matrix{};
    std::array<float,6> gain{1,1,1,1,1,1};   // per-output speed (legacy "gain")
    std::array<bool,6> invert{};              // per-output invert (legacy "invert")
    std::array<bool,6> enabled{true,true,true,true,true,true};
    Lock lock = Lock::none;
    bool translation = true, rotation = true, orbit = true;
    Mapping() { for (int i=0;i<6;++i) matrix[i][i]=1; }
};

// Normalized response curve for magnitude m >= 0 (1 == full calibrated deflection).
// Beyond full deflection the curve continues linearly so nothing saturates early.
inline float shapeMagnitude(float m, Curve curve, float k) noexcept {
    k = std::clamp(k, 0.f, 1.f);
    auto f = [&](float x) -> float {
        switch (curve) {
            case Curve::linear: return x;
            case Curve::expo: return (1-k)*x + k*x*x*x;
            case Curve::power: return std::pow(x, 1+3*k);
            case Curve::scurve: return (1-k)*x + k*(x*x*(3-2*x));
        }
        return x;
    };
    if (m <= 1) return f(m);
    return f(1) + (m-1);
}

// Calibrate, deadzone, curve and sensitivity for one input, in nominal raw units.
inline float shapeInput(float raw, const InputTuning& t) noexcept {
    const float range = std::max(1.f, std::abs(t.range));
    const float centered = raw - t.center;
    const float magnitude = std::abs(centered);
    const float dz = std::clamp(t.deadzone, 0.f, range*0.95f);
    if (magnitude <= dz) return 0;
    // Rescale so output starts at 0 at the deadzone edge and reaches 1 at full range.
    const float m = (magnitude - dz) / (range - dz);
    return std::copysign(shapeMagnitude(m, t.curve, t.curveAmount) * nominalRange * t.sensitivity, centered);
}

// Stateful per-device processor (smoothing memory). Not thread safe: own one per
// device and call from the input queue only.
class Processor {
    std::array<float,6> smoothed{};
    std::array<int16_t,6> last{};
    uint64_t previous = 0;
public:
    void reset() noexcept { smoothed = {}; last = {}; previous = 0; }
    const std::array<int16_t,6>& output() const noexcept { return last; }
    // Compute the mapped axes for a motion report and update smoothing memory.
    Event process(Event e, const Mapping& map) noexcept {
        if (e.kind == Kind::reset || e.kind == Kind::removed) { reset(); e.axes = {}; return withFlags(e, map); }
        if (e.kind != Kind::motion) { e.axes = last; return withFlags(e, map); }
        float dt = previous && e.received > previous ? float(e.received - previous) / 1e6f : 8.f;
        dt = std::clamp(dt, 0.f, 50.f);
        previous = e.received;
        std::array<float,6> shaped{};
        for (int i=0;i<6;++i) {
            const auto& t = map.input[size_t(i)];
            float y = shapeInput(float(e.axes[size_t(i)]), t);
            if (y == 0) smoothed[size_t(i)] = 0;  // snap to rest: never drift after release
            else if (t.smoothing > 0.5f) {
                float alpha = 1 - std::exp(-dt / t.smoothing);
                smoothed[size_t(i)] += alpha * (y - smoothed[size_t(i)]);
            } else smoothed[size_t(i)] = y;
            shaped[size_t(i)] = smoothed[size_t(i)];
        }
        std::array<float,6> out{};
        for (int o=0;o<6;++o) {
            float sum = 0;
            for (int i=0;i<6;++i) sum += map.matrix[size_t(o)][size_t(i)] * shaped[size_t(i)];
            if (!map.enabled[size_t(o)] || (o<3 && !map.translation) || (o>=3 && !map.rotation)) sum = 0;
            out[size_t(o)] = sum;
        }
        if (map.lock == Lock::dominant) {
            int d = 0;
            for (int o=1;o<6;++o) if (std::abs(out[size_t(o)]) > std::abs(out[size_t(d)])) d = o;
            for (int o=0;o<6;++o) if (o != d) out[size_t(o)] = 0;
        } else if (map.lock == Lock::group) {
            float t = 0, r = 0;
            for (int o=0;o<3;++o) { t = std::max(t, std::abs(out[size_t(o)])); r = std::max(r, std::abs(out[size_t(o+3)])); }
            for (int o=0;o<3;++o) out[size_t(t >= r ? o+3 : o)] = 0;
        }
        for (int o=0;o<6;++o) {
            float v = out[size_t(o)] * map.gain[size_t(o)] * (map.invert[size_t(o)] ? -1.f : 1.f);
            last[size_t(o)] = int16_t(std::lround(std::clamp(v, -32768.f, 32767.f)));
        }
        e.axes = last;
        return withFlags(e, map);
    }
private:
    static Event withFlags(Event e, const Mapping& map) noexcept {
        if (map.orbit) e.flags |= Flags::orbit; else e.flags &= ~Flags::orbit;
        return e;
    }
};
}
