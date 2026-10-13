#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include "axial/devices.hpp"

namespace sn {
constexpr uint32_t magic = 0x534e4156;
enum class Kind : uint16_t { hello = 1, motion, buttons, added, removed, reset, command };
// mapped: hello flag for monitors that also want the post-mapping stream.
// processed: marks a mirrored, post-mapping copy delivered to such monitors.
enum Flags : uint32_t { monitor = 1, replay = 2, orbit = 4, disconnected = 8, mapped = 16, processed = 32 };
// Local little-endian ABI, identical on macOS arm64 and x86_64. No pointers.
struct Event {
    uint32_t magicValue = magic;
    uint16_t version = 1;
    Kind kind = Kind::motion;
    uint64_t received = 0;
    uint64_t sequence = 0;
    uint32_t device = 0;
    uint32_t buttons = 0;
    std::array<int16_t, 6> axes{};
    uint16_t vendor = 0, product = 0;
    uint32_t flags = 0;
    uint32_t pid = 0;
    uint64_t decoded = 0;
};
static_assert(sizeof(Event) == 64);
static_assert(offsetof(Event, axes) == 32);
inline bool valid(const Event& e) {
    return e.magicValue == magic && e.version == 1 &&
        uint16_t(e.kind) >= 1 && uint16_t(e.kind) <= uint16_t(Kind::command);
}
inline int16_t le16(const uint8_t* p) {
    uint16_t u = uint16_t(p[0]) | (uint16_t(p[1]) << 8);
    return static_cast<int16_t>(u);
}
struct Decoder {
    Event state;
    bool enterpriseArraySeen=false;
    uint32_t enterpriseShort=0,enterpriseLong=0;
    // Report ID is included once in bytes, regardless of the host HID callback API.
    bool decode(std::span<const uint8_t> bytes, uint64_t timestamp, Event& out) noexcept {
        if (bytes.empty()) return false;
        auto next = state;
        if (bytes[0] == 1 && (bytes.size() == 7 || bytes.size() == 13)) {
            for (size_t i=0; i < (bytes.size()-1)/2; ++i) next.axes[i] = le16(bytes.data()+1+i*2);
            next.kind = Kind::motion;
        } else if (bytes[0] == 2 && bytes.size() == 7) {
            for (size_t i=0; i<3; ++i) next.axes[i+3] = le16(bytes.data()+1+i*2);
            next.kind = Kind::motion;
        } else if (bytes[0] == 3 && bytes.size() >= 2 && bytes.size() <= 5) {
            // Enterprise duplicates its ordinary buttons in report 0x1c. Once
            // that complete report is seen, report 3 must not release high keys.
            if(enterprise(state.vendor,state.product)&&enterpriseArraySeen)return false;
            next.buttons = 0;
            for (size_t i=1; i<bytes.size(); ++i) next.buttons |= uint32_t(bytes[i]) << ((i-1)*8);
            if(enterprise(state.vendor,state.product)) {
                constexpr uint32_t legacyMask=[] {
                    uint32_t mask=0;
                    for(const auto& b:enterpriseButtons)if(b.usage==b.slot+1)mask|=uint32_t(1)<<b.slot;
                    return mask;
                }();
                next.buttons &= legacyMask;
            }
            if (next.buttons == state.buttons) return false;
            next.kind = Kind::buttons;
        } else if(enterprise(state.vendor,state.product)&&(bytes[0]==0x1c||bytes[0]==0x1d)&&bytes.size()==13) {
            uint32_t mask=0;
            for(size_t i=1;i<bytes.size();i+=2){
                unsigned usage=unsigned(bytes[i])|(unsigned(bytes[i+1])<<8);
                if(!usage)continue;
                const ButtonSpec* found=nullptr;
                for(const auto& button:enterpriseButtons)if(button.usage==usage){found=&button;break;}
                if(!found)return false; // reject malformed reports without altering held keys
                mask|=uint32_t(1)<<found->slot;
            }
            enterpriseArraySeen=true;
            if(bytes[0]==0x1c)enterpriseShort=mask;else enterpriseLong=mask;
            next.buttons=enterpriseShort|enterpriseLong;
            if(next.buttons==state.buttons)return false;
            next.kind=Kind::buttons;
        } else return false;
        next.received = timestamp;
        next.sequence = state.sequence + 1;
        state = out = next;
        return true;
    }
};
struct Settings {
    std::array<float,6> gain{1,1,1,1,1,1};
    std::array<float,6> deadzone{0,0,0,0,0,0};
    std::array<bool,6> invert{};
    bool dominant = false, translation = true, rotation = true, orbit = true;
};
inline Event filter(Event e, const Settings& s) noexcept {
    float values[6]{};
    int dominant = 0;
    for (int i=0;i<6;++i) {
        float x=e.axes[i], d=s.deadzone[i];
        x=std::copysign(std::max(0.f,std::abs(x)-d),x)*s.gain[i];
        if (s.invert[i]) x=-x;
        if ((i<3 && !s.translation) || (i>=3 && !s.rotation)) x=0;
        values[i]=x;
        if (std::abs(x)>std::abs(values[dominant])) dominant=i;
    }
    for (int i=0;i<6;++i)
        e.axes[i]=int16_t(std::clamp(s.dominant && i!=dominant ? 0.f : values[i],-32768.f,32767.f));
    if (s.orbit) e.flags |= Flags::orbit; else e.flags &= ~Flags::orbit;
    return e;
}
// Fixed queue: only consecutive motion for the same device may be replaced.
// Buttons and neutral transitions are barriers. Overflow disconnects the client.
template<size_t N> class EventQueue {
    std::array<Event,N> data{};
    size_t head=0, count=0;
public:
    // protectFront: the front frame is partly written and must not be replaced.
    bool push(const Event& e, bool protectFront=false) noexcept {
        if (count && e.kind==Kind::motion) {
            bool neutral=std::all_of(e.axes.begin(),e.axes.end(),[](int v){return v==0;});
            // Look back over at most one interleaved motion frame of the other
            // stream (raw vs processed) so mapped monitors still coalesce.
            for (size_t back=1; back<=std::min<size_t>(2,count); ++back) {
                size_t index=(head+count-back)%N;
                auto& last=data[index];
                if (last.kind!=Kind::motion||last.device!=e.device) break;
                bool previousNeutral=std::all_of(last.axes.begin(),last.axes.end(),[](int v){return v==0;});
                if ((last.flags&Flags::processed)!=(e.flags&Flags::processed)) {
                    if (previousNeutral) break; // neutral frames are barriers
                    continue;
                }
                if (!neutral && !previousNeutral && !(protectFront && index==head)) {last=e; return true;}
                break;
            }
        }
        if (count==N) return false;
        data[(head+count++)%N]=e;
        return true;
    }
    const Event& front() const { return data[head]; }
    void pop() { head=(head+1)%N; --count; }
    bool empty() const { return count==0; }
    size_t size() const { return count; }
    void clear() { head=count=0; }
};
}
