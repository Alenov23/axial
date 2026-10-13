#include "axial/transport.hpp"
#include "axial/mapping.hpp"
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <thread>
#include <mutex>
#include <chrono>
#include <pthread/qos.h>
#include <dispatch/dispatch.h>
extern "C" char* AxialRequest(const char* request) {
    if(!request)return nullptr;auto result=sn::request(request);
    return strdup(result.c_str());
}
extern "C" uint32_t AxialDeviceCount(){return uint32_t(std::size(sn::devices));}
extern "C" uint32_t AxialDeviceIdentity(uint32_t index){
    if(index>=std::size(sn::devices))return 0;
    const auto& d=sn::devices[index];return uint32_t(d.vendor)<<16|d.product;
}
extern "C" const char* AxialDeviceName(uint32_t identity){
    auto d=sn::deviceSpec(uint16_t(identity>>16),uint16_t(identity));return d?d->name:nullptr;
}
extern "C" const char* AxialDeviceButtonName(uint32_t identity,uint32_t slot){
    auto d=sn::deviceSpec(uint16_t(identity>>16),uint16_t(identity));auto b=d?d->button(slot):nullptr;return b?b->name:nullptr;
}
extern "C" uint32_t AxialDeviceButtonSlots(uint32_t identity,uint8_t* slots,uint32_t capacity){
    auto d=sn::deviceSpec(uint16_t(identity>>16),uint16_t(identity));if(!d||!slots||capacity<d->buttons.size())return 0;
    for(size_t i=0;i<d->buttons.size();++i)slots[i]=d->buttons[i].slot;return uint32_t(d->buttons.size());
}

