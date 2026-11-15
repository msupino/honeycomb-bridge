#include "XPLMPlugin.h"
#include "XPLMProcessing.h"
#include "XPLMDataAccess.h"
#include "XPLMMenus.h"
#include "XPLMUtilities.h"
#include "Protocol.hpp"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <chrono>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <cerrno>

static int inputSocket = -1;
static bool enabled = false;
static XPLMMenuID menu = nullptr;
static int parentItem = -1;
static HoneycombFrame frame;
static std::chrono::steady_clock::time_point receivedAt;
static bool receivedAny = false;
static sockaddr_in sender{};

// Axis datarefs, indexed like HoneycombFrame::values.
enum { kPitch, kRoll, kYaw, kThrottle, kLeftBrake, kRightBrake, kProp, kMixture };
static XPLMDataRef axes[kAxisCount]{};
static XPLMDataRef overrides[3]{};
static bool owned[3]{};
static bool brakeWritten[2]{};
// Optional full joystick override (settings.txt "hide_mouse_box 1"): takes mouse/keyboard flight control away
// from X-Plane while live input flows, which also removes the no-joystick mouse-flying box.
static XPLMDataRef fullOverride = nullptr;
static bool fullOwned = false, hideMouseBox = false;

// Button map: bit index -> command. With only an "on" command the command is held while the
// button is held (begin/end). With an "off" command too, "on" fires once on press and "off" once
// on release, which suits latching switches.
struct ButtonBinding { XPLMCommandRef on = nullptr, off = nullptr; };
static ButtonBinding bindings[kButtonBits];
static bool buttonState[kButtonBits]{}, held[kButtonBits]{};
static bool buttonsSynced = false;
static std::string buttonMapPath, settingsPath;

static void releaseOverride(int i) {
    if (owned[i]) { XPLMSetDatai(overrides[i], 0); owned[i] = false; }
}
static void releaseBrake(int i) {
    if (brakeWritten[i] && axes[kLeftBrake + i]) XPLMSetDataf(axes[kLeftBrake + i], 0);
    brakeWritten[i] = false;
}
// Ends held commands without firing any release ("off") command; the next fresh input re-syncs.
static void releaseButtons() {
    for (size_t n = 0; n < kButtonBits; n++) if (held[n]) { XPLMCommandEnd(bindings[n].on); held[n] = false; }
    buttonsSynced = false;
}
static void releaseFull() { if (fullOwned) { XPLMSetDatai(fullOverride, 0); fullOwned = false; } }
static void releaseAll() {
    releaseFull();
    for (int i = 0; i < 3; i++) releaseOverride(i);
    releaseBrake(0); releaseBrake(1); releaseButtons();
}
static bool acquire(int i) {
    if (!overrides[i]) return false;
    if (owned[i]) return XPLMGetDatai(overrides[i]) == 1;
    if (XPLMGetDatai(overrides[i]) != 0) return false;
    XPLMSetDatai(overrides[i], 1); owned[i] = true; return true;
}
static void logLine(const std::string &text) { XPLMDebugString(("Honeycomb Input: " + text + "\n").c_str()); }

// Format, one binding per line:  <bit 0-95> <on command> [off command]   ('#' starts a comment)
static int loadButtonMap(const std::string &path) {
    releaseButtons();
    for (auto &b : bindings) b = ButtonBinding{};
    FILE *file = std::fopen(path.c_str(), "r");
    if (!file) { logLine("no button map at " + path); return 0; }
    char line[512]; int count = 0, number = 0;
    while (std::fgets(line, sizeof(line), file)) {
        number++;
        if (char *hash = std::strchr(line, '#')) *hash = 0;
        char on[256] = "", off[256] = ""; int bit = -1;
        int fields = std::sscanf(line, "%d %255s %255s", &bit, on, off);
        if (fields <= 0) continue;
        if (fields < 2 || bit < 0 || bit >= int(kButtonBits)) { logLine("button map line " + std::to_string(number) + " ignored"); continue; }
        ButtonBinding binding; binding.on = XPLMFindCommand(on);
        if (fields == 3) binding.off = XPLMFindCommand(off);
        if (!binding.on || (fields == 3 && !binding.off)) { logLine("unknown command on button map line " + std::to_string(number)); continue; }
        bindings[bit] = binding; count++;
    }
    std::fclose(file);
    logLine("loaded " + std::to_string(count) + " button bindings from " + path);
    return count;
}
static void applyButtons(const HoneycombFrame &f) {
    if (!buttonsSynced) { for (size_t n = 0; n < kButtonBits; n++) buttonState[n] = f.bit(n); buttonsSynced = true; return; } // never fire on first sight
    for (size_t n = 0; n < kButtonBits; n++) {
        bool pressed = f.bit(n);
        if (pressed == buttonState[n]) continue;
        buttonState[n] = pressed; const ButtonBinding &b = bindings[n];
        if (!b.on) continue;
        if (b.off) XPLMCommandOnce(pressed ? b.on : b.off);
        else if (pressed) { XPLMCommandBegin(b.on); held[n] = true; }
        else if (held[n]) { XPLMCommandEnd(b.on); held[n] = false; }
    }
}

