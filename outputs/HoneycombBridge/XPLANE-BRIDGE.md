# X-Plane 12 input bridge prototype

The raw Xbox-mode input path is working on the tested rig. This version adds a calibration screen and a direct, localhost-only X-Plane plugin. **The plugin has compiled and passed mocked-host unit tests, but has not run inside X-Plane: the user's X-Plane 12 installation is on an external disk that was disconnected during development.** Do not confuse successful USB capture or the monitor's motion graphs with a completed simulator test.

## What changed for responsiveness

Recorded active USB report intervals were approximately 4 ms median (one sampled run had an 8 ms 95th percentile). That measures device-report cadence, not end-to-end latency. The original 20 Hz monitor display could add visible delay, and raw byte bars can jump/wrap when a multi-byte axis changes.

The display now targets 60 Hz. A separate serial sender runs nominally every 8 ms (125 Hz), using the latest received payload and saved calibration; it does not wait for the display timer. X-Plane drains received state before each flight-model frame. Main-thread scheduling, simulator frame rate and OS scheduling still contribute latency. No end-to-end simulator latency number is claimed.

## Calibrate in the app

1. Connect the Alpha to the Mac in Xbox mode with Bravo and Charlie still on the Xbox Hub. Open Honeycomb Monitor and click Connect.
2. Move a control once so the device supplies an initial sample, then center the yoke/rudder, put throttle at idle and release toe brakes.
3. Open **Calibrate for X-Plane**. Choose one control and click **Learn**.
4. Sweep only that control through its full range several times, then return to center/idle and click **Finish range**.
5. Check that the preview follows the intended control across its range. Use **Reverse** if necessary, then **Save mapping**. Repeat for the controls you want.

Learning compares byte/word interpretations only within the field groups observed during isolated hardware tests. It proposes a candidate from measured travel and smoothness rather than pre-filling guessed Xbox axis names. A candidate is not a protocol specification. Keep other controls still, verify every saved result, and relearn any ambiguous mapping. Mappings which overlap another saved control are rejected. Saved definitions live in `calibration.json` beside the app; normalization clamps to the learned range. No simulator input is sent during learning.

Current scope: pitch, roll, rudder, throttle, prop and mixture (each lever drives all engines), both toe brakes, and up to 64 buttons/switches bound to X-Plane commands. Independent per-engine levers, reversers, hats as axes, force feedback and Bravo lights are not mapped.

Bravo levers are 10-bit values packed into byte pairs 17/18 … 27/28 (`low byte = (v & 3) << 6`, `high byte = v >> 2`). Reading a pair as little-endian unsigned 16-bit gives `v << 6`, so the existing learner calibrates them linearly.

## Buttons and switches

The app sends button bits 0–63 = payload bytes 3–10 (bit `n` = byte `3 + n/8`, bit `n % 8`) and bits 64–87 = payload bytes 0–2 (navigation buttons, hat, fire buttons: bit `64 + 8·k + j` = byte `k`, bit `j`). The plugin maps bits to commands from `HoneycombInput/buttons.txt`:

```text
<bit> <command>                    # held: command begins when the bit sets, ends when it clears
<bit> <on command> <off command>   # latching: on fires once when set, off fires once when cleared
```

Find a bit in **Calibrate for X-Plane → Buttons & switches**: press or flip one control and note the bit that changes. Command names are listed in `X-Plane 12/Resources/plugins/Commands.txt`. After editing, choose **Plugins → Honeycomb Input → Reload button map**; `Log.txt` reports how many bindings loaded and any unknown commands. The plugin never fires commands for the state it sees first (after enable, reconnect or reload), so latching switches don't all toggle at once; on stale input it ends held commands without firing release commands. Brakes and aircraft-specific interaction need particular validation in the real simulator. The prototype is intended for a stock aircraft first; aircraft-specific systems/plugins may replace or override the standard datarefs.

## Install when the external disk is connected

Quit X-Plane. Copy the complete `HoneycombInput` folder into:

```text
X-Plane 12/Resources/plugins/HoneycombInput/mac_x64/HoneycombInput.xpl
```

The supplied plugin is Apple Silicon arm64, built for macOS 15+ against the official X-Plane SDK 4.3 headers, using the SDK 4.0 API level. Run X-Plane natively rather than under Rosetta with this build. No third-party runtime, DriverKit extension or virtual-HID entitlement is needed for the direct plugin path. It does not create entries in X-Plane's normal joystick device list.

In X-Plane, choose **Plugins → Honeycomb Input → Enable calibrated input**. In the monitor, enable **X-Plane output** after saving mappings. Both output controls default off. The app reports whether a plugin acknowledges input and how many requested controls are active; sending datagrams alone is not shown as simulator acceptance.

