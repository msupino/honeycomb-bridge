# Virtual joysticks (native X-Plane detection)

Honeycomb Monitor can present the Xbox-mode Alpha, Bravo and Charlie to macOS as the **original PC-mode USB
devices**, so X-Plane (or any simulator) detects them natively and uses its own Honeycomb profiles. The X-Plane
plugin is not needed in this mode.

```
Alpha (Xbox mode) ─USB─▶ honeycomb-usb-read ─▶ Honeycomb Monitor ─HCV1 / UDP 49877─▶ Honeycomb Virtual HID ─▶ macOS HID ─▶ X-Plane
   + Xbox Hub, Bravo, Charlie                  (mapping to PC buttons)               (CoreHID HIDVirtualDevice)
```

| Virtual device | VID:PID | Elements |
| --- | --- | --- |
| Alpha Flight Controls | 294B:1900 | 35 buttons, 8-way hat, X/Y 0–4095 |
| Bravo Throttle Quadrant | 294B:1901 | 48 buttons, 6 lever axes (X, Y, Z, Rx, Ry, Rz) 0–4095 |
| Charlie Rudder Pedal | 294B:1903 | X = left brake, Y = right brake, Z = rudder, 0–1023 |

Elements follow the PC-mode devices (Alpha taken from `captures/pc-controls.ndjson`); the report byte layout is this
project's own. Button numbers are PC-mode: Alpha per FlightGear's bindings, Bravo per RoystonS/honeycomb
(see `BRAVO-BUTTONS.md` and `Sources/Monitor/VirtualJoystickMapping.swift`).

## Use

1. Build with `./build-monitor.sh` (also builds and bundles `Honeycomb Virtual HID.app`).
2. In Honeycomb Monitor: **Connect**, then switch on **Virtual joysticks** (this turns off *X-Plane output*).
3. First time only: allow **Honeycomb Virtual HID** in System Settings → Privacy & Security → **Accessibility**
   (macOS requires the "post events" permission to create virtual HID devices).
4. In X-Plane → Settings → Joystick the three devices appear like real hardware.

The devices disappear 2 s after input stops (like unplugging); the helper quits after 60 s idle.
`Honeycomb Virtual HID --self-test` creates the devices and sweeps every element for 10 s.

## Behaviour notes

- **Bravo selector:** reports nothing in Xbox mode; the virtual Bravo holds the selector position that matches the
  knob target (last AP button pressed: HDG, ALT, VS, IAS, NAV → CRS), so X-Plane's Bravo profile routes the knob.
- **Two-position switches** (Alpha rockers, Bravo switches) press one of two buttons, as on the PC device.
- **Alpha yoke** uses the monitor's roll/pitch calibration (including *Reversed*) when learned, raw otherwise.
- **Charlie:** in Xbox mode rudder and toe brakes share two fields; the virtual pedals follow the Charlie mode
  (Rudder → Z only; Xbox-style → Z plus both brakes when both pedals are pressed; Toe brakes → X/Y only). For a separate rudder and brakes connect the Charlie to the Mac's USB.
- **Provisional:** grip button order, Bravo switch polarity and lever-button numbers until checked on hardware.
- **Bravo LEDs:** not driven yet (the Alpha reports 25 LEDs in its capabilities reply).

## Signing

The helper needs the managed capability **HID Virtual Device** (`com.apple.developer.hid.virtual.device`), granted by
Apple to the developer team, enabled on the App ID `org.supino.honeycomb-vhid-test` and included in a development
provisioning profile for this Mac. `xcodebuild -allowProvisioningUpdates` (in `build-monitor.sh`) fetches the profile
automatically. Without it the helper cannot create devices and the monitor reports that.
