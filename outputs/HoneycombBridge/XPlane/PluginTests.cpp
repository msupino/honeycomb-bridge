#include "Plugin.cpp"
#include <cassert>
#include <deque>
#include <map>
#include <string>
#include <vector>
#include <limits>

struct MockRef { int type = xplmType_Float; int integer = 0; float value = 0; std::vector<float> array = {0,0}; };
static std::map<std::string, MockRef> references;
static std::deque<std::vector<unsigned char>> datagrams;
static uint32_t appliedMask = 0;
struct MockCommand { std::string name; int begins = 0, ends = 0, onces = 0; };
static std::map<std::string, MockCommand> commands;
static const char *pluginPath = "/tmp/hcb-test/HoneycombInput/mac_x64/HoneycombInput.xpl";
extern "C" {
XPLMDataRef XPLMFindDataRef(const char *name) {
    auto &ref = references[name];
    ref.type = std::strstr(name, "override/") ? xplmType_Int : std::strstr(name, "throttle_ratio") ? xplmType_FloatArray : xplmType_Float;
    return &ref;
}
int XPLMCanWriteDataRef(XPLMDataRef) { return 1; }
XPLMDataTypeID XPLMGetDataRefTypes(XPLMDataRef ref) { return static_cast<MockRef *>(ref)->type; }
int XPLMGetDatai(XPLMDataRef ref) { return static_cast<MockRef *>(ref)->integer; }
void XPLMSetDatai(XPLMDataRef ref, int value) { static_cast<MockRef *>(ref)->integer = value; }
void XPLMSetDataf(XPLMDataRef ref, float value) { static_cast<MockRef *>(ref)->value = value; }
int XPLMGetDatavf(XPLMDataRef ref, float *, int, int) { return int(static_cast<MockRef *>(ref)->array.size()); }
void XPLMSetDatavf(XPLMDataRef ref, float *values, int start, int count) { auto &array = static_cast<MockRef *>(ref)->array; for (int i=0;i<count;i++) array.at(start+i)=values[i]; }
XPLMCommandRef XPLMFindCommand(const char *name) {
    if (std::strncmp(name, "sim/", 4)) return nullptr;
    auto &c = commands[name]; c.name = name; return &c;
}
void XPLMCommandBegin(XPLMCommandRef c) { static_cast<MockCommand *>(c)->begins++; }
void XPLMCommandEnd(XPLMCommandRef c) { static_cast<MockCommand *>(c)->ends++; }
void XPLMCommandOnce(XPLMCommandRef c) { static_cast<MockCommand *>(c)->onces++; }
XPLMPluginID XPLMGetMyID() { return 1; }
void XPLMGetPluginInfo(XPLMPluginID, char *, char *path, char *, char *) { std::strcpy(path, pluginPath); }
void XPLMEnableFeature(const char *, int) {}
XPLMMenuID XPLMFindPluginsMenu() { return reinterpret_cast<void *>(1); }
int XPLMAppendMenuItem(XPLMMenuID, const char *, void *, int) { return 0; }
XPLMMenuID XPLMCreateMenu(const char *, XPLMMenuID, int, XPLMMenuHandler_f, void *) { return reinterpret_cast<void *>(2); }
void XPLMCheckMenuItem(XPLMMenuID, int, XPLMMenuCheck) {}
void XPLMDestroyMenu(XPLMMenuID) {}
void XPLMRemoveMenuItem(XPLMMenuID, int) {}
void XPLMDebugString(const char *) {}
void XPLMRegisterFlightLoopCallback(XPLMFlightLoop_f, float, void *) {}
void XPLMUnregisterFlightLoopCallback(XPLMFlightLoop_f, void *) {}
ssize_t recvfrom(int, void *buffer, size_t capacity, int, sockaddr *address, socklen_t *) {
    if (datagrams.empty()) return -1;
    auto packet = datagrams.front(); datagrams.pop_front(); assert(packet.size() <= capacity);
    std::memcpy(buffer, packet.data(), packet.size());
    auto *source = reinterpret_cast<sockaddr_in *>(address); source->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return ssize_t(packet.size());
}
ssize_t sendto(int, const void *buffer, size_t count, int, const sockaddr *, socklen_t) {
    assert(count == 12); appliedMask = readNetwork32(static_cast<const unsigned char *>(buffer) + 4); return ssize_t(count);
}
}
static std::vector<unsigned char> packet(uint32_t mask, uint64_t buttons = 0, uint32_t high = 0) {
    std::vector<unsigned char> data(kFrameLength); std::memcpy(data.data(), "HCB3", 4); writeNetwork32(data.data()+4,mask);
    const float values[kAxisCount] = {-0.5f,0.5f,0,0.75f,0.25f,0.5f,0.6f,0.9f};
    for (size_t i=0;i<kAxisCount;i++) { uint32_t bits; std::memcpy(&bits,&values[i],4);writeNetwork32(data.data()+16+4*i,bits); }
    writeNetwork32(data.data()+16+4*kAxisCount, uint32_t(buttons)); writeNetwork32(data.data()+20+4*kAxisCount, uint32_t(buttons >> 32)); writeNetwork32(data.data()+24+4*kAxisCount, high);
    return data;
}
static float value(int axis) { return static_cast<MockRef *>(axes[axis])->value; }
static void loop(std::vector<unsigned char> p) { datagrams.push_back(p); flightLoop(0,0,0,nullptr); }

