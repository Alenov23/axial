#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#import <ApplicationServices/ApplicationServices.h>
#include "axial/transport.hpp"
#include "axial/keys.hpp"
#include "axial/application.hpp"
#include "axial/web.hpp"
#include "axial/mapping.hpp"
#include <atomic>
#include <cstdio>
#include <memory>
#include <map>
#include <thread>
#include <vector>
#include <sys/file.h>
#include <signal.h>
#include <mach/mach.h>
#include <sys/resource.h>

using namespace sn;
namespace {
// Order is the wire/JSON order of action names; append only.
enum class Action : uint8_t {none,dominant,translation,rotation,faster,slower,fit,group,pause,resetSpeed};
const char* const actionNames[]={"","dominant","translation","rotation","faster","slower","fit","group","pause","resetSpeed"};
struct MacroStep {enum class Type:uint8_t{key,text,delay}; Type type=Type::key;int key=0;uint64_t modifiers=0;uint32_t delay=0;std::string text;};
struct Profile {
    Mapping motion;
    std::array<float,6> configuredGain{1,1,1,1,1,1};
    bool led=true;
    std::array<int,32> keys;
    std::array<uint64_t,32> modifiers{};
    std::array<Action,32> actions{};
    std::array<std::vector<MacroStep>,32> macros{};
    std::array<std::string,32> open{},shell{};
    uint32_t blocked=0; // buttons withheld from applications (custom assignment owns them)
    Profile(){keys.fill(-1);}
};
struct Configuration { std::map<std::string,Profile> profiles;WebConfiguration web; };
std::unique_ptr<WebServer> webServer;
struct Peer {
    int fd=-1;
    pid_t pid=0;
    sn::ProcessIdentity identity;
    bool foreground=false;
    bool registered=false, observe=false, injecting=false, writeActive=false, mapped=false;
    Event incoming{};
    size_t readOffset=0,writeOffset=0;
    EventQueue<256> queue;
    dispatch_source_t reader=nullptr,writer=nullptr;
};
struct SocketLifetime {int fd;explicit SocketLifetime(int value):fd(value){}~SocketLifetime(){close(fd);}};
struct LEDOutput {
    IOHIDDeviceRef device;
    IOHIDElementRef element;
    std::atomic<bool> connected{true};
    std::atomic<int> state{-1};
    std::atomic<uint32_t> error{0};
    LEDOutput(IOHIDDeviceRef d,IOHIDElementRef e):device(d),element(e){CFRetain(d);CFRetain(e);}
    ~LEDOutput(){CFRelease(element);CFRelease(device);}
};
struct HID {
    IOHIDDeviceRef device=nullptr;
    Decoder decoder;
    Profile profile;
    Profile preview; // profile mirrored to mapped monitors (the one being edited)
    Processor processor, previewProcessor;
    uint32_t previousButtons=0;
    uint32_t suppressedButtons=0;
    std::shared_ptr<LEDOutput> led;
    int requestedLED=-1;
};
struct Snapshot {
    std::array<Event,16> latest{};
    size_t count=0,clients=0;
    uint64_t reports=0,overflows=0,rejected=0;
    pid_t foreground=0;
    std::array<bool,16> ledSupported{};
    std::array<int,16> ledState{};
    std::array<uint32_t,16> ledError{};
};
dispatch_queue_t inputQueue;
std::array<Peer,32> peers;
std::array<HID,16> hidDevices;
std::array<Event,16> virtualDevices{};
std::array<uint32_t,16> virtualButtonState{};
std::array<Processor,16> virtualProcessors,virtualPreviewProcessors;
Processor fallbackProcessor,fallbackPreviewProcessor;
std::unique_ptr<Configuration> configuration;
Profile activeProfile,activePreview;
std::string activeKey,previewKey;
std::string foregroundBundle;
pid_t foregroundPID=0;
sn::ProcessIdentity foregroundIdentity;
void resolveForeground(Peer& peer) {
    peer.foreground=sn::belongsToApplication(peer.identity,foregroundIdentity,sn::processIdentity);
}
bool mockMode=false;
uint64_t reports=0,overflows=0,rejected=0;
dispatch_queue_t keyQueue;
dispatch_queue_t macroQueue;
dispatch_queue_t outputQueue;
dispatch_source_t keySource;
struct KeyWork {uint32_t device=0,buttons=0;bool release=false;std::array<int,32> keys{};std::array<uint64_t,32> modifiers{};};
std::array<KeyWork,128> keyWork;
std::atomic<size_t> keyRead{0},keyWrite{0};
std::atomic<bool> keyOverflow{false};
KeyState heldKeys;
NSDictionary* document;
NSMutableDictionary* commandCatalog;
NSString* settingsPath;
uint32_t nextDevice=1;

void setLED(HID& hid,bool enabled) {
    if(!hid.led||hid.requestedLED==int(enabled))return;
    hid.requestedLED=enabled;auto output=hid.led;
    dispatch_async(outputQueue,^{
        if(!output->connected.load())return;
        auto value=IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,output->element,mach_absolute_time(),enabled?1:0);
        IOReturn result=value?IOHIDDeviceSetValue(output->device,output->element,value):kIOReturnNoMemory;
        if(value)CFRelease(value);
        output->error=result;output->state=result==kIOReturnSuccess?int(enabled):-1;
    });
}

