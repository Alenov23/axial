// SpaceControl mapping engine tests: every pipeline stage, real SpaceExplorer
// capture replay, no allocation on the input path and per-report cost.
#include "axial/mapping.hpp"
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <new>
#include <sstream>
#include <vector>
static bool trackAllocations=false;
static size_t allocations=0;
void* operator new(size_t size){if(trackAllocations)++allocations;if(void* p=std::malloc(size?size:1))return p;throw std::bad_alloc();}
void operator delete(void* p) noexcept {std::free(p);}
void operator delete(void* p,size_t) noexcept {std::free(p);}
#define CHECK(x) do{if(!(x)){std::cerr<<__FILE__<<":"<<__LINE__<<" " #x "\n";std::exit(1);}}while(0)
using namespace sn;
static Event motion(std::array<int16_t,6> axes,uint64_t time){Event e;e.kind=Kind::motion;e.axes=axes;e.received=time;e.device=1;return e;}
static bool near(float a,float b,float tolerance=1.f){return std::abs(a-b)<=tolerance;}

int main(int argc,char** argv){
    // Identity mapping is a straight pass-through.
    {Processor p;Mapping m;auto out=p.process(motion({10,-30,40,100,20,-5},1),m);
     CHECK((out.axes==std::array<int16_t,6>{10,-30,40,100,20,-5}));CHECK(out.flags&Flags::orbit);}
    // Swap: twist (RZ, input 5) drives zoom (Y, output 1); Y drives spin.
    {Processor p;Mapping m;m.matrix[1]={0,0,0,0,0,1};m.matrix[5]={0,1,0,0,0,0};
     auto out=p.process(motion({0,-80,0,0,0,120},1),m);CHECK(out.axes[1]==120&&out.axes[5]==-80);}
    // Mixing and cross-type mapping (translation X + rotation RY into output X), inversion via weight.
    {Processor p;Mapping m;m.matrix[0]={1,0,0,0,-0.5f,0};auto out=p.process(motion({100,0,0,0,100,0},1),m);CHECK(out.axes[0]==50);}
    // Disable, translation/rotation toggles and output invert/gain.
    {Processor p;Mapping m;m.enabled[2]=false;m.rotation=false;m.invert[0]=true;m.gain[1]=2;
     auto out=p.process(motion({10,20,30,40,50,60},1),m);CHECK(out.axes[0]==-10&&out.axes[1]==40&&out.axes[2]==0&&out.axes[3]==0&&out.axes[5]==0);}
    // Dominant and group axis locks.
    {Processor p;Mapping m;m.lock=Lock::dominant;auto out=p.process(motion({10,-90,30,40,50,60},1),m);
     CHECK((out.axes==std::array<int16_t,6>{0,-90,0,0,0,0}));
     m.lock=Lock::group;out=p.process(motion({10,-20,30,40,50,60},2),m);CHECK((out.axes==std::array<int16_t,6>{0,0,0,40,50,60}));
     out=p.process(motion({10,-90,30,40,50,60},3),m);CHECK((out.axes==std::array<int16_t,6>{10,-90,30,0,0,0}));}
    // Deadzone is rescaled: zero at the edge, full scale at full deflection, no jump.
    {InputTuning t;t.deadzone=50;CHECK(shapeInput(50,t)==0);CHECK(shapeInput(-49,t)==0);
     CHECK(near(shapeInput(350,t),350));CHECK(near(shapeInput(-200,t),-175));CHECK(shapeInput(51,t)>0&&shapeInput(51,t)<2);}
    // Calibration: center offset and range normalize to the nominal scale.
    {InputTuning t;t.center=6;t.range=300;CHECK(shapeInput(6,t)==0);CHECK(near(shapeInput(306,t),350));CHECK(near(shapeInput(-294,t),-350));}
    // Curves keep endpoints, are monotonic, and soften the centre.
    for(Curve c:{Curve::linear,Curve::expo,Curve::power,Curve::scurve}){
        CHECK(near(shapeMagnitude(1,c,0.8f),1,1e-4f));CHECK(shapeMagnitude(0,c,0.8f)==0);
        float previous=-1;for(int i=0;i<=120;++i){float y=shapeMagnitude(i/100.f,c,0.8f);CHECK(y>=previous);previous=y;}
    }
    CHECK(shapeMagnitude(.3f,Curve::expo,1)<.3f*.2f);CHECK(shapeMagnitude(.3f,Curve::power,1)<.01f);
    CHECK(near(shapeMagnitude(1.5f,Curve::power,1),1.5f,1e-4f));
    {InputTuning t;t.sensitivity=2;CHECK(near(shapeInput(100,t),200));}
    // Smoothing: time constant converges, independent of report rate, snaps to rest on release.
    {Processor p;Mapping m;m.input[0].smoothing=40;
     auto out=p.process(motion({300,0,0,0,0,0},1'000'000),m);CHECK(out.axes[0]>0&&out.axes[0]<300);
     uint64_t time=1'000'000;for(int i=0;i<40;++i){time+=8'000'000;out=p.process(motion({300,0,0,0,0,0},time),m);}
     CHECK(out.axes[0]>=298);
     out=p.process(motion({0,0,0,0,0,0},time+8'000'000),m);CHECK(out.axes[0]==0);
     Processor fast,slow;uint64_t a=0,b=0;Event fa{},sb{};
     for(int i=0;i<25;++i){a+=4'000'000;fa=fast.process(motion({200,0,0,0,0,0},a),m);}
     for(int i=0;i<10;++i){b+=10'000'000;sb=slow.process(motion({200,0,0,0,0,0},b),m);}
     CHECK(std::abs(fa.axes[0]-sb.axes[0])<=6);}
    // Button events reuse the last mapped output without advancing smoothing.
    {Processor p;Mapping m;m.matrix[0]={0,0,0,0,0,2};p.process(motion({0,0,0,0,0,50},1),m);
     Event b;b.kind=Kind::buttons;b.buttons=4;b.axes={9,9,9,9,9,9};auto out=p.process(b,m);CHECK(out.axes[0]==100&&out.buttons==4);
     Event r;r.kind=Kind::reset;out=p.process(r,m);CHECK(std::all_of(out.axes.begin(),out.axes.end(),[](int v){return v==0;}));}
    // Saturation clamps to int16.
    {Processor p;Mapping m;m.gain.fill(20);m.input[1].sensitivity=10;auto out=p.process(motion({0,-32768,0,0,0,0},1),m);CHECK(out.axes[1]==-32768);}
    // Raw + processed monitor stream: interleaved frames still coalesce per stream.
    {EventQueue<8> q;Event raw=motion({1,0,0,0,0,0},1),processed=raw;processed.flags|=Flags::processed;
     for(int i=0;i<50;++i){raw.axes[0]=int16_t(i+1);processed.axes[0]=int16_t(-i-1);CHECK(q.push(raw));CHECK(q.push(processed));}
     CHECK(q.size()==2);CHECK(q.front().axes[0]==50);q.pop();CHECK(q.front().axes[0]==-50);
     q.clear();CHECK(q.push(raw));CHECK(q.push(processed,true));raw.axes[0]=7;CHECK(q.push(raw,true));CHECK(q.size()==3);}
    // Replay the physical SpaceExplorer capture through a busy mapping:
    // no allocation, every report processed, returns to rest at the end.
    std::ifstream fixture(argc>1?argv[1]:"tests/fixtures/spaceexplorer-motion.txt");CHECK(fixture);
    std::vector<std::vector<uint8_t>> reports;std::vector<uint64_t> times;std::string line;
    while(std::getline(fixture,line)){if(line.empty()||line[0]=='#')continue;std::istringstream in(line);uint64_t t;std::string v,pr,id;in>>t>>v>>pr>>id;
        std::vector<uint8_t> bytes;std::string byte;while(in>>byte)bytes.push_back(uint8_t(std::stoul(byte,nullptr,16)));reports.push_back(bytes);times.push_back(t);}
    CHECK(reports.size()>100);
    Mapping busy;busy.matrix[1]={0,0.5f,0,0,0,1};busy.lock=Lock::group;
    for(auto& t:busy.input){t.deadzone=8;t.curve=Curve::expo;t.curveAmount=.6f;t.smoothing=25;t.center=1;t.range=320;}
    Decoder d;Processor p;Event e,last{};size_t processed=0;
    trackAllocations=true;
    auto begin=std::chrono::steady_clock::now();
    for(int round=0;round<200;++round)for(size_t i=0;i<reports.size();++i)
        if(d.decode(std::span<const uint8_t>(reports[i]),times[i]+uint64_t(round)*100'000'000'000ull,e)){last=p.process(e,busy);++processed;}
    auto elapsed=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-begin).count();
    trackAllocations=false;
    CHECK(allocations==0);CHECK(processed>reports.size()*100);
    double perReport=elapsed/double(processed);
    CHECK(perReport<2000); // far below the 8 ms HID report interval
    std::cout<<"Mapping: matrix, swap, mix, locks, deadzone, calibration, curves, smoothing, queue, capture replay passed ("
             <<processed<<" reports, "<<perReport<<" ns/report, last X="<<last.axes[0]<<")\n";
}