int main() {
    std::system("mkdir -p /tmp/hcb-test/HoneycombInput/mac_x64");
    FILE *map = std::fopen("/tmp/hcb-test/HoneycombInput/buttons.txt", "w");
    std::fputs("# test map\n0 sim/flight_controls/flaps_down\n9 sim/lights/landing_lights_on sim/lights/landing_lights_off  # latching\n"
               "70 sim/flight_controls/brakes_regular\n99 sim/bad/bit\n3 not/a/command\n\n", map);
    std::fclose(map);
    char name[256], signature[256], description[256]; assert(XPluginStart(name,signature,description)==1);
    assert(buttonMapPath == "/tmp/hcb-test/HoneycombInput/buttons.txt");
    assert(bindings[0].on && !bindings[0].off && bindings[9].on && bindings[9].off && !bindings[3].on && bindings[70].on);
    inputSocket = -1; enabled = true;

    // Axes
    loop(packet(255));
    assert(appliedMask==255 && XPLMGetDatai(overrides[0])==1);
    assert(value(kPitch)==-0.5f && value(kLeftBrake)==0.25f && value(kRightBrake)==0.5f && value(kProp)==0.6f && value(kMixture)==0.9f);
    assert(static_cast<MockRef *>(axes[kThrottle])->array[1]==0.75f);
    receivedAt=std::chrono::steady_clock::now()-std::chrono::seconds(1);flightLoop(0,0,0,nullptr);
    for (int i=0;i<3;i++) assert(XPLMGetDatai(overrides[i])==0);
    assert(value(kLeftBrake)==0 && value(kRightBrake)==0);
    enabled=false;loop(packet(255));assert(appliedMask==0);
    enabled=true;XPLMSetDatai(overrides[1],1);loop(packet(2));
    assert(appliedMask==0 && XPLMGetDatai(overrides[1])==1 && !owned[1]);
    XPLMSetDatai(overrides[1],0);
    loop(packet(1));assert(appliedMask==1);
    loop(packet(16));assert(appliedMask==16 && value(kLeftBrake)==0.25f);

    // Buttons: first sight never fires, held command begins/ends, latching fires on/off once.
    auto &flaps = commands["sim/flight_controls/flaps_down"], &on = commands["sim/lights/landing_lights_on"], &off = commands["sim/lights/landing_lights_off"];
    loop(packet(kButtonsValid, 1ull << 9)); assert(appliedMask==kButtonsValid && on.onces==0 && off.onces==0);
    loop(packet(kButtonsValid, 1ull << 9 | 1)); assert(flaps.begins==1 && flaps.ends==0);
    loop(packet(kButtonsValid, 1)); assert(off.onces==1 && on.onces==0);
    loop(packet(kButtonsValid, 1ull << 9 | 1)); assert(on.onces==1);
    loop(packet(kButtonsValid, 1ull << 9)); assert(flaps.ends==1);
    loop(packet(kButtonsValid, 1ull << 9 | 1)); assert(flaps.begins==2);
    receivedAt=std::chrono::steady_clock::now()-std::chrono::seconds(1);flightLoop(0,0,0,nullptr);
    assert(flaps.ends==2 && !held[0] && !buttonsSynced && off.onces==1);  // stale: end held, no release fired

    // High bits (payload bytes 0-2): bit 70 = byte 0 bit 6
    auto &brk = commands["sim/flight_controls/brakes_regular"];
    loop(packet(kButtonsValid)); loop(packet(kButtonsValid, 0, 1u << 6)); assert(brk.begins==1);
    loop(packet(kButtonsValid)); assert(brk.ends==1);
    enabled=true;XPluginReceiveMessage(0,XPLM_MSG_PLANE_LOADED,reinterpret_cast<void *>(1));assert(enabled);
    XPluginReceiveMessage(0,XPLM_MSG_PLANE_LOADED,nullptr);assert(!enabled);

    HoneycombFrame test;auto bad=packet(512);assert(!decodeHoneycomb(bad.data(),bad.size(),test));
    bad=packet(1);writeNetwork32(bad.data()+16,0x7fc00000);assert(!decodeHoneycomb(bad.data(),bad.size(),test));
    assert(!decodeHoneycomb(bad.data(),40,test));
    auto good=packet(kMaskAll, 0x8000000000000001ull, 0x00800001u);assert(decodeHoneycomb(good.data(),good.size(),test) && test.buttons==0x8000000000000001ull && test.bit(64) && test.bit(87) && !test.bit(65));
    XPluginDisable();XPluginStop();
    for (int i=0;i<3;i++) assert(!owned[i]);
    std::puts("Plugin unit tests passed: decode, axes incl. prop/mixture, stale release, independent brakes, button map parsing, held and latching buttons, AI plane-load filter, override conflict, shutdown.");
}
