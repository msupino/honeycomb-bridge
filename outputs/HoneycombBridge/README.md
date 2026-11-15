# Honeycomb Xbox-mode USB/HID bridge experiment

**November 14 result:** a native macOS authentication exchange succeeded, and isolated movement tests captured Alpha, Bravo and Charlie input through the unchanged Xbox Hub → Alpha wiring. [Reproduce the successful test](#successful-xbox-mode-capture) and see [the evidence](XONE-RESEARCH.md).

A native Apple Silicon macOS proof of concept for investigating this connection:

```text
Bravo ────┐
          ├── Honeycomb Xbox Hub ── Alpha XPC (Xbox mode) ── Mac USB host
Charlie ──┘
```

**Status:** Xbox-mode USB transport, a cryptographically verified v1 handshake and raw input from all three device groups have been demonstrated on this rig. Individual Xbox control mappings, calibrated ranges, an OS-visible virtual joystick and simulator operation are not yet validated. The included HID mapper/virtual backend currently consumes HID value events, not the newly captured Xbox payload. This is a source-level proof of concept, not an installable flight-simulator driver.

The objective is to find out whether that wiring can stay intact when changing hosts. Software cannot assume that the Xbox Hub exposes its accessories as ordinary Mac USB devices. No Honeycomb VID/PID, Xbox packet layout, initialization sequence, or authentication exchange is guessed in this project.

## What is here

| Component | Behavior |
| --- | --- |
| `honeycomb-probe` | Lists USB devices and their currently published interfaces using IOKit. With explicit VID/PID, `--descriptors` reads USB configuration/interface/endpoint descriptors without selecting a configuration; `--watch` records HID descriptors, elements, input reports, changed byte offsets, interpreted HID element values, HID arrival/removal, and USB registry changes. |
| `honeycomb-usb-read` | Explicitly selects an advertised USB configuration, opens a selected interface without seizure, captures interrupt IN packets, then attempts to restore the original configuration. Default mode sends no GIP messages; explicit research/authentication flags add source-backed initialization. |
| `honeycomb-monitor` | Native macOS UI with Alpha, Bravo and Charlie movement panels, activity plots, raw channel bars and capture saving. |
| `honeycomb-bridge` | Maps selected, observed HID element values into eight signed axes and 32 buttons. Emits normalized state as NDJSON without special entitlements. Optionally attempts a CoreHID virtual joystick with `--virtual`. |
| `examples/` | Clearly synthetic input and mappings, to test the software without hardware or entitlements. These are not Honeycomb profiles. |
| `Signing/VirtualHID.entitlements` | A declaration of the capability requested for the optional CoreHID path. It does not grant that capability. |
| `Tests/` | Range normalization, clamping, source isolation, disconnect reset, report packing, and invalid mapping tests. |

The probe opens only the selected VID/PID for input, using non-seizing HID opens. Inventory does not open devices. It sends no application-level output/feature reports or vendor-specific Xbox initialization commands. The HID stack may perform its normal enumeration and initialization.

**The probe is not a USB packet sniffer.** It cannot capture vendor-specific USB endpoint traffic through IOHIDManager. If Xbox mode has no accessible HID input service, USB metadata is still useful, but use `honeycomb-usb-read` for a bounded interrupt-IN capture. The source-backed initialization/authentication path below now works on the measured rig. Control-by-control Xbox decoding is still required.

## Similar work already exists

Research checked November 13, 2026. No verified project for the exact Alpha XPC + Xbox Hub + Bravo + Charlie path on Apple Silicon was found in the searches performed. That is a search result, not proof that none exists.

| Project / source | Relevance and limit |
| --- | --- |
| [X360MacOSReceiverBridge](https://github.com/nabekhan/X360MacOSReceiverBridge) | Close architecture: USB input decoder and optional virtual joystick on modern macOS. Its documented hardware is Xbox 360 receivers and wired Xbox 360 controllers. It does not establish Honeycomb or Xbox One/Series GIP compatibility. Its code is GPL-2.0. |
| [xone](https://github.com/medusalix/xone) | Linux Xbox One/Series accessory driver targeting Game Input Protocol. Useful protocol research if captured descriptors/traffic identify that transport. It is not a macOS driver, and its existence does not prove this Honeycomb layout or initialization. Review its license before reusing code. |
| [hidapi](https://github.com/libusb/hidapi) | Reusable HID enumeration/report access library. It needs an actual HID interface and does not translate unknown Xbox traffic. This small native probe uses IOKit directly to avoid external dependencies. |
| [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) | DriverKit virtual keyboard/mouse reference. It is not a flight joystick backend to plug in unchanged; custom DriverKit builds need appropriate signing/capabilities. |
| [360Controller](https://github.com/360Controller/360Controller) | Historical Xbox controller driver. Its README says there are no plans for Big Sur/Apple Silicon support. Not a suitable base for this Mac. |
| [Honeycomb Xbox Hub product documentation](https://flyhoneycomb.com/products/xbox-hub) | Documents the Alpha XPC/accessory connection and limits official use to Alpha XPC and Xbox. It does not document a Mac pass-through protocol. |

The current native authentication adaptation is derived from xone; see NOTICE.md and COPYING (GPL-2.0-or-later). No upstream binary or Linux module is linked. For now, there is no verified drop-in component that eliminates the hardware capture step.

## Build with Xcode tools

Requirements: Apple Silicon Mac, macOS 15+, Xcode 16+ with the macOS 15 SDK or newer, and its command-line tools selected. The optional virtual backend uses CoreHID. No Homebrew packages, kernel extensions, DriverKit extension, or Swift package downloads are needed.

In Terminal, enter this project's directory, then:

```sh
swift build -c release
swift test
.build/release/honeycomb-probe --help
.build/release/honeycomb-bridge --help
```

To use the Xcode UI, open `Package.swift`, select the `honeycomb-probe`, `honeycomb-usb-read`, or `honeycomb-bridge` executable scheme, set the destination to My Mac, and build. Put probe arguments under Product → Scheme → Edit Scheme → Run → Arguments. Run long captures and stdin pipelines from Terminal using `swift build` output. The package is the Xcode-openable source project; there is no generated `.xcodeproj` to maintain.

The Objective-C probe is built with ARC. The mapper and virtual backend are Swift. `Sources/Bridge/Model.swift` holds the report layout and mapper independently of CoreHID.

## First hardware capture

Keep Bravo and Charlie attached to the Honeycomb Xbox Hub and the Hub attached to the Alpha's dedicated Hub port. With the Alpha set to Xbox mode, connect its main USB cable to the Mac. The USB connection must have one host at a time.

1. Save a USB inventory:

   ```sh
   mkdir -p captures
   .build/release/honeycomb-probe > captures/xbox-usb.ndjson
   ```

   The initial `inventory` event reports the matching USB device count, including zero. Inspect the device names, decimal `idVendor` and `idProduct`, `registry_id`, `locationID`, and the `interfaces` array. The interface fields include class/subclass/protocol, number, alternate setting, and endpoint count **when present in the registry**. HID class is 3; vendor-specific class is 255. A vendor-specific class alone is not proof of GIP. HID IDs and USB IDs are separate registry entries; `usb_registry_id` links a HID entry to its nearest USB device.

2. Replace `YOUR_VID` and `YOUR_PID` below with the actual decimal IDs from the inventory. `0x` hexadecimal values are also accepted. No IDs are prefilled because Xbox and PC modes may enumerate differently.

   ```sh
   .build/release/honeycomb-probe --vid YOUR_VID --pid YOUR_PID --watch \
     | tee captures/xbox-controls.ndjson
   ```

   If the Hub/Bravo/Charlie appear as separate USB devices with different IDs, capture each relevant ID in a separate session as well. The tool does not silently broaden capture to other HID devices. `--watch` requires both IDs.

3. Leave controls still initially, then move **one control at a time**, returning it to neutral between movements. Record the approximate times and labels in a separate note: Alpha roll, Alpha pitch, Alpha buttons, each Bravo lever/detent/button/rotary, Charlie rudder, left brake, right brake. Press Ctrl-C to finish. The probe emits time as Unix seconds.

4. Read the evidence:

   - `hid_added` and `descriptor`: macOS exposed a HID service and descriptor.
   - `hid_open.status == 0`: the non-seizing HID open succeeded. Other numeric status values indicate an access/open failure.
   - `report`: raw **HID input** callback bytes as contiguous hex, report type/ID and length, plus changed byte offsets. The first report lists every offset. Reports are compared separately per device/type/report ID. The bytes are exactly those delivered by IOKit; no report ID byte is inserted or stripped. Sequence counters/noise can cause changes while controls are stationary.
   - `element` and `value`: usage page, usage, cookie, report ID and logical range parsed by Apple's HID stack. These are the usable inputs to the mapper. Large array values exceeding a machine integer are retained in the raw report path rather than treated as scalar values.
   - `hid_removed`: device disconnected; the mapper resets its mapped destinations.
   - `usb_added`, `usb_changed`, `usb_removed`: registry topology changes, polled once a second. A very brief reconnect can be missed. Metadata is the registry's current view, not an exhaustive USB descriptor dump or alternate-setting scan.
   - USB device present but no `hid_added`: HID input is unavailable through this tool. This does not mean the hardware has no input data.

5. Optional comparison captures: test Alpha in PC mode, then Bravo and Charlie directly on the Mac through an ordinary USB hub. These temporary cable changes establish a known baseline; they are not the proposed final wiring. Use newly enumerated IDs each time. Do not assume the Xbox Hub forwards accessories in PC mode.

If macOS blocks input access, inspect System Settings → Privacy & Security → Input Monitoring for the terminal or executable you run, and reconnect/restart the tool after granting the requested permission. Approve a USB accessory connection if macOS asks. A device already owned by another driver may still refuse access. The program does not request seizure, unload drivers, reset firmware, change SIP, or require root.

If inventory is empty, confirm the connection in System Information → USB and check the data cable, power, mode, and host connection. The initial inventory was empty; after the user connected the rig, the Alpha was detected. See the capture record below.

## Test the user-space mapper now

From the project directory:

```sh
.build/release/honeycomb-bridge --mapping examples/mapping.synthetic.json \
  < examples/input.synthetic.ndjson
```

Expected sequence: neutral, axis 0 at -32767, axis 0 at +32767, button bit 0 pressed, reset on removal, and a final neutral state at EOF. Progress/errors go to stderr; stdout contains only state JSON with `axes` and `buttons`. This demonstrates a user-space input translation pipeline without claiming there is an OS-visible controller.

For hardware, copy the synthetic mapping to `captures/mapping.json` and replace every source identifier using captured `element`/`value` events:

```json
[
  {"registryID":123,"usagePage":1,"usage":48,"cookie":7,"kind":"axis","index":0,"invert":false}
]
```

Here **123 and 7 are placeholders**, not Honeycomb identifiers. Use the HID `device.registry_id`, not the USB registry ID. Page, usage and cookie must all match. Registry IDs and cookies can change after a reconnect, mode change, or restart; regenerate/check mappings. `kind` is `axis` (index 0–7) or `button` (index 0–31). Destination indices must be unique. `invert` reverses an axis or button polarity. Buttons use nonzero as pressed; hat switches and rotary encoders need explicit future handling.

Axes use the HID logical minimum/maximum and clamp to -32767…32767. Check the actual physical endpoints: this is not calibration or deadzone compensation. Relative elements and invalid axis ranges are rejected. Unknown raw Xbox reports are never decoded by this mapper. It does not invent a control identity from a changing byte.

Replay a capture:

```sh
.build/release/honeycomb-bridge --mapping captures/mapping.json \
  < captures/xbox-controls.ndjson > captures/states.ndjson
```

Or run live after preparing a mapping:

```sh
.build/release/honeycomb-probe --vid YOUR_VID --pid YOUR_PID --watch \
  | tee captures/live.ndjson \
  | .build/release/honeycomb-bridge --mapping captures/mapping.json
```

Unmapped events are ignored. Invalid JSON/mappings fail with an error; the bridge attempts a neutral report before exiting. EOF also sends neutral. Stationary controls may not emit an initial value, so the mapper starts at neutral until events arrive. There is no inactivity timeout: silence can mean a stationary control. If a capture producer hangs without closing the pipe or reporting removal, the last state remains until stopped.

## Optional virtual HID experiment

The normal bridge mode has **no virtual HID output**. `--virtual` attempts Apple's public `CoreHID.HIDVirtualDevice` API on macOS 15+. This is a user-space path, not a bundled DriverKit driver.

[Apple's virtual device example](https://developer.apple.com/documentation/corehid/creatingvirtualdevices) describes creation, activation, delegates and input reports. Virtual creation on a stock system requires the managed [`com.apple.developer.hid.virtual.device` entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device), plus suitable signing/provisioning and applicable system permissions. Merely putting that key into a plist, ad-hoc signing, running as root, or compiling in Xcode does not grant it.

The provided entitlement plist is a declaration to use **only after** Apple grants the matching capability to your team/App ID and provisioning profile. For an approved developer build, embed the bridge executable in a macOS application target/bundle, configure its bundle identifier, team, matching provisioning profile and Code Signing Entitlements in Xcode, and sign the main executable with that capability. Launch that signed executable from Terminal to retain stdin/stdout. Confirm the actual executable's entitlements and provisioning profile match using Xcode's signing details and `codesign -d --entitlements :- PATH_TO_EXECUTABLE`. No entitlement or provisioning profile is supplied here. Do not add a restricted entitlement to the ordinary probe build.

Only once that setup exists, run the **signed executable's path** with:

```sh
PATH_TO_SIGNED_BRIDGE --mapping examples/mapping.synthetic.json --virtual \
  < examples/input.synthetic.ndjson
```

If creation fails or report dispatch throws, the bridge reports an error and exits; it does not silently claim virtual output succeeded. Even a successful dispatch is only API acceptance, not proof that X-Plane or another game sees or uses the device. A file replay exits and removes the virtual service at EOF; use the live pipeline or keep stdin open while inspecting it in another app.

The virtual descriptor is deliberately a generic prototype joystick: eight 16-bit signed axes (X, Y, Z, Rx, Ry, Rz, Slider, Dial), followed by 32 button bits, little-endian, **20 bytes with no report ID**. This is our output format, not the Honeycomb/Xbox wire format. Vendor ID 0 and product ID 1 are local prototype values, not borrowed Honeycomb/Microsoft IDs; obtain appropriate identifiers for distribution. The delegate answers input-report reads from the latest state and rejects unsupported requests. The eight-axis limit cannot represent every independent axis of the entire rig simultaneously; expand the descriptor and mapper only after measuring the source capabilities.

Verify with an independent HID enumerator and then X-Plane's joystick configuration: device enumeration, live axis motion, button press/release, disconnect, and reconnect are separate checks. Do not use presence in System Settings → Game Controllers as the sole acceptance test for a generic flight joystick.

A custom DriverKit solution is a different project with a host app, system extension, appropriate USB/HID family capabilities, signing/provisioning, and user approval. Follow [Apple's entitlement procedure](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development) for that path. This package ships no DEXT and claims no DriverKit entitlement access. This distinction also avoids relying on similarly named historical entitlement keys.

## Decision after the first capture

| Evidence | Next action |
| --- | --- |
| Alpha, Bravo and Charlie controls produce accessible HID values in Xbox mode | Create measured bindings, verify each control, then test the optional entitled virtual path only if the simulator needs translation. A simulator may already read the physical HID device directly. |
| Reports move but scalar HID values are unusable | Study the captured descriptor and labelled reports; add a decoder only for a measured report layout. |
| Only vendor-specific USB interfaces appear, or input remains silent | Use the provided bounded raw reader after identifying interface ownership/endpoints. On this rig, standard configuration and endpoint reads succeeded but returned zero packets; verified Xbox initialization or a working Windows/Xbox capture is needed next. A Linux `xone` investigation may help if GIP is actually established. No initialization packets are supplied here. |
| Alpha works but Bravo/Charlie never affect host-visible input | Determine whether the Alpha initializes/accesses its downstream devices without an Xbox session. A virtual HID backend cannot restore input the Mac never receives. |
| Xbox path remains inaccessible | Use native PC-mode connections as the fallback. A genuine multi-host USB sharing switch could reduce cable handling, but that topology and mode switching need testing with the exact hardware. A hub with per-port power buttons alone does not establish host-switching support. |

The cable-minimizing Xbox-mode wiring remains a hypothesis until the first row is demonstrated. No product purchase or zero-cable-change claim depends on this prototype.

## Validation record

Built and tested on Apple Silicon using Xcode 27.2 / Swift 6.4.2 on November 13, 2026. Debug and release builds and all five mapper unit tests passed. Synthetic replay produced the expected axis/button/disconnect states. Command-line checks passed for invalid arguments, inventory JSON, filtered watch startup, and clean Ctrl-C shutdown. After connection, physical Alpha USB descriptors were captured in Xbox mode (`294b:1904`) and PC mode (`294b:1900`). PC-mode HID open and raw report capture succeeded. The user moved Alpha, Bravo and Charlie; only the Alpha axes produced report changes in the inspected movement interval. No permission-denied hardware tests, virtual HID entitlement validation, OS-visible virtual joystick test, or simulator test were performed. The macOS 15 deployment target is declared; runtime testing on macOS 15 has not been performed.

## Connected-hardware capture record

On November 13, 2026, the user's Alpha was detected as Xbox-mode `294b:1904`, firmware bcdDevice `0x0116`, device class/subclass/protocol `ff/47/d0`. It advertised one configuration, but the selected configuration was 0 (unconfigured) when read. Interface 0 advertises interrupt OUT `0x01` and IN `0x81`, both 64-byte maximum packets. Interface 1 advertises alternate 0 without endpoints and alternate 1 with isochronous endpoints `0x08` and `0x87`. No HID service appeared. These are descriptor observations, not a decoded Xbox protocol. The probe did not select a configuration or initialize Xbox input.

After the user selected PC mode and reconnected only the main connection, the Alpha enumerated as `294b:1900` with HID class 3. Its HID descriptor exposes X/Y axes (0…4095), a hat, 35 buttons and a 53-byte vendor-defined input field. HID open succeeded and 64-byte input reports arrived. Bravo and Charlie did not enumerate as separate USB devices in this observation. During the user-confirmed test of all three devices, only the two standard Alpha axes changed; the vendor-defined payload stayed all zero. The field is deliberately left undecoded. See [the capture results](CAPTURE-RESULTS.md) for the observation and its limits.

The filtered evidence is in `captures/xbox-first-connection.ndjson`, `captures/xbox-usb-descriptors.ndjson`, `captures/pc-usb-descriptors.ndjson`, and `captures/pc-controls.ndjson`. Reproduce the configuration descriptor read with:

```sh
.build/release/honeycomb-probe --vid 0x294b --pid 0x1904 --descriptors
```

Use `0x1900` after switching to PC mode. The descriptor command requires both IDs. Configuration bytes are logged as hex and parsed into interface/endpoint metadata; `usb_selected_configuration` records the current configuration and read status. It uses the native IOKit USB compatibility interface and does not open, seize, set configuration, or send application-level output packets.

`captures/alpha-pc.mapping.json` is generated from the actual PC-mode descriptor for this connection's registry ID and cookies. It maps the two standard axes and first 32 buttons; it excludes the hat, last three buttons and unknown vendor payload. It is a measured baseline mapping, not a Bravo/Charlie profile, and must be regenerated after reconnect if identifiers change.

## Bounded raw USB input experiment

`honeycomb-usb-read` is a separate opt-in path for vendor-specific devices. Unlike the metadata/HID probe, it opens the USB device and interface and selects a USB configuration. It validates the requested configuration against advertised descriptors and finds the requested interrupt IN endpoint from pipe properties. It does not seize interfaces or detach existing drivers. All source-selection arguments are explicit, and exactly one matching VID/PID device must be present.

For the Xbox-mode descriptors actually measured on this Alpha:

```sh
.build/release/honeycomb-usb-read --vid 0x294b --pid 0x1904 \
  --configuration 1 --interface 0 --endpoint 0x81 --seconds 30 \
  > captures/xbox-raw-read.ndjson
```

Duration is 1–300 seconds; Ctrl-C also ends capture. The tool performs asynchronous interrupt reads with a run-loop deadline, aborts a pending read on shutdown, closes the interface, and attempts to restore the previous USB configuration. Status and restoration results are logged; unplug/reconnect if restoration fails. No reset, output endpoint writes, vendor requests, or guessed Xbox initialization packets are sent. This is an active endpoint read, not a passive USB bus sniffer. Only the selected endpoint is read; the isochronous interfaces are left alone.

`raw_read_started` means configuration and interface setup succeeded, while `usb_packet` records bytes actually received. `raw_read_finished.packets == 0` means no packets were received in that window, even if every setup operation succeeded. The tool does not feed unknown USB packets into the HID mapper. It cannot itself start an Xbox input session or prove downstream accessory input works.

The raw reader was built in debug and release and exercised against the connected Alpha in Xbox mode. Selecting configuration 1, opening interface 0 and queuing the interrupt IN read succeeded. The 30-second Bravo-only test returned zero packets, with lights unchanged according to the user. Pending-read abort, original-configuration restoration and close all succeeded. Argument validation and all five mapper tests passed. See `CAPTURE-RESULTS.md` and `captures/xbox-raw-read.ndjson`.

The raw reader now has explicit `--xone-setup`, `--gip-identify` and `--gip-power-on` research flags, described in [XONE-RESEARCH.md](XONE-RESEARCH.md). These are exceptions to the earlier read-only GIP tests: they add source-backed startup and, when requested, identification/ACK/power messages. Default probe/raw modes do not send those messages. The xone setup path resets the USB device. No Honeycomb flight-stick control mapping is supplied; the newer --gip-authenticate path is described below.

## Successful Xbox-mode capture

Leave Bravo and Charlie on the Xbox Hub, the Hub on the Alpha's dedicated port, and the Alpha's main connection on the Mac. Select Xbox mode.

```sh
swift build -c release
.build/release/honeycomb-usb-read --gip-self-test
.build/release/honeycomb-usb-read --vid 0x294b --pid 0x1904 \
  --configuration 1 --interface 0 --endpoint 0x81 \
  --gip-authenticate --seconds 120 > captures/authenticated-input.ndjson
```

Create `captures/` first if needed. The new flag includes xone-style setup, identification, power-on and the real handshake. It is mutually exclusive with the experimental `--gip-session-complete` shortcut. During that shortcut test the device disconnected without user intervention; the cause was not isolated, and it is not the successful path.

`gip_auth_phase` logs negotiation progress; `gip_auth_verified` specifically means that the device's finish transcript verified. `gip_auth_failed` stops the run without pretending the handshake completed. Authentication supports xone's v1 RSA/PKCS#1 path and a native P-256 v2 path; only v1 has been exercised with this Alpha. Certificate handling follows xone's device-public-key extraction and is not a general certificate trust-chain verification service. No secret session key or plaintext premaster is logged. Raw protocol messages, including public certificates and random challenges, are retained in the capture.

The subsequent movement session reused the device's initialized state: it began receiving input directly and needed no new announcement/handshake despite the tool selecting configuration again. Therefore, absence of a fresh `gip_auth_verified` event in every run does not itself indicate failure if input is already flowing. It also does not prove a new authentication exchange happened; consult the preceding captured handshake for that proof.

In the labelled session, Alpha generated 613 input packets, Bravo 720 more, and Charlie another 340. These counts and the changing field groups are evidence of downstream input reaching the Mac, not a completed control layout. Packet fields are not assigned axis names or sizes solely from those group tests. See `AUTHENTICATED-RESULTS.md` for payload byte offsets, phase boundaries and limitations.

After capture, the tool attempts to restore the previous USB configuration. This does not guarantee restoration of all device-internal authenticated state. Lights are not used as input evidence. A real USB sharing switch between the Alpha's main connection and the two hosts could build on this wiring, but switching/authentication lifecycle and Xbox return behavior have not been tested.

## Native movement monitor

Build and open the local app:

```sh
./build-monitor.sh
open "Honeycomb Monitor.app"
```

Click **Connect**, then move the controls. Each of the three panels shows the activity and byte levels of its observed channel group. **Stop capture** asks the helper to stop and restore its prior USB configuration. Closing the window also stops capture. Each connection is bounded to five minutes; connect again after it finishes. Keep only one capture process connected to the Alpha at a time.

The app writes NDJSON under `captures/` next to the app; **Show capture** reveals the log. For source-level debugging, select `honeycomb-monitor` in Xcode after opening Package.swift; build the USB reader too so it is available as a sibling executable. `build-monitor.sh` packages that reader in the app and signs the local build ad hoc. No virtual-HID capability is requested or granted by this app.

The bars are raw byte levels, so a bar can wrap rather than move smoothly like a calibrated axis. The activity plot and movement counts show changes, not control travel or force. The group assignments come from the isolated physical tests described in `AUTHENTICATED-RESULTS.md`; the UI intentionally uses channel labels rather than guessing individual control names. The first received report establishes a baseline and does not count every nonzero channel as movement.

Validate the UI parser against an existing capture without opening a window or USB session:

```sh
.build/release/honeycomb-monitor --validate-capture captures/xone-authenticated-controls-2026-11-14.ndjson
```

Ten unit tests cover the HID mapper, calibration and UI parsing/group isolation, plus the USB reader's hardware-independent GIP/auth self-tests. The actual v1 handshake and isolated group captures supply the hardware evidence; virtual output and simulator behavior remain untested.

## Bravo buttons

See [BRAVO-BUTTONS.md](BRAVO-BUTTONS.md) for PC-mode button numbers vs. the Xbox-mode bits measured here. The seven toggle switches (bits 35–41) are bound to light/pitot/avionics commands in `HoneycombInput/buttons.txt`; polarity still needs a hardware check.

## Live control view

Above the activity cards the monitor now draws the controls themselves: Alpha yoke (pitch/roll field plus a rotating wheel), six Bravo levers, and Charlie rudder and toe brakes. Raw decodes measured on the rig are used, and a saved calibration takes precedence:

| Control | Payload field |
| --- | --- |
| Alpha roll / pitch | signed 16-bit little-endian at 11 / 13 |
| Bravo levers 1–6 | 10-bit packed at 17, 19, 21, 23, 25, 27 (`v = byte[o+1] << 2 | byte[o] >> 6`) |
| Charlie toe brakes (provisional) | 10-bit packed at 29 / 31 |
| Rudder | shown only from a saved calibration; raw field not yet confirmed |

Replay a capture without hardware:

```sh
"Honeycomb Monitor.app/Contents/MacOS/honeycomb-monitor" --replay "$PWD/captures/monitor-1794684339-B962E4.ndjson"
```

## X-Plane 12 bridge prototype

The updated monitor includes a **Calibrate for X-Plane** screen and an output switch. A native arm64 plugin is built in `HoneycombInput/mac_x64/HoneycombInput.xpl`. It consumes calibrated local input directly, so no virtual HID device or DriverKit entitlement is required. This route will not add normal joystick-device entries to X-Plane's settings.

The display now targets 60 Hz, and the independent sender targets 125 Hz. USB cadence measured approximately 4 ms during active movement; end-to-end simulator latency has not been measured. X-Plane was unavailable because the user's external installation disk was disconnected. The plugin is compiled and unit-tested against a mocked host, **not yet validated in the simulator**.

See [XPLANE-BRIDGE.md](XPLANE-BRIDGE.md) for calibration, installation, current control scope, dataref/runtime limitations and verification steps. Learn and confirm each control before enabling output. Default output is off.

The first physical calibration check saved pitch and roll profiles through the UI and showed centered preview values. Other control calibration was still in progress.

**November 14 review fixes (plugin rebuilt, not yet run in X-Plane):**

- Toe brakes write `left_brake_ratio` / `right_brake_ratio` directly; `override_gearbrake` is no longer acquired, so landing gear stays under X-Plane control. Each brake works independently and returns to 0 on stale input, output off, disable or aircraft reload.
- `XPLM_MSG_PLANE_LOADED` resets the plugin only for the user's aircraft (index 0), not AI/multiplayer loads.
- `Log.txt` reports socket/bind failures (for example port 49876 in use) and missing override datarefs.
- Pitch, roll and rudder use a 2% rescaled centre deadzone.

**November 14 extension:** prop and mixture axes (learned like throttle) and 64 button/switch bits bound to X-Plane commands through `HoneycombInput/buttons.txt` (held or latching). Protocol is now `HCB2`; app and plugin must match. Verified in X-Plane 12: plugin loads and acknowledges packets; hardware not yet connected for an end-to-end test.

**Known calibration issue:** the saved rudder mapping (bytes 31–32, big-endian, maximum 16389) is suspect and the right toe brake is not mapped. Relearn Charlie before flight tests: rudder with pedals slid only, then each toe brake alone.

Install tip: after copying the plugin, clear quarantine:

```sh
xattr -dr com.apple.quarantine "X-Plane 12/Resources/plugins/HoneycombInput"
``` The app-to-plugin sender uses a separate 125 Hz timer; this is a nominal output cadence, not a measured end-to-end simulator latency. Output remains user-controlled and defaults off.