namespace {
struct PreviewSlot {
    std::atomic<uint64_t> version{0},timestamp{0};
    std::atomic<uint32_t> device{0},buttons{0},identity{0};
    std::array<std::atomic<int16_t>,6> axes{};
    // Post-mapping output mirrored by the service (Flags::processed frames).
    std::atomic<uint64_t> mappedTimestamp{0};
    std::array<std::atomic<int16_t>,6> mapped{};
};
struct ButtonLog {uint64_t timestamp=0;uint32_t device=0,changed=0,buttons=0,reason=0,identity=0;};
struct Preview {
    std::atomic<void(*)()> activityCallback{nullptr};
    std::atomic<unsigned> activityObservers{0};
    dispatch_source_t activity;
    std::array<PreviewSlot,16> slots;
    std::array<ButtonLog,4096> log;
    std::atomic<size_t> read{0},write{0};
    std::atomic<uint64_t> lost{0};
    std::atomic<bool> running{false};
    std::thread worker;
    std::mutex lifecycle, startStop;
    int fd=-1;
    Preview() {
        activity=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(activity,^{if(activityObservers.load())if(auto callback=activityCallback.load())callback();});
        dispatch_resume(activity);
    }
    void changed(){if(activityObservers.load())dispatch_source_merge_data(activity,1);}
    void append(uint64_t time,uint32_t device,uint32_t changed,uint32_t buttons,uint32_t reason,uint32_t identity){
        if(!changed)return;size_t w=write.load(std::memory_order_relaxed);
        if(w-read.load(std::memory_order_acquire)==log.size()){++lost;return;}
        log[w%log.size()]={time,device,changed,buttons,reason,identity};write.store(w+1,std::memory_order_release);
    }
    void clear(uint32_t device=0,uint32_t reason=uint32_t(sn::Kind::reset)){
        for(auto& slot:slots)if(slot.device.load()&&(!device||slot.device.load()==device)){
            if(reason==uint32_t(sn::Kind::removed))append(sn::now(),slot.device.load(),slot.buttons.load(),0,reason,slot.identity.load());
            slot.version.fetch_add(1,std::memory_order_acq_rel);for(auto& axis:slot.axes)axis=0;for(auto& axis:slot.mapped)axis=0;slot.timestamp=0;slot.mappedTimestamp=0;
            if(reason==uint32_t(sn::Kind::removed)){slot.buttons=0;slot.device=0;slot.identity=0;}
            slot.version.fetch_add(1,std::memory_order_release);
        }
        changed();
    }
    void receive(const sn::Event& event){
        if(event.kind==sn::Kind::reset||event.kind==sn::Kind::removed){clear(event.device,uint32_t(event.kind));return;}
        if(!event.device)return;
        PreviewSlot* selected=nullptr;
        for(auto& slot:slots)if(slot.device.load()==event.device){selected=&slot;break;}
        if(!selected)for(auto& slot:slots)if(!slot.device.load()){selected=&slot;break;}
        if(!selected)return;auto& slot=*selected;
        if(event.flags&sn::Flags::processed){
            // Only mirror output for a slot already claimed by this device's raw frames.
            if(event.kind!=sn::Kind::motion||slot.device.load()!=event.device)return;
            bool moved=false;for(int i=0;i<6;++i)moved|=slot.mapped[i].load()!=event.axes[i];
            uint64_t stamp=event.received?event.received:sn::now(),previous=slot.mappedTimestamp.load();
            slot.version.fetch_add(1,std::memory_order_acq_rel);
            for(int i=0;i<6;++i)slot.mapped[i]=event.axes[i];slot.mappedTimestamp=stamp;
            slot.version.fetch_add(1,std::memory_order_release);
            if(moved||!previous||stamp-previous>250000000)changed();
            return;
        }
        uint32_t identity=uint32_t(event.vendor)<<16|event.product;
        if(!identity)identity=slot.identity.load();
        if(event.kind==sn::Kind::buttons)append(event.received,event.device,slot.buttons.load()^event.buttons,event.buttons,uint32_t(event.kind),identity);
        bool different=false;for(int i=0;i<6;++i)different|=slot.axes[i].load()!=event.axes[i];
        bool wake=event.kind==sn::Kind::motion&&(different||!slot.timestamp.load()||event.received-slot.timestamp.load()>250000000);
        slot.version.fetch_add(1,std::memory_order_acq_rel);slot.device=event.device;slot.buttons=event.buttons;slot.identity=identity;
        if(event.kind==sn::Kind::motion){for(int i=0;i<6;++i)slot.axes[i]=event.axes[i];slot.timestamp=event.received;}
        slot.version.fetch_add(1,std::memory_order_release);
        if(wake)changed();
    }
    void start(){
        std::lock_guard call(startStop);
        if(running.exchange(true))return;
        worker=std::thread([this]{pthread_setname_np("Axial live preview");pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
            while(running.load()){
                int connected=sn::openEvents(sn::Flags::monitor|sn::Flags::mapped);
                if(connected<0){for(int i=0;i<10&&running;++i)std::this_thread::sleep_for(std::chrono::milliseconds(100));continue;}
                {std::lock_guard lock(lifecycle);fd=connected;if(!running)shutdown(fd,SHUT_RDWR);}
                sn::Event event;
                while(running&&sn::readAll(connected,&event,sizeof(event))&&sn::valid(event))receive(event);
                {std::lock_guard lock(lifecycle);::close(connected);fd=-1;}
                clear(0,uint32_t(sn::Kind::removed));
            }
        });
    }
    void stop(){std::lock_guard call(startStop);running=false;{std::lock_guard lock(lifecycle);if(fd>=0)shutdown(fd,SHUT_RDWR);}if(worker.joinable())worker.join();}
    ~Preview(){stop();dispatch_source_cancel(activity);}
};
Preview preview;
}
extern "C" void AxialPreviewStart(){preview.start();}
extern "C" void AxialPreviewStop(){preview.stop();}
// Called on the main queue; dispatch coalesces producer notifications. The
// callback is process-wide and must not capture a view or renderer lifetime.
extern "C" void AxialPreviewActivity(void (*callback)()){preview.activityCallback=callback;}
// Balanced once per visible, idle view. Active renderers already read the
// buffer every frame; they do not need main-queue work on every HID report.
extern "C" void AxialPreviewWatch(bool enabled){
    if(enabled){++preview.activityObservers;preview.changed();}
    else --preview.activityObservers;
}
extern "C" uint64_t AxialPreviewNow(){return sn::now();}
extern "C" uint64_t AxialPreviewLostLogs(){return preview.lost.load();}
extern "C" bool AxialPreviewRead(uint32_t device,double* axes,uint32_t* buttons){
    if(!axes||!buttons)return false;
    for(auto& slot:preview.slots)if(slot.device.load()&&(!device||slot.device.load()==device)){
        for(int attempt=0;attempt<3;++attempt){uint64_t version=slot.version.load(std::memory_order_acquire);if(version&1)continue;
            uint32_t found=slot.device.load();uint64_t timestamp=slot.timestamp.load();for(int i=0;i<6;++i)axes[i]=slot.axes[i].load();*buttons=slot.buttons.load();
            if(slot.version.load(std::memory_order_acquire)==version&&found&&(!device||found==device)){if(!timestamp||sn::now()-timestamp>250000000)for(int i=0;i<6;++i)axes[i]=0;return true;}
        }
    }
    for(int i=0;i<6;++i)axes[i]=0;*buttons=0;return false;
}
extern "C" bool AxialPreviewPopLog(uint64_t* timestamp,uint32_t* device,uint32_t* changed,uint32_t* buttons,uint32_t* reason,uint32_t* identity){
    if(!timestamp||!device||!changed||!buttons||!reason||!identity)return false;
    size_t r=preview.read.load(std::memory_order_relaxed);if(r==preview.write.load(std::memory_order_acquire))return false;
    const auto& event=preview.log[r%preview.log.size()];*timestamp=event.timestamp;*device=event.device;*changed=event.changed;*buttons=event.buttons;*reason=event.reason;*identity=event.identity;
    preview.read.store(r+1,std::memory_order_release);return true;
}
// Mapped output for the same device; zero when stale (device at rest).
extern "C" bool AxialPreviewReadMapped(uint32_t device,double* axes){
    if(!axes)return false;
    for(auto& slot:preview.slots)if(slot.device.load()&&(!device||slot.device.load()==device)){
        for(int attempt=0;attempt<3;++attempt){uint64_t version=slot.version.load(std::memory_order_acquire);if(version&1)continue;
            uint64_t timestamp=slot.mappedTimestamp.load();for(int i=0;i<6;++i)axes[i]=slot.mapped[i].load();
            if(slot.version.load(std::memory_order_acquire)==version){if(!timestamp||sn::now()-timestamp>250000000)for(int i=0;i<6;++i)axes[i]=0;return timestamp!=0;}
        }
    }
    for(int i=0;i<6;++i)axes[i]=0;return false;
}
// The exact service shaping function, for drawing response curves in the UI.
extern "C" double AxialShapeInput(double raw,double sensitivity,double deadzone,uint32_t curve,double amount,double center,double range){
    sn::InputTuning t;t.sensitivity=float(sensitivity);t.deadzone=float(deadzone);t.curve=sn::Curve(std::min<uint32_t>(curve,3));
    t.curveAmount=float(amount);t.center=float(center);t.range=float(range);
    return sn::shapeInput(float(raw),t);
}