// settings.txt in the plugin folder: "enabled 1" turns calibrated input on at load/enable.
// The menu item writes it, so the choice survives restarts and plugin reloads.
static bool readEnabledSetting() {
    FILE *f = std::fopen(settingsPath.c_str(), "r"); if (!f) { hideMouseBox = false; return false; }
    char key[64] = ""; int value = 0; bool on = false; hideMouseBox = false;
    while (std::fscanf(f, "%63s %d", key, &value) == 2) {
        if (!std::strcmp(key, "enabled")) on = value != 0;
        if (!std::strcmp(key, "hide_mouse_box")) hideMouseBox = value != 0;
    }
    std::fclose(f); return on;
}
static void writeEnabledSetting(bool on) {
    if (FILE *f = std::fopen(settingsPath.c_str(), "w")) { std::fprintf(f, "enabled %d\nhide_mouse_box %d\n", on ? 1 : 0, hideMouseBox ? 1 : 0); std::fclose(f); }
}
static void menuAction(void *, void *item) {
    if (item == reinterpret_cast<void *>(1)) { loadButtonMap(buttonMapPath); return; }
    enabled = !enabled; writeEnabledSetting(enabled);
    XPLMCheckMenuItem(menu, 0, enabled ? xplm_Menu_Checked : xplm_Menu_Unchecked);
    if (!enabled) releaseAll();
}
static void setAllEngines(XPLMDataRef ref, float value) {
    int count = std::min(16, XPLMGetDatavf(ref, nullptr, 0, 0));
    if (count > 0) { float values[16]; std::fill(values, values + count, value); XPLMSetDatavf(ref, values, 0, count); }
}
static float flightLoop(float, float, int, void *) {
    for (int i = 0; i < 64; i++) {
        unsigned char bytes[128]; sockaddr_in from{}; socklen_t length = sizeof(from);
        ssize_t n = recvfrom(inputSocket, bytes, sizeof(bytes), 0, reinterpret_cast<sockaddr *>(&from), &length);
        if (n < 0) break;
        HoneycombFrame incoming;
        if (from.sin_addr.s_addr != htonl(INADDR_LOOPBACK) || !decodeHoneycomb(bytes, size_t(n), incoming)) continue;
        frame = incoming; sender = from; receivedAt = std::chrono::steady_clock::now(); receivedAny = true;
    }
    bool fresh = receivedAny && std::chrono::duration<double>(std::chrono::steady_clock::now() - receivedAt).count() <= 0.25;
    uint32_t mask = enabled && fresh ? frame.mask : 0, applied = 0;
    if (hideMouseBox && fullOverride && (mask & 3) == 3) {
        if (!fullOwned && XPLMGetDatai(fullOverride) == 0) { XPLMSetDatai(fullOverride, 1); fullOwned = true; }
    } else releaseFull();
    for (int i = 0; i < 3; i++) {
        if ((mask & (1u << i)) && axes[i] && acquire(i)) {
            XPLMSetDataf(axes[i], frame.values[i]); applied |= 1u << i;
        } else releaseOverride(i);
    }
    if ((mask & (1u << kThrottle)) && axes[kThrottle]) { setAllEngines(axes[kThrottle], frame.values[kThrottle]); applied |= 1u << kThrottle; }
    // Toe brakes: written directly (no override_gearbrake, which would also take over the landing gear).
    // Each brake is independent; on release it is returned to 0 so a lost link never leaves brakes applied.
    for (int b = 0; b < 2; b++) {
        if ((mask & (1u << (kLeftBrake + b))) && axes[kLeftBrake + b]) {
            XPLMSetDataf(axes[kLeftBrake + b], frame.values[kLeftBrake + b]); brakeWritten[b] = true; applied |= 1u << (kLeftBrake + b);
        } else releaseBrake(b);
    }
    for (int i : {kProp, kMixture}) {
        if ((mask & (1u << i)) && axes[i]) { XPLMSetDataf(axes[i], frame.values[i]); applied |= 1u << i; }
    }
    if (mask & kButtonsValid) { applyButtons(frame); applied |= kButtonsValid; }
    else releaseButtons();
    if (fresh) {
        unsigned char acknowledgement[12] = {'H','C','A','1'};
        writeNetwork32(acknowledgement + 4, applied); writeNetwork32(acknowledgement + 8, frame.sequence);
        sendto(inputSocket, acknowledgement, sizeof(acknowledgement), 0, reinterpret_cast<const sockaddr *>(&sender), sizeof(sender));
    }
    return -1;
}
PLUGIN_API int XPluginStart(char *name, char *signature, char *description) {
    std::snprintf(name, 256, "Honeycomb Input POC");
    std::snprintf(signature, 256, "local.honeycomb.input.poc");
    std::snprintf(description, 256, "Calibrated local Honeycomb input through the Xbox Hub");
    XPLMEnableFeature("XPLM_USE_NATIVE_PATHS", 1);
    const char *names[kAxisCount] = {"sim/joystick/yoke_pitch_ratio", "sim/joystick/yoke_roll_ratio", "sim/joystick/yoke_heading_ratio",
        "sim/cockpit2/engine/actuators/throttle_ratio", "sim/cockpit2/controls/left_brake_ratio", "sim/cockpit2/controls/right_brake_ratio",
        "sim/cockpit2/engine/actuators/prop_ratio_all", "sim/cockpit2/engine/actuators/mixture_ratio_all"};
    for (int i = 0; i < int(kAxisCount); i++) {
        axes[i] = XPLMFindDataRef(names[i]);
        int type = i == kThrottle ? xplmType_FloatArray : xplmType_Float;
        if (!axes[i] || !XPLMCanWriteDataRef(axes[i]) || !(XPLMGetDataRefTypes(axes[i]) & type)) {
            logLine(std::string("unavailable/incompatible control dataref: ") + names[i]); axes[i] = nullptr;
        }
    }
    fullOverride = XPLMFindDataRef("sim/operation/override/override_joystick");
    if (fullOverride && (!XPLMCanWriteDataRef(fullOverride) || !(XPLMGetDataRefTypes(fullOverride) & xplmType_Int))) fullOverride = nullptr;
    const char *overrideNames[] = {"sim/operation/override/override_joystick_pitch", "sim/operation/override/override_joystick_roll",
        "sim/operation/override/override_joystick_heading"};
    for (int i = 0; i < 3; i++) {
        overrides[i] = XPLMFindDataRef(overrideNames[i]);
        if (!overrides[i] || !XPLMCanWriteDataRef(overrides[i]) || !(XPLMGetDataRefTypes(overrides[i]) & xplmType_Int)) {
            logLine(std::string("unavailable override dataref: ") + overrideNames[i]); overrides[i] = nullptr;
        }
    }
    // buttons.txt lives in the plugin folder: <...>/HoneycombInput/buttons.txt (the .xpl is in mac_x64/).
    char path[1024] = "";
    XPLMGetPluginInfo(XPLMGetMyID(), nullptr, path, nullptr, nullptr);
    std::string folder(path);
    for (int up = 0; up < 2; up++) { auto slash = folder.find_last_of('/'); if (slash != std::string::npos) folder.erase(slash); }
    buttonMapPath = folder + "/buttons.txt";
    settingsPath = folder + "/settings.txt";
    loadButtonMap(buttonMapPath);
    parentItem = XPLMAppendMenuItem(XPLMFindPluginsMenu(), "Honeycomb Input", nullptr, 1);
    menu = XPLMCreateMenu("Honeycomb Input", XPLMFindPluginsMenu(), parentItem, menuAction, nullptr);
    XPLMAppendMenuItem(menu, "Enable calibrated input", reinterpret_cast<void *>(0), 1); XPLMCheckMenuItem(menu, 0, xplm_Menu_Unchecked);
    XPLMAppendMenuItem(menu, "Reload button map", reinterpret_cast<void *>(1), 1);
    return 1;
}
PLUGIN_API int XPluginEnable() {
    inputSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (inputSocket < 0) { logLine("socket() failed"); return 0; }
    if (fcntl(inputSocket, F_SETFL, O_NONBLOCK) < 0) { close(inputSocket); inputSocket = -1; return 0; }
    int one = 1; setsockopt(inputSocket, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_len = sizeof(address);
    address.sin_port = htons(49876); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(inputSocket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) < 0) {
        logLine(std::string("cannot bind 127.0.0.1:49876: ") + std::strerror(errno) + "; plugin not enabled"); close(inputSocket); inputSocket = -1; return 0;
    }
    enabled = readEnabledSetting(); receivedAny = false;
    if (menu) XPLMCheckMenuItem(menu, 0, enabled ? xplm_Menu_Checked : xplm_Menu_Unchecked);
    if (enabled) logLine("calibrated input enabled from settings.txt");
    XPLMRegisterFlightLoopCallback(flightLoop, -1, nullptr); return 1;
}
PLUGIN_API void XPluginDisable() {
    enabled = false; releaseAll();
    XPLMUnregisterFlightLoopCallback(flightLoop, nullptr);
    if (inputSocket >= 0) { close(inputSocket); inputSocket = -1; }
}
PLUGIN_API void XPluginStop() {
    releaseAll();
    if (menu) XPLMDestroyMenu(menu);
    if (parentItem >= 0) XPLMRemoveMenuItem(XPLMFindPluginsMenu(), parentItem);
}
PLUGIN_API void XPluginReceiveMessage(XPLMPluginID, int message, void *param) {
    // PLANE_LOADED also fires for AI/multiplayer aircraft; only the user's aircraft (index 0) resets input.
    // Release overrides on aircraft load; re-apply the saved enable setting.
    if (message == XPLM_MSG_PLANE_LOADED && reinterpret_cast<intptr_t>(param) == 0) {
        releaseAll(); receivedAny = false; enabled = readEnabledSetting();
        XPLMCheckMenuItem(menu, 0, enabled ? xplm_Menu_Checked : xplm_Menu_Unchecked);
    }
}
