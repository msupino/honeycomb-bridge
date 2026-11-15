# Honeycomb Xbox-mode bridge for macOS / X-Plane 12

Experimental. Not affiliated with Honeycomb Aeronautical, Microsoft or Laminar Research.

Use a Honeycomb Alpha XPC (Xbox mode) with Bravo and Charlie on the Honeycomb Xbox Hub, connected to an Apple Silicon Mac, without rewiring. A native macOS app authenticates with the device (Xbox GIP, adapted from xone), decodes raw input, and sends calibrated axes to a local X-Plane 12 plugin.

## Status (2026-11-14)

| Area | State |
| --- | --- |
| USB transport + GIP v1 authentication | Working on the test rig |
| Raw input from Alpha, Bravo, Charlie | Working (byte groups identified) |
| Pitch / roll / throttle calibration | Saved through the app |
| Rudder / toe brakes calibration | **Needs relearning**: rudder mapping suspect, right brake unmapped |
| X-Plane plugin | Loads in X-Plane 12 and answers localhost packets; **not yet tested with hardware** |
| Prop / mixture axes | Supported; learn in the app |
| Buttons & switches (64 bits) | Bound to X-Plane commands via `HoneycombInput/buttons.txt` |
| Per-engine levers, reversers, Bravo lights | Not mapped |

## Layout

```text
outputs/
  HoneycombBridge/                       Swift package + plugin source, docs, captures, calibration.json
  Honeycomb-XPlane12-plugin-arm64.zip    Built X-Plane plugin (HoneycombInput/mac_x64/HoneycombInput.xpl)
  Honeycomb-Monitor-macOS-arm64.zip      Built monitor/calibration app
  HoneycombBridge-source.zip             Source archive (predates the Nov 14 review fixes)
work/
  xone/          Linux Xbox GIP driver (reference for the auth handshake)
  xplane-sdk/    Official X-Plane SDK 4.3 (build dependency)
  xpad.c         Linux xpad driver (reference)
```

## Build and test

Requires macOS 15+, Xcode 16+.

```sh
cd outputs/HoneycombBridge
SDK=~/supino/honeycomb-bridge/work/xplane-sdk/SDK
./build-monitor.sh
./build-xplane-plugin.sh "$SDK"
./test-xplane-plugin.sh "$SDK"
swift test
```

## Quick X-Plane test

1. Quit X-Plane. Copy `outputs/HoneycombBridge/HoneycombInput` to `X-Plane 12/Resources/plugins/`, then run
   `xattr -dr com.apple.quarantine "X-Plane 12/Resources/plugins/HoneycombInput"`.
2. Run X-Plane natively (not Rosetta). Check `Log.txt` for `Honeycomb Input:` warnings.
3. Remove any X-Plane axis assignments that would fight the plugin (throttle especially).
4. Open Honeycomb Monitor → Connect → Calibrate for X-Plane; relearn rudder and both brakes; learn prop/mixture if wanted. Find button bits under *Buttons & switches*, edit `HoneycombInput/buttons.txt` in the X-Plane plugins folder, then Plugins → Honeycomb Input → Reload button map.
5. Load a stock aircraft, parked. **Plugins → Honeycomb Input → Enable calibrated input**, then enable X-Plane output in the app.
6. Check direction, centering and full travel per axis; throttle idle/full; each brake alone.
7. Turn output off and confirm normal control returns; reload the aircraft and confirm overrides are released.

## Further documentation

- [outputs/HoneycombBridge/README.md](outputs/HoneycombBridge/README.md): full project notes, tools, capture procedures
- [outputs/HoneycombBridge/XPLANE-BRIDGE.md](outputs/HoneycombBridge/XPLANE-BRIDGE.md): calibration, plugin behavior, datarefs, limits
- [outputs/HoneycombBridge/AUTHENTICATED-RESULTS.md](outputs/HoneycombBridge/AUTHENTICATED-RESULTS.md): authentication and input evidence

## Next steps

1. With the hardware connected, confirm the current plugin build loads in X-Plane (`Honeycomb Input:` lines in `Log.txt`).
2. Relearn rudder (bytes 31–32 big-endian mapping is suspect) and the right toe brake.
3. Find button/switch bits in the app and fill `buttons.txt`.
4. End-to-end flight test on a stock aircraft.
5. Later: per-engine levers, reversers, Bravo LEDs; optional virtual-HID route once Apple grants `com.apple.developer.hid.virtual.device`.

## Data in this repository

`outputs/HoneycombBridge/captures/` holds raw USB captures from the test rig (including the GIP authentication exchange), and `calibration.json` is that rig's saved mapping. They are evidence and examples, not a universal profile.

## Third-party material and licenses

| Path | Origin | License |
| --- | --- | --- |
| `outputs/HoneycombBridge/Sources/USBRead/GIPAuth.*` and related GIP code | Adapted from [xone](https://github.com/medusalix/xone) | GPL-2.0-or-later (see `outputs/HoneycombBridge/COPYING`, `NOTICE.md`) |
| `work/xone/` | Unmodified copy of [xone](https://github.com/medusalix/xone) at commit `3484f60` (git metadata removed) | GPL-2.0 (`work/xone/LICENSE`) |
| `work/xpad.c` | Linux kernel xpad driver, reference only | GPL-2.0 |
| `work/xplane-sdk/`, `work/XPSDK430.zip` | [X-Plane SDK 4.3](https://developer.x-plane.com/sdk/plugin-sdk-downloads/) | BSD-style, see `work/xplane-sdk/SDK/license.txt` |

Because the USB helper includes GPL-derived code, the project as a whole is distributed under GPL-2.0-or-later. Honeycomb, Xbox and X-Plane are trademarks of their owners; this project is not affiliated with or endorsed by them.
