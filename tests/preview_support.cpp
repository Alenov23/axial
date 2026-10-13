// Test-only injection into the real preview buffer; never linked into Axial.
#include "../app/bridge.cpp"
extern "C" void AxialTestInput(double value) {
    sn::Event event;event.kind=sn::Kind::motion;event.device=1;
    event.vendor=0x046d;event.product=0xc627;event.received=sn::now();
    event.axes[0]=int16_t(value);event.axes[3]=int16_t(value);
    preview.receive(event);
}
// Post-mapping frame as mirrored by the service for monitor|mapped peers.
extern "C" void AxialTestMapped(double value) {
    sn::Event event;event.kind=sn::Kind::motion;event.device=1;event.flags|=sn::Flags::processed;
    event.vendor=0x046d;event.product=0xc627;event.received=sn::now();
    event.axes[0]=int16_t(value);event.axes[3]=int16_t(value);
    preview.receive(event);
}
// Device reset: clears raw and mapped state without removing the device.
extern "C" void AxialTestReset() {
    sn::Event event;event.kind=sn::Kind::reset;event.device=1;event.received=sn::now();
    preview.receive(event);
}