void postKey(int key,bool down,uint64_t modifiers){
    CGEventRef e=CGEventCreateKeyboardEvent(nullptr,CGKeyCode(key),down);
    if(e){CGEventSetFlags(e,CGEventFlags(modifiers));CGEventPost(kCGHIDEventTap,e);CFRelease(e);}
}
// Macros press real modifier keys around each chord; some apps (Blender, Fusion)
// ignore flag-only modifiers on synthetic key events.
void postChord(int key,uint64_t modifiers){
    struct Modifier {uint64_t flag;CGKeyCode code;};
    static constexpr Modifier order[]={{kCGEventFlagMaskControl,59},{kCGEventFlagMaskAlternate,58},{kCGEventFlagMaskShift,56},{kCGEventFlagMaskCommand,55}};
    uint64_t held=0;
    for(const auto& m:order)if(modifiers&m.flag){held|=m.flag;
        if(CGEventRef e=CGEventCreateKeyboardEvent(nullptr,m.code,true)){CGEventSetFlags(e,CGEventFlags(held));CGEventPost(kCGHIDEventTap,e);CFRelease(e);}}
    postKey(key,true,modifiers);postKey(key,false,modifiers);
    for(auto it=std::rbegin(order);it!=std::rend(order);++it)if(modifiers&it->flag){held&=~it->flag;
        if(CGEventRef e=CGEventCreateKeyboardEvent(nullptr,it->code,false)){CGEventSetFlags(e,CGEventFlags(held));CGEventPost(kCGHIDEventTap,e);CFRelease(e);}}
}
void typeText(const std::string& text){
    NSString* string=[NSString stringWithUTF8String:text.c_str()];if(!string)return;
    for(NSUInteger i=0;i<string.length;){
        NSRange range=[string rangeOfComposedCharacterSequenceAtIndex:i];
        unichar buffer[8];NSUInteger length=std::min<NSUInteger>(range.length,8);[string getCharacters:buffer range:NSMakeRange(range.location,length)];
        for(bool down:{true,false})if(CGEventRef e=CGEventCreateKeyboardEvent(nullptr,0,down)){CGEventKeyboardSetUnicodeString(e,length,buffer);CGEventPost(kCGHIDEventTap,e);CFRelease(e);}
        i=NSMaxRange(range);usleep(2000);
    }
}
void runMacro(std::vector<MacroStep> steps){
    if(steps.empty())return;
    dispatch_async(macroQueue,^{
        if(!AXIsProcessTrusted())return;
        for(const auto& s:steps){
            if(s.type==MacroStep::Type::key){postChord(s.key,s.modifiers);usleep(4000);}
            else if(s.type==MacroStep::Type::text)typeText(s.text);
            else usleep(useconds_t(std::min<uint32_t>(s.delay,10000))*1000);
        }
    });
}
void launch(const std::string& open,const std::string& shell){
    if(!open.empty()){NSString* target=@(open.c_str());
        dispatch_async(dispatch_get_main_queue(),^{
            NSURL* url=[target containsString:@"://"]?[NSURL URLWithString:target]:[NSURL fileURLWithPath:target.stringByExpandingTildeInPath];
            if(url)[NSWorkspace.sharedWorkspace openURL:url];
        });
    }
    if(!shell.empty()){NSString* command=@(shell.c_str());
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSTask* task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];task.arguments=@[@"-c",command];
            task.standardInput=NSFileHandle.fileHandleWithNullDevice;task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
            [task launchAndReturnError:nil];
        });
    }
}
void clearHeld(uint32_t device=0){
    heldKeys.release(device,postKey);
}
void drainKeys(){
    bool overflowed=keyOverflow.exchange(false);
    if(overflowed)clearHeld();
    size_t r=keyRead.load(std::memory_order_relaxed);
    while(r!=keyWrite.load(std::memory_order_acquire)){
        KeyWork work=keyWork[r%keyWork.size()];keyRead.store(++r,std::memory_order_release);
        if(work.release){clearHeld(work.device);continue;}
        if(!AXIsProcessTrusted()){clearHeld();continue;}
        heldKeys.update(work.device,work.buttons,work.keys,work.modifiers,postKey);
    }
    if(keyOverflow.exchange(false)||overflowed)clearHeld();
}
void submitKeyWork(const KeyWork& work){
    size_t w=keyWrite.load(std::memory_order_relaxed);
    if(w-keyRead.load(std::memory_order_acquire)==keyWork.size()){keyOverflow=true;++overflows;}
    else{keyWork[w%keyWork.size()]=work;keyWrite.store(w+1,std::memory_order_release);}
    dispatch_source_merge_data(keySource,1);
}
void releaseKeys(uint32_t device=0) {
    KeyWork work;work.release=true;work.device=device;submitKeyWork(work);
}
void closePeer(Peer& p) {
    if(p.fd<0)return;
    dispatch_source_cancel(p.reader);
    if(!p.writeActive) dispatch_resume(p.writer);
    dispatch_source_cancel(p.writer);
    p.fd=-1; // The last dispatch-source cancellation closes the descriptor.
    p.reader=nullptr;p.writer=nullptr;p.queue.clear();p.writeOffset=0;
}
void flush(Peer& p) {
    while(!p.queue.empty()) {
        const char* bytes=reinterpret_cast<const char*>(&p.queue.front());
        ssize_t n=send(p.fd,bytes+p.writeOffset,sizeof(Event)-p.writeOffset,0);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))break;
        if(n<0&&errno==EINTR)continue;
        if(n<=0){closePeer(p);return;}
        p.writeOffset+=size_t(n);
        if(p.writeOffset==sizeof(Event)){p.queue.pop();p.writeOffset=0;}
    }
    bool needsWrite=!p.queue.empty();
    if(needsWrite&&!p.writeActive){dispatch_resume(p.writer);p.writeActive=true;}
    if(!needsWrite&&p.writeActive){dispatch_suspend(p.writer);p.writeActive=false;}
}
void enqueue(Peer& p,const Event& e) {
    // Never replace a partly written front frame: append a barrier if necessary.
    // A partly written front frame is never replaced; push appends instead.
    if(!p.queue.push(e,p.writeOffset!=0)){++overflows;closePeer(p);return;}
    flush(p);
}
void applyAction(Profile& profile,Action action) {
    auto& m=profile.motion;
    switch(action){
        case Action::dominant:m.lock=m.lock==Lock::dominant?Lock::none:Lock::dominant;break;
        case Action::group:m.lock=m.lock==Lock::group?Lock::none:Lock::group;break;
        case Action::translation:m.translation=!m.translation;break;
        case Action::rotation:m.rotation=!m.rotation;break;
        case Action::pause:{bool on=m.translation||m.rotation;m.translation=m.rotation=!on;break;}
        case Action::faster:for(auto& gain:m.gain)gain=std::min(20.f,gain*1.25f);break;
        case Action::slower:for(auto& gain:m.gain)gain=std::max(.01f,gain/1.25f);break;
        case Action::resetSpeed:m.gain=profile.configuredGain;break;
        default:break;
    }
}
void route(const Event& raw) {
    ++reports;
    Profile* selected=&activeProfile;
    Profile* preview=&activePreview;
    Processor* processor=&fallbackProcessor;
    Processor* previewProcessor=&fallbackPreviewProcessor;
    uint32_t suppressed=0;
    uint32_t ignoredPrevious=0;uint32_t* previous=&ignoredPrevious;
    if(mockMode)for(size_t i=0;i<virtualDevices.size();++i)if(virtualDevices[i].device==raw.device){previous=&virtualButtonState[i];processor=&virtualProcessors[i];previewProcessor=&virtualPreviewProcessors[i];break;}
    for(auto& h:hidDevices)if(h.device&&h.decoder.state.device==raw.device){selected=&h.profile;preview=&h.preview;processor=&h.processor;previewProcessor=&h.previewProcessor;previous=&h.previousButtons;if(raw.kind==Kind::buttons)h.suppressedButtons&=raw.buttons;suppressed=h.suppressedButtons;break;}
    if(raw.kind==Kind::buttons){
        uint32_t pressed=raw.buttons&~*previous;*previous=raw.buttons;
        for(int i=0;i<32;++i)if(pressed&(1u<<i)){
            Action action=selected->actions[i];
            if(action==Action::fit){Event command=raw;command.kind=Kind::command;command.flags=0x10000;
                if(webServer)webServer->receive(command);
                for(auto& p:peers)if(p.fd>=0&&p.registered&&!p.injecting&&!p.observe&&(mockMode||p.foreground))enqueue(p,command);
            } else if(action!=Action::none){
                applyAction(*selected,action);
                if(!previewKey.empty()&&preview!=selected)applyAction(*preview,action);
            }
            if(!mockMode&&!(suppressed&(1u<<i))){
                if(!selected->macros[i].empty())runMacro(selected->macros[i]);
                if(!selected->open[i].empty()||!selected->shell[i].empty())launch(selected->open[i],selected->shell[i]);
            }
        }
    }
    Event e=processor->process(raw,selected->motion);
    e.buttons&=~suppressed;
    const uint32_t keyButtons=e.buttons;
    e.buttons&=~selected->blocked; // custom assignments own these buttons
    bool wantsMapped=false;
    for(const auto& p:peers)if(p.fd>=0&&p.registered&&p.observe&&p.mapped){wantsMapped=true;break;}
    Event mapped{};
    if(wantsMapped&&raw.kind==Kind::motion){
        // Mirror the real output, or the profile being edited when one is previewed.
        mapped=previewKey.empty()?e:previewProcessor->process(raw,preview->motion);
        mapped.flags|=Flags::processed;
    } else if(!previewKey.empty())previewProcessor->process(raw,preview->motion);
    if(webServer)webServer->receive(e);
    for(auto& p:peers) if(p.fd>=0&&p.registered&&!p.injecting) {
        if(p.observe){enqueue(p,raw);if(p.fd>=0&&p.mapped&&raw.kind==Kind::motion)enqueue(p,mapped);}
        else if(mockMode||p.foreground||raw.kind==Kind::added||raw.kind==Kind::removed||raw.kind==Kind::reset)
            enqueue(p,e);
    }
    if(raw.kind==Kind::buttons&&!mockMode) {
        KeyWork work;work.device=raw.device;work.buttons=keyButtons;work.keys=selected->keys;work.modifiers=selected->modifiers;submitKeyWork(work);
    }
    if(raw.kind==Kind::removed||raw.kind==Kind::reset)releaseKeys(raw.device);
}
void resetFocus() {for(auto& h:hidDevices)if(h.device)h.suppressedButtons=h.decoder.state.buttons;Event e;e.kind=Kind::reset;e.received=now();route(e);}
// Resolution order: app@device, app, *@device, *. Returns the matched key.
std::string resolveProfile(const std::string& bundle,uint16_t vendor,uint16_t product,bool device,Profile& out) {
    out=Profile{};
    if(!configuration)return "";
    std::string candidates[4];size_t count=0;
    char suffix[16];snprintf(suffix,sizeof(suffix),"@%04x:%04x",vendor,product);
    if(device)candidates[count++]=bundle+suffix;
    candidates[count++]=bundle;
    if(device)candidates[count++]=std::string("*")+suffix;
    candidates[count++]="*";
    for(size_t i=0;i<count;++i){auto it=configuration->profiles.find(candidates[i]);if(it!=configuration->profiles.end()){out=it->second;return it->first;}}
    return "";
}
// The settings app previews the exact profile key being edited.
void resolvePreview(uint16_t vendor,uint16_t product,bool device,const Profile& active,Profile& out) {
    if(previewKey.empty()||!configuration){out=active;return;}
    auto it=configuration->profiles.find(previewKey);
    if(it!=configuration->profiles.end())out=it->second;
    else resolveProfile(previewKey.substr(0,previewKey.find('@')),vendor,product,device,out);
}
void selectProfile() {
    activeKey=resolveProfile(foregroundBundle,0,0,false,activeProfile);
    resolvePreview(0,0,false,activeProfile,activePreview);
    for(auto& h:hidDevices)if(h.device){
        activeKey=resolveProfile(foregroundBundle,h.decoder.state.vendor,h.decoder.state.product,true,h.profile);
        resolvePreview(h.decoder.state.vendor,h.decoder.state.product,true,h.profile,h.preview);
        setLED(h,h.profile.led);
    }
}
void hidReport(void* context,IOReturn result,void*,IOHIDReportType,uint32_t reportID,uint8_t* bytes,CFIndex length) {
    uint64_t begin=now();
    if(result!=kIOReturnSuccess||length<=0||length>255)return;
    auto& h=*static_cast<HID*>(context);Event e;
    // IOKit numbered reports include the ID. Some transports omit it.
    std::array<uint8_t,256> corrected{};
    std::span<const uint8_t> report(bytes,size_t(length));
    if(bytes[0]!=reportID){corrected[0]=uint8_t(reportID);memcpy(corrected.data()+1,bytes,size_t(length));report={corrected.data(),size_t(length+1)};}
    if(h.decoder.decode(report,begin,e)){e.decoded=now();route(e);}
    else ++rejected;
}
void managerReport(void*,IOReturn result,void* sender,IOHIDReportType type,uint32_t reportID,uint8_t* bytes,CFIndex length) {
    for(auto& h:hidDevices)if(h.device==sender){hidReport(&h,result,sender,type,reportID,bytes,length);return;}
}
int property(IOHIDDeviceRef d,CFStringRef key) {
    auto n=IOHIDDeviceGetProperty(d,key);int result=0;
    if(n&&CFGetTypeID(n)==CFNumberGetTypeID())CFNumberGetValue((CFNumberRef)n,kCFNumberIntType,&result);
    return result;
}
// The Universal Receiver's primary usage is vendor-defined; its multi-axis
// collection is listed only among the interface's usage pairs.
bool multiAxis(IOHIDDeviceRef d) {
    if(property(d,CFSTR(kIOHIDPrimaryUsagePageKey))==1&&property(d,CFSTR(kIOHIDPrimaryUsageKey))==8)return true;
    auto pairs=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDDeviceUsagePairsKey));
    if(!pairs||CFGetTypeID(pairs)!=CFArrayGetTypeID())return false;
    for(NSDictionary* pair in (__bridge NSArray*)pairs)
        if([pair isKindOfClass:NSDictionary.class]&&[pair[@(kIOHIDDeviceUsagePageKey)] isEqual:@1]&&[pair[@(kIOHIDDeviceUsageKey)] isEqual:@8])return true;
    return false;
}
void added(void*,IOReturn result,void*,IOHIDDeviceRef d) {
    if(result!=kIOReturnSuccess){fprintf(stderr,"Cannot exclusively open device: 0x%x\n",result);return;}
    int vid=property(d,CFSTR(kIOHIDVendorIDKey)),pid=property(d,CFSTR(kIOHIDProductIDKey));
    if(!deviceSpec(vid,pid)||!multiAxis(d))return;
    for(auto& h:hidDevices)if(!h.device) {
        h.device=d;CFRetain(d);h.decoder=Decoder{};h.previousButtons=0;h.suppressedButtons=0;h.processor.reset();h.previewProcessor.reset();
        h.led.reset();h.requestedLED=-1;
        NSArray* elements=CFBridgingRelease(IOHIDDeviceCopyMatchingElements(d,nullptr,kIOHIDOptionsTypeNone));
        for(id item in elements){auto element=(__bridge IOHIDElementRef)item;
            if(IOHIDElementGetType(element)==kIOHIDElementTypeOutput&&IOHIDElementGetUsagePage(element)==8&&IOHIDElementGetUsage(element)==0x4b){h.led=std::make_shared<LEDOutput>(d,element);break;}
        }
        auto& e=h.decoder.state;e.device=nextDevice++;e.vendor=vid;e.product=pid;
        selectProfile();
        Event connected=e;connected.kind=Kind::added;connected.received=now();route(connected);return;
    }
}
void removed(void*,IOReturn,void*,IOHIDDeviceRef d) {
    for(auto& h:hidDevices)if(h.device==d){Event e=h.decoder.state;e.axes={};e.buttons=0;e.kind=Kind::removed;e.received=now();route(e);if(h.led)h.led->connected=false;h.led.reset();CFRelease(h.device);h.device=nullptr;return;}
}
int listener(bool control) {
    auto path=socketPath(control);auto parent=path.substr(0,path.find_last_of('/'));
    if(mkdir(parent.c_str(),0700)<0&&errno!=EEXIST)return -1;
    struct stat st{};
    if(lstat(parent.c_str(),&st)||!S_ISDIR(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&077)!=0){errno=EACCES;return -1;}
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return -1;socketOptions(fd);
    sockaddr_un a{};a.sun_family=AF_UNIX;
    if(path.size()>=sizeof(a.sun_path)){close(fd);errno=ENAMETOOLONG;return -1;}
    memcpy(a.sun_path,path.c_str(),path.size()+1);unlink(path.c_str());
    if(bind(fd,(sockaddr*)&a,sizeof(a))||chmod(path.c_str(),0600)||listen(fd,32)){close(fd);return -1;}
    return fd;
}
bool sameUser(int fd) {uid_t uid;gid_t gid;return getpeereid(fd,&uid,&gid)==0&&uid==getuid();}
void readPeer(Peer& p) {
    while(p.fd>=0) {
        ssize_t n=recv(p.fd,reinterpret_cast<char*>(&p.incoming)+p.readOffset,sizeof(Event)-p.readOffset,0);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return;
        if(n<0&&errno==EINTR)continue;
        if(n<=0){closePeer(p);return;}
        p.readOffset+=size_t(n);if(p.readOffset<sizeof(Event))continue;p.readOffset=0;
        Event e=p.incoming;
        if(!valid(e)){closePeer(p);return;}
        if(!p.registered) {
            if(e.kind!=Kind::hello){closePeer(p);return;}
            p.registered=true;p.observe=e.flags&Flags::monitor;p.injecting=e.flags&Flags::replay;p.mapped=p.observe&&(e.flags&Flags::mapped);
            if(p.injecting&&!mockMode){closePeer(p);return;}
            if(!p.injecting){
                for(const auto& h:hidDevices)if(h.device){Event a=h.decoder.state;a.kind=Kind::added;enqueue(p,a);if(p.fd<0)return;}
                for(const auto& a:virtualDevices)if(a.device){Event b=a;b.kind=Kind::added;enqueue(p,b);if(p.fd<0)return;}
            }
        } else if(p.injecting) {
            if(e.kind==Kind::hello){closePeer(p);return;}
            if(e.device){
                auto v=std::find_if(virtualDevices.begin(),virtualDevices.end(),[&](const auto& item){return item.device==e.device;});
                if(v==virtualDevices.end()&&e.kind!=Kind::removed)v=std::find_if(virtualDevices.begin(),virtualDevices.end(),[](const auto& item){return !item.device;});
                if(v!=virtualDevices.end()){
                    if(!v->device||e.kind==Kind::added||e.kind==Kind::removed){size_t index=size_t(v-virtualDevices.begin());virtualButtonState[index]=0;virtualProcessors[index].reset();virtualPreviewProcessors[index].reset();}
                    *v=e.kind==Kind::removed?Event{}:e;
                }
            }
            e.decoded=now(); // Marks service entry for optional native benchmark diagnostics.
            route(e);
        } else {closePeer(p);return;}
    }
}
void acceptEvents(int listenerFD) {
    int fd=accept(listenerFD,nullptr,nullptr);if(fd<0)return;socketOptions(fd);
    if(!sameUser(fd)){close(fd);return;}
    for(auto& p:peers)if(p.fd<0) {
        p=Peer{};p.fd=fd;
        socklen_t size=sizeof(p.pid);
        if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&p.pid,&size)){close(fd);p.fd=-1;return;}
        p.identity=sn::processIdentity(p.pid);resolveForeground(p);
        fcntl(fd,F_SETFL,O_NONBLOCK);
        int buffer=4096;setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&buffer,sizeof(buffer));
        Peer* ptr=&p;
        p.reader=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,inputQueue);
        p.writer=dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,fd,0,inputQueue);
        auto socket=std::make_shared<SocketLifetime>(fd);
        dispatch_source_set_cancel_handler(p.reader,^{(void)socket;});
        dispatch_source_set_cancel_handler(p.writer,^{(void)socket;});
        dispatch_source_set_event_handler(p.reader,^{readPeer(*ptr);});
        dispatch_source_set_event_handler(p.writer,^{flush(*ptr);});
        dispatch_resume(p.reader);return;
    }
    close(fd);
}
bool number(id x){return [x isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID()&&std::isfinite([x doubleValue]);}
bool boolean(id x){return x&&CFGetTypeID((__bridge CFTypeRef)x)==CFBooleanGetTypeID();}
// Optional fixed-size numeric array within [low, high].
bool numbers(id value,double low,double high,std::array<float,6>& out){
    if(!value)return true;
    if(![value isKindOfClass:NSArray.class]||[value count]!=6)return false;
    for(int i=0;i<6;++i){id x=value[i];if(!number(x))return false;double v=[x doubleValue];if(v<low||v>high)return false;out[size_t(i)]=float(v);}
    return true;
}
bool booleans(id value,std::array<bool,6>& out){
    if(!value)return true;
    if(![value isKindOfClass:NSArray.class]||[value count]!=6)return false;
    for(int i=0;i<6;++i){if(!boolean(value[i]))return false;out[size_t(i)]=[value[i] boolValue];}
    return true;
}
bool text(id value,NSUInteger limit){return !value||([value isKindOfClass:NSString.class]&&[value length]<=limit);}
bool parseProfile(NSDictionary* v,Profile& p){
    auto& m=p.motion;
    std::array<float,6> deadzone{},sensitivity{1,1,1,1,1,1},amount{},smoothing{},center{},range{};range.fill(nominalRange);
    if(!numbers(v[@"gain"],0,20,m.gain)||!numbers(v[@"deadzone"],0,1000,deadzone)||!booleans(v[@"invert"],m.invert)||
       !numbers(v[@"sensitivity"],0,10,sensitivity)||!numbers(v[@"curveAmount"],0,1,amount)||!numbers(v[@"smoothing"],0,500,smoothing)||
       !numbers(v[@"center"],-1000,1000,center)||!numbers(v[@"range"],10,2000,range)||!booleans(v[@"enabled"],m.enabled))return false;
    p.configuredGain=m.gain;
    for(int i=0;i<6;++i){auto& t=m.input[size_t(i)];t.deadzone=deadzone[size_t(i)];t.sensitivity=sensitivity[size_t(i)];t.curveAmount=amount[size_t(i)];
        t.smoothing=smoothing[size_t(i)];t.center=center[size_t(i)];t.range=range[size_t(i)];}
    if(id curves=v[@"curve"]){
        if(![curves isKindOfClass:NSArray.class]||[curves count]!=6)return false;
        NSArray* names=@[@"linear",@"expo",@"power",@"scurve"];
        for(int i=0;i<6;++i){id name=curves[i];if(![name isKindOfClass:NSString.class])return false;
            NSUInteger index=[names indexOfObject:name];if(index==NSNotFound)return false;m.input[size_t(i)].curve=Curve(index);}
    }
    if(id matrix=v[@"matrix"]){
        if(![matrix isKindOfClass:NSArray.class]||[matrix count]!=6)return false;
        for(int o=0;o<6;++o){std::array<float,6> row{};if(!numbers(matrix[o],-4,4,row)||!matrix[o])return false;m.matrix[size_t(o)]=row;}
    }
    for(NSString* field in @[@"dominant",@"translation",@"rotation",@"orbit",@"led"])if(v[field]&&!boolean(v[field]))return false;
    if(!text(v[@"name"],128)||!text(v[@"lock"],16))return false;
    m.lock=[v[@"dominant"] boolValue]?Lock::dominant:Lock::none;
    if(NSString* lock=v[@"lock"]){
        NSUInteger index=[@[@"none",@"dominant",@"group"] indexOfObject:lock];if(index==NSNotFound)return false;
        if(index||!v[@"dominant"])m.lock=Lock(index);
    }
    m.translation=v[@"translation"]?[v[@"translation"] boolValue]:true;
    m.rotation=v[@"rotation"]?[v[@"rotation"] boolValue]:true;
    m.orbit=v[@"orbit"]?[v[@"orbit"] boolValue]:true;
    p.led=v[@"led"]?[v[@"led"] boolValue]:true;
    NSArray* buttons=v[@"buttons"];
    if(!buttons)return true;
    if(![buttons isKindOfClass:NSArray.class]||buttons.count>32)return false;
    for(NSUInteger i=0;i<buttons.count;++i){NSDictionary* b=buttons[i];if(![b isKindOfClass:NSDictionary.class])return false;
        int kinds=0;for(NSString* field in @[@"keyCode",@"command",@"action",@"macro",@"open",@"shell"])if(b[field])++kinds;
        if(kinds>1)return false;
        if(b[@"keyCode"]){if(!number(b[@"keyCode"]))return false;double key=[b[@"keyCode"] doubleValue];if(key<0||key>127||std::floor(key)!=key)return false;p.keys[i]=[b[@"keyCode"] intValue];}
        if(b[@"modifiers"]){if(!number(b[@"modifiers"]))return false;double flags=[b[@"modifiers"] doubleValue];if(flags<0||flags>0xffffffff||std::floor(flags)!=flags)return false;p.modifiers[i]=[b[@"modifiers"] unsignedLongLongValue];}
        if(!text(b[@"command"],4096)||!text(b[@"label"],128)||!text(b[@"open"],4096)||!text(b[@"shell"],4096))return false;
        if(b[@"passthrough"]&&!boolean(b[@"passthrough"]))return false;
        if(b[@"action"]){
            if(![b[@"action"] isKindOfClass:NSString.class])return false;
            NSUInteger action=NSNotFound;for(NSUInteger a=0;a<std::size(actionNames);++a)if([b[@"action"] isEqualToString:@(actionNames[a])])action=a;
            if(action==NSNotFound)return false;p.actions[i]=Action(action);
        }
        if(NSString* open=b[@"open"])p.open[i]=open.UTF8String;
        if(NSString* shell=b[@"shell"])p.shell[i]=shell.UTF8String;
        if(id macro=b[@"macro"]){
            if(![macro isKindOfClass:NSArray.class]||[macro count]>64)return false;
            for(NSDictionary* step in macro){
                if(![step isKindOfClass:NSDictionary.class])return false;
                MacroStep s;
                if(id key=step[@"keyCode"]){double k=number(key)?[key doubleValue]:-1;if(k<0||k>127||std::floor(k)!=k)return false;s.type=MacroStep::Type::key;s.key=int(k);
                    if(id flags=step[@"modifiers"]){if(!number(flags)||[flags doubleValue]<0||[flags doubleValue]>0xffffffff)return false;s.modifiers=[flags unsignedLongLongValue];}}
                else if(id value=step[@"text"]){if(!text(value,1024))return false;s.type=MacroStep::Type::text;s.text=[value UTF8String];}
                else if(id delay=step[@"delay"]){if(!number(delay)||[delay doubleValue]<0||[delay doubleValue]>10000)return false;s.type=MacroStep::Type::delay;s.delay=uint32_t([delay doubleValue]);}
                else return false;
                if(!text(step[@"label"],128))return false;
                p.macros[i].push_back(std::move(s));
            }
        }
        // Commands reach applications through the native button event; never withhold them.
        if(b[@"passthrough"]&&![b[@"passthrough"] boolValue]&&!b[@"command"])p.blocked|=1u<<i;
    }
    return true;
}
std::unique_ptr<Configuration> parseConfig(NSDictionary* d) {
    if(![d isKindOfClass:NSDictionary.class]||!number(d[@"version"])||![d[@"version"] isEqual:@1]||![d[@"profiles"] isKindOfClass:NSDictionary.class])return nullptr;
    NSDictionary* profiles=d[@"profiles"];if(profiles.count>128)return nullptr;
    auto c=std::make_unique<Configuration>();
    c->web.enabled=!mockMode;
    NSString* webDirectory=mockMode?[settingsPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"web"]:@"/Library/Application Support/Axial/Web";
    c->web.certificate=[[webDirectory stringByAppendingPathComponent:@"server.crt"] UTF8String];
    c->web.key=[[webDirectory stringByAppendingPathComponent:@"server.key"] UTF8String];
    if(id web=d[@"web"]){
        if(![web isKindOfClass:NSDictionary.class]||(web[@"enabled"]&&!boolean(web[@"enabled"])))return nullptr;
        if(web[@"enabled"])c->web.enabled=[web[@"enabled"] boolValue];
    }
    for(NSString* key in profiles){
        if(![key isKindOfClass:NSString.class]||key.length==0||key.length>255)return nullptr;
        NSDictionary* v=profiles[key];if(![v isKindOfClass:NSDictionary.class])return nullptr;
        Profile p;
        if(!parseProfile(v,p))return nullptr;
        NSArray* buttons=v[@"buttons"];
        std::array<std::string,32> commands{};
        if(buttons)for(NSUInteger i=0;i<buttons.count;++i){NSString* command=buttons[i][@"command"];if(command)commands[i]=command.UTF8String;}
        c->web.commands.emplace(key.UTF8String,std::move(commands));
        c->profiles.emplace(key.UTF8String,p);
    }
    return c;
}
NSDictionary* status() {
    __block Snapshot snapshot;
    __block NSString* bundle;
    __block NSString* active;
    __block NSString* previewing;
    dispatch_sync(inputQueue,^{
        for(const auto& h:hidDevices)if(h.device&&snapshot.count<16){size_t i=snapshot.count++;snapshot.latest[i]=h.decoder.state;snapshot.ledSupported[i]=bool(h.led);snapshot.ledState[i]=h.led?h.led->state.load():-1;snapshot.ledError[i]=h.led?h.led->error.load():0;}
        for(const auto& e:virtualDevices)if(e.device&&snapshot.count<16)snapshot.latest[snapshot.count++]=e;
        for(const auto& p:peers)if(p.fd>=0&&p.registered)++snapshot.clients;
        snapshot.reports=reports;snapshot.overflows=overflows;snapshot.rejected=rejected;snapshot.foreground=foregroundPID;
        bundle=[NSString stringWithUTF8String:foregroundBundle.c_str()];
        active=@(activeKey.c_str());previewing=@(previewKey.c_str());
    });
    NSMutableArray* items=[NSMutableArray array];
    for(size_t i=0;i<snapshot.count;++i){const auto& e=snapshot.latest[i];auto spec=deviceSpec(e.vendor,e.product);
        NSMutableArray* axes=[NSMutableArray array];for(int16_t x:e.axes)[axes addObject:@(x)];
        [items addObject:@{@"id":@(e.device),@"vendor":@(e.vendor),@"product":@(e.product),@"name":spec?@(spec->name):@"Unknown",@"buttonCount":@(spec?spec->buttons.size():0),@"axes":axes,@"buttons":@(e.buttons),@"ledSupported":@(snapshot.ledSupported[i]),@"ledState":@(snapshot.ledState[i]),@"ledError":@(snapshot.ledError[i])}];
    }
    mach_task_basic_info_data_t memory{};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&memory),&count);
    rusage usage{};getrusage(RUSAGE_SELF,&usage);
    double cpu=usage.ru_utime.tv_sec+usage.ru_stime.tv_sec+(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6;
    auto webText=webServer->status();NSData* webData=[NSData dataWithBytes:webText.data() length:webText.size()];
    id web=[NSJSONSerialization JSONObjectWithData:webData options:0 error:nil];
    return @{@"version":@1,@"mock":@(mockMode),@"devices":items,@"clients":@(snapshot.clients),@"reports":@(snapshot.reports),@"overflows":@(snapshot.overflows),@"rejected":@(snapshot.rejected),@"foregroundPID":@(snapshot.foreground),@"foregroundApp":bundle?:@"",@"activeProfile":active?:@"",@"previewProfile":previewing?:@"",@"accessibility":@(bool(AXIsProcessTrusted())),@"residentBytes":@(memory.resident_size),@"cpuSeconds":@(cpu),@"web":web?:@{}};
}
NSDictionary* handle(NSDictionary* request) {
    NSString* op=request[@"op"];
    if([op isEqual:@"status"])return status();
    if([op isEqual:@"retryWeb"]){webServer->retry();return @{@"ok":@YES};}
    if([op isEqual:@"requestAccessibility"]){
        bool trusted=AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt:@YES});
        return @{@"trusted":@(trusted)};
    }
    if([op isEqual:@"stop"]){dispatch_async(dispatch_get_main_queue(),^{kill(getpid(),SIGTERM);});return @{@"ok":@YES};}
    if([op isEqual:@"preview"]){
        // The settings app mirrors this profile to mapped monitors while editing it.
        NSString* key=request[@"profile"];
        if(key&&![key isKindOfClass:NSString.class])return @{@"error":@"Invalid preview profile"};
        std::string value=key?key.UTF8String:"";if(value.size()>255)return @{@"error":@"Invalid preview profile"};
        dispatch_sync(inputQueue,^{if(previewKey!=value){previewKey=value;selectProfile();}});
        return @{@"ok":@YES};
    }
    if([op isEqual:@"getConfig"])return document;
    if([op isEqual:@"getCommands"])return commandCatalog;
    if([op isEqual:@"commands"]){NSString* app=request[@"app"];NSArray* commands=request[@"commands"];
        if(![app isKindOfClass:NSString.class]||app.length==0||app.length>255||![commands isKindOfClass:NSArray.class]||commands.count>4096)return @{@"error":@"Invalid commands"};
        if(!commandCatalog[app]&&commandCatalog.count>=128)return @{@"error":@"Command catalog is full"};
        for(id command in commands) {
            if(![command isKindOfClass:NSDictionary.class])return @{@"error":@"Invalid command"};
            id identifier=command[@"id"],label=command[@"label"];
            if(![identifier isKindOfClass:NSString.class]||[identifier length]==0||[identifier length]>4096||![label isKindOfClass:NSString.class]||[label length]>4096)return @{@"error":@"Invalid command"};
        }
        NSMutableDictionary* candidate=[commandCatalog mutableCopy];candidate[app]=commands;
        NSData* encoded=[NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil];
        if(!encoded||encoded.length>=1024*1024)return @{@"error":@"Command catalog exceeds the response size limit"};
        commandCatalog=candidate;return @{@"ok":@YES};
    }
    if([op isEqual:@"setConfig"]){
        NSDictionary* d=request[@"config"];auto c=parseConfig(d);
        if(!c)return @{@"error":@"Invalid version 1 configuration"};
        NSError* error=nil;NSData* data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:&error];
        if(!data||![data writeToFile:settingsPath options:NSDataWritingAtomic error:&error])return @{@"error":error.localizedDescription?:@"Could not save settings"};
        webServer->configure(c->web);
        document=[d copy];Configuration* ptr=c.release();
        // Configuration changes execute between reports, never while decoding one.
        dispatch_sync(inputQueue,^{resetFocus();configuration.reset(ptr);selectProfile();});
        return @{@"ok":@YES};
    }
    return @{@"error":@"Unknown operation"};
}
void controlLoop(int fd) {
    pthread_setname_np("Axial control");
    for(;;){int client=accept(fd,nullptr,nullptr);if(client<0){if(errno==EINTR)continue;return;}
        @autoreleasepool {
            socketOptions(client);if(!sameUser(client)){close(client);continue;}
            fcntl(client,F_SETFL,O_NONBLOCK);
            const uint64_t deadline=now()+2000000000;
            std::string input;bool complete=false;
            while(now()<deadline){
                char buffer[4096];auto n=recv(client,buffer,sizeof(buffer),0);
                if(n>0){
                    const auto* end=static_cast<const char*>(memchr(buffer,'\n',size_t(n)));
                    input.append(buffer,end?size_t(end-buffer):size_t(n));
                    if(input.size()>256*1024)break;
                    if(end){complete=true;break;}
                    continue;
                }
                if(n<0&&errno==EINTR)continue;
                if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)&&waitSocket(client,POLLIN,deadline))continue;
                break;
            }
            NSData* data=[NSData dataWithBytes:input.data() length:input.size()];
            id json=complete?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            NSDictionary* response=[json isKindOfClass:NSDictionary.class]?handle(json):@{@"error":@"Expected a JSON object"};
            NSData* bytes=[NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingSortedKeys error:nil];
            std::string output(static_cast<const char*>(bytes.bytes),bytes.length);output+='\n';
            size_t sent=0;
            while(sent<output.size()&&now()<deadline){
                auto n=send(client,output.data()+sent,output.size()-sent,0);
                if(n>0){sent+=size_t(n);continue;}
                if(n<0&&errno==EINTR)continue;
                if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)&&waitSocket(client,POLLOUT,deadline))continue;
                break;
            }
            close(client);
        }
    }
}
}
int main(int argc,char** argv) {@autoreleasepool {
    bool appOwned=false;pid_t owner=getppid();
    for(int i=1;i<argc;++i){if(std::string(argv[i])=="--mock")mockMode=true;else if(std::string(argv[i])=="--app-owned")appOwned=true;else{fprintf(stderr,"usage: axial-service [--mock] [--app-owned]\n");return 2;}}
    if(appOwned&&owner<=1){fprintf(stderr,"An owning app is required\n");return 2;}
    auto path=socketPath();auto parent=path.substr(0,path.find_last_of('/'));
    mkdir(parent.c_str(),0700);
    struct stat parentStat{};
    if(lstat(parent.c_str(),&parentStat)||!S_ISDIR(parentStat.st_mode)||parentStat.st_uid!=getuid()||(parentStat.st_mode&077)) {fprintf(stderr,"Unsafe socket directory\n");return 1;}
    int lock=open((path+".lock").c_str(),O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Axial already running or socket directory unavailable\n");return 1;}
    int events=listener(false),controls=listener(true);
    if(events<0||controls<0){perror("listen");return 1;}
    inputQueue=dispatch_queue_create("pro.jest.input",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    keyQueue=dispatch_queue_create("pro.jest.shortcuts",DISPATCH_QUEUE_SERIAL);
    macroQueue=dispatch_queue_create("pro.jest.macros",DISPATCH_QUEUE_SERIAL);
    outputQueue=dispatch_queue_create("pro.jest.output",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    keySource=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,keyQueue);
    dispatch_source_set_event_handler(keySource,^{drainKeys();});dispatch_resume(keySource);
    const char* custom=getenv("AXIAL_CONFIG");
    settingsPath=custom?@(custom):[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Axial/settings.json"];
    [[NSFileManager defaultManager] createDirectoryAtPath:settingsPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* existing=[NSData dataWithContentsOfFile:settingsPath];
    document=existing?[NSJSONSerialization JSONObjectWithData:existing options:0 error:nil]:nil;
    configuration=parseConfig(document);
    if(!configuration){document=@{@"version":@1,@"profiles":@{@"*":@{}}};configuration=parseConfig(document);}
    webServer=std::make_unique<WebServer>();webServer->configure(configuration->web);
    commandCatalog=[NSMutableDictionary dictionary];selectProfile();
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,events,0,inputQueue);
    dispatch_source_set_event_handler(source,^{acceptEvents(events);});dispatch_resume(source);
    std::thread(controlLoop,controls).detach();
    auto updateFocus=^{NSRunningApplication* app=NSWorkspace.sharedWorkspace.frontmostApplication;
        pid_t pid=app.processIdentifier;NSString* bundle=app.bundleIdentifier?:@"";
        auto identity=sn::processIdentity(pid);
        dispatch_async(inputQueue,^{if(foregroundPID!=pid||foregroundIdentity.birth!=identity.birth){resetFocus();foregroundPID=pid;foregroundIdentity=identity;foregroundBundle=bundle.UTF8String;for(auto& p:peers)if(p.fd>=0)resolveForeground(p);selectProfile();}});
    };
    id observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*){updateFocus();}];
    updateFocus();
    IOHIDManagerRef hid=nullptr;
    if(!mockMode){
        hid=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
        NSMutableArray* matching=[NSMutableArray array];
        for(const auto& device:sn::devices)[matching addObject:@{@(kIOHIDVendorIDKey):@(device.vendor),@(kIOHIDProductIDKey):@(device.product),@(kIOHIDTransportKey):@"USB",@(kIOHIDDeviceUsagePageKey):@1,@(kIOHIDDeviceUsageKey):@8}];
        IOHIDManagerSetDeviceMatchingMultiple(hid,(__bridge CFArrayRef)matching);
        IOHIDManagerRegisterDeviceMatchingCallback(hid,added,nullptr);IOHIDManagerRegisterDeviceRemovalCallback(hid,removed,nullptr);
        IOHIDManagerRegisterInputReportCallback(hid,managerReport,nullptr);
        IOHIDManagerSetDispatchQueue(hid,inputQueue);
        dispatch_sync(inputQueue,^{
            IOReturn result=IOHIDManagerOpen(hid,kIOHIDOptionsTypeSeizeDevice);
            if(result!=kIOReturnSuccess){fprintf(stderr,"Exclusive HID open failed: 0x%x. Check Input Monitoring permission.\n",result);exit(1);}
            IOHIDManagerActivate(hid);
        });
    }
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
    dispatch_source_t termination=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_t interrupt=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    auto shutdown=^{dispatch_sync(inputQueue,^{resetFocus();for(auto& p:peers)closePeer(p);for(auto& h:hidDevices)if(h.device)setLED(h,false);});dispatch_sync(outputQueue,^{});dispatch_sync(keyQueue,^{drainKeys();clearHeld();});unlink(socketPath().c_str());unlink(socketPath(true).c_str());exit(0);};
    dispatch_source_set_event_handler(termination,shutdown);dispatch_source_set_event_handler(interrupt,shutdown);
    dispatch_resume(termination);dispatch_resume(interrupt);
    // A crashed or force-quit menu-bar app must not leave a headless driver behind.
    // Kernel process-exit notification adds no polling to the input path.
    dispatch_source_t ownerExit=nullptr;
    if(appOwned){
        ownerExit=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,uintptr_t(owner),DISPATCH_PROC_EXIT,dispatch_get_main_queue());
        if(!ownerExit){fprintf(stderr,"Cannot monitor the owning app\n");shutdown();}
        dispatch_source_set_event_handler(ownerExit,shutdown);dispatch_resume(ownerExit);
        if(getppid()!=owner)shutdown();
    }
    fprintf(stderr,"Axial %s listening at %s\n",mockMode?"mock service":"USB service",socketPath().c_str());
    (void)observer;CFRunLoopRun();
    return 0;
}}