For the first simulator test, use a parked stock aircraft and verify direction, centering, full travel, throttle idle/full and released/pressed brakes. Disable output and check that normal simulator control returns. Confirm aircraft reload and app disconnect release the overrides before relying on the setup for a flight. These checks have not yet been performed here.

## Plugin behavior

Only saved, valid calibrated channels are transmitted. The application heartbeat carries full current state even when controls are stationary. The plugin listens only on `127.0.0.1:49876`, validates the fixed-size packet and finite ranges, and applies fresh values on X-Plane's main flight-loop thread.

Pitch, roll and yaw acquire their separate joystick overrides, preserving unmapped primary axes. The plugin does not acquire an override already enabled by another component. Toe brakes write the standard left/right brake ratios directly, without `override_gearbrake` (which would also take over the landing gear). Each brake works independently and is returned to 0 on release. Only the user's aircraft load (not AI/multiplayer loads) resets the plugin. Bipolar axes have a 2% rescaled centre deadzone. Interaction with the selected aircraft still needs in-sim verification. Throttle writes the standard throttle-handle array for all engines, without bypassing engine-control logic with a throttle-force override. Every candidate dataref is checked at runtime for existence, type and writability; unsupported paths are skipped and logged.

Disabling the plugin, disabling output, reloading an aircraft, or losing packets for more than 250 ms releases overrides this plugin acquired. The stale check runs on the flight loop, so a stalled simulator cannot execute it until its loop resumes. An app crash normally stops heartbeats and triggers that release. The sender holds the last position during ordinary stationary input; it cannot distinguish a hung USB producer from a stationary device until the producer exits or reports an error.

## Developer build and tests

Download the [official SDK](https://developer.x-plane.com/sdk/plugin-sdk-downloads/), unzip it, then run:

```sh
./build-monitor.sh
./build-xplane-plugin.sh /absolute/path/to/SDK
./test-xplane-plugin.sh /absolute/path/to/SDK
swift test
```

The SDK remains an external build dependency and is not bundled in the source archive. The binary links to X-Plane's own XPLM framework at its documented plugin-host location.

`XPlane/PluginTests.cpp` compiles with the SDK headers and mocks the XPLM API and network reads/writes. It checks frame validation, data application, stale release, disabled output, existing override conflicts and shutdown. `Tests/MonitorTests/CalibrationTests.swift` checks signed-axis candidate learning, independent eight-bit brake learning, neutral normalization, stationary rejection and invalid definitions. These are unit tests, not a substitute for loading the plugin in X-Plane.

The app-to-plugin format is ours, not the Xbox USB format: `HCB3`, mask (bits 0–7 axes, bit 8 buttons), sequence, zero reserved word, eight IEEE-754 floats (pitch, roll, yaw, throttle, left brake, right brake, prop, mixture), then three button words (96 bits, low first), all 32-bit words in network byte order, 60 bytes total. App and plugin must be from the same build. The plugin acknowledgement is `HCA1`, applied mask and sequence, 12 bytes. USB packets remain captured unchanged for investigation.

## Primary references

- [X-Plane SDK downloads and Apple Silicon support](https://developer.x-plane.com/sdk/plugin-sdk-downloads/).
- [Official control-dataref example](https://developer.x-plane.com/code-sample/control/).
- [Official override example](https://developer.x-plane.com/code-sample/override/).
- [Data access and writable-dataref rules](https://developer.x-plane.com/sdk/XPLMDataAccess/).
- [Flight-loop API and scheduling](https://developer.x-plane.com/sdk/XPLMProcessing/).
- [Throttle position versus commands](https://developer.x-plane.com/2009/04/datarefs-vs-commands-ii-which-one-should-i-use/).

## Current physical calibration notes

The user saved pitch and roll through the UI; the profiles measured full signed 16-bit ranges at the two Alpha field pairs. The pedal calibration remains provisional. The user confirmed sliding the pedals left/right without pressing toe brakes while learning rudder; a candidate was saved, but field overlap and each independent brake response still need verification. Do not treat the current profile as a finished, simulator-tested full-rig mapping. The original `calibration.json` stays beside the working app and is not shipped as a universal preset.

## settings.txt (auto-enable)

`HoneycombInput/settings.txt` holds `enabled 1` or `enabled 0`. The plugin reads it when it is enabled and after the user aircraft loads, so calibrated input comes on without using the menu. Toggling *Plugins → Honeycomb Input → Enable calibrated input* rewrites the file. The socket now binds with `SO_REUSEADDR`, and a bind failure logs the system error.
