# Bravo controls: PC-mode numbering vs. Xbox-mode bits

Two sources combined:

1. **PC (USB HID) mode button numbers** from the community reference [RoystonS/honeycomb `bravo-controls.md`](https://github.com/RoystonS/honeycomb/blob/main/bravo-controls.md) (1-based, as Windows shows them; X-Plane and FSUIPC count from 0). Several key-map lists agree on the AP row and gear numbers ([blogofant](https://www.blogofant.de/en/technology/honeycomb-bravo-throttle-quadrant-key-maps-button-maps/), [Sporty's X-Plane PDF](https://ipadpilotnews-images.s3.us-east-2.amazonaws.com/wp-content/uploads/2022/01/07113919/10503-Honeycomb-Bravo-Configuration-X-Plane.pdf)).
2. **Xbox-mode bits measured on this rig** during the isolated Bravo test in `captures/xone-authenticated-controls-2026-11-14.ndjson` (packets 613–1333). Bit `n` = payload byte `3 + n/8`, bit `n % 8`. These are the bit numbers used by `HoneycombInput/buttons.txt` and shown under *Calibrate for X-Plane → Buttons & switches*.

Xbox mode does **not** reuse the PC numbering: two-position switches report one bit instead of two buttons, and the layout is packed differently. Confidence column: **measured** = sequence in the capture matches the physical test; **likely** = consistent but order/polarity unconfirmed; **not seen** = never present in any capture yet.

## Toggle switches (row of 7)

PC mode: two held buttons per switch (up / down). Xbox mode: one held bit per switch.

| Switch | PC buttons (up / down) | Xbox bit | Confidence | Suggested X-Plane commands (on / off) |
| --- | --- | --- | --- | --- |
| 1 | 34 / 35 | 35 | measured (order) | `sim/lights/beacon_lights_on` / `_off` |
| 2 | 36 / 37 | 36 | measured (order) | `sim/lights/landing_lights_on` / `_off` |
| 3 | 38 / 39 | 37 | measured (order) | `sim/lights/taxi_lights_on` / `_off` |
| 4 | 40 / 41 | 38 | measured (order) | `sim/lights/nav_lights_on` / `_off` |
| 5 | 42 / 43 | 39 | measured (order) | `sim/lights/strobe_lights_on` / `_off` |
| 6 | 44 / 45 | 40 | measured (order) | `sim/ice/pitot_heat0_on` / `_off` |
| 7 | 46 / 47 | 41 | measured (order) | `sim/systems/avionics_on` / `_off` |

In the test the bits cleared 35→41 and then set 41→35, i.e. the user flipped the switches left to right and back. **Polarity (set = up or down) is not confirmed**: if a light comes on when the switch goes down, swap the two commands on that line.

## Lever detent buttons

PC mode: pulling a lever below the flight detent presses a held button. In the capture, bits 48–53 were set at rest and cleared one by one as the levers were raised.

| Lever | PC button | Xbox bit | Confidence | Suggested use |
| --- | --- | --- | --- | --- |
| 1 | 24 | 48 | likely | `sim/engines/thrust_reverse_hold` or unbound |
| 2 | 25 | 49 | likely | as above |
| 3 | 26 | 50 | likely | prop feather |
| 4 | 27 | 51 | likely | prop feather |
| 5 | 28 | 52 | likely | idle cutoff (`sim/engines/mixture_min`) |
| 6 | 33 | 53 | likely | idle cutoff |

## Autopilot row and knob

| Control | PC button | Xbox bit | Confidence | Suggested X-Plane command |
| --- | --- | --- | --- | --- |
| HDG | 1 | 18–22 range? | not mapped | `sim/autopilot/heading` |
| NAV | 2 | 18–22 range? | not mapped | `sim/autopilot/NAV` |
| APR | 3 | 18–22 range? | not mapped | `sim/autopilot/approach` |
| REV | 4 | 18–22 range? | not mapped | `sim/autopilot/back_course` |
| ALT | 5 | 18–22 range? | not mapped | `sim/autopilot/altitude_hold` |
| VS | 6 | ? | not seen | `sim/autopilot/vertical_speed` |
| IAS | 7 | ? | not seen | `sim/autopilot/level_change` |
| AP master | 8 | ? | not seen | `sim/autopilot/servos_toggle` |
| Knob increment / decrement | 13 / 14 | ? | not seen | depends on selector (see below) |
| Selector IAS / CRS / HDG / VS / ALT | 17–21 (held) | ? | not seen | used with the knob; needs plugin support |

Bits 18, 19, 20, 21 and 22 each appeared for exactly one packet, in order, during the Bravo phase. That pattern fits five momentary presses (likely five AP-row buttons, left to right), but which buttons were pressed was not recorded, so they are not bound yet.

## Not yet seen in any Xbox-mode capture

Gear lever up/down (PC 31/32), flaps lever down/up (15/16, momentary), trim wheel forward/back (22/23), lever buttons A/B (9, 10, 11, 12, 29, 30, 48), and the selector knob. A selector knob position should always be held, yet no bit stayed set besides switches and detents, so the selector may live outside bytes 3–10 or need another report. Capture it on the next hardware session.

## Alpha (for reference)

During the Alpha phase bits 0–3 were pressed together and released, then 5–8 likewise; bits 4 and 11 are held most of the time (probably magneto/master switch states). Individual Alpha buttons are not mapped yet.

## Next hardware session checklist

1. Open *Calibrate for X-Plane → Buttons & switches*.
2. Press each AP button once, left to right, noting bits (confirms 18–22 and finds VS / IAS / AP).
3. Turn the selector through all five positions; turn the knob both ways.
4. Gear up/down, flaps up/down, trim wheel both ways, each lever button.
5. Flip each switch up and note whether its bit sets or clears (polarity).
6. Update `buttons.txt` and this table.

## Confirmed on hardware (2026-11-15, learned in Honeycomb Monitor)

Bit numbers as used by `buttons.txt` (bit n = payload byte 3 + n/8, bit n % 8).

| Bit | Control | Bit | Control |
| --- | --- | --- | --- |
| 0 | Alpha ALT master | 17–23 | Bravo AP: HDG, NAV, APR, REV, ALT, VS, IAS |
| 1 | Alpha BAT master | 32 / 33 | Bravo knob − / + |
| 2 / 3 | Alpha AV BUS 1 / 2 | 34 | Bravo AUTOPILOT |
| 4–8 | Alpha BCN, LAND, TAXI, NAV, STROBE | 35–41 | Bravo switches 1–7 (still provisional) |
| 9–12 | Alpha magneto R, L, BOTH, START | 42 / 43 | Bravo gear UP / DOWN |
| (none) | Alpha magneto OFF → derived bit 63 | 44 / 45 | Bravo flaps UP / DOWN |
| 16 | Alpha hat ← | 46 / 47 | Bravo trim forward / back |
|  |  | 48–53 | Bravo lever 1–6 below detent |

Not yet learned: Alpha hat ↑/→/↓, grip buttons and rockers; Bravo selector (ALT/VS/HDG/CRS/IAS, probably bits 24–31), lever A/B buttons. Bit 42 (gear up) is the held bit seen at the start of the live session.

Note: the Alpha light rockers and Bravo switches 1–5 default to the same light commands, so both panels drive the same lights; rebind one set if that conflicts.

## Protocol reference: Xbox FlightStick (GIP)

The Alpha's GIP metadata declares the interface `Microsoft.Xbox.Input.FlightStick` (seen in the command-0x04 metadata packets of `captures/xone-authenticate-2026-11-14.ndjson`). That is a generic Xbox device class, and the Linux `xbox_gip` flight-stick patch ([linux-input, v3 10/10, March 2026](https://ratatoskr.run/linux-input/2026/03/8938149); superseded by v7) parses its 0x20 input report with the same offsets this project measured (payload offsets, after the 4-byte GIP header):

| Payload bytes | FlightStick meaning (patch) | This rig |
| --- | --- | --- |
| 0–1 | navigation buttons (via the navigation driver) | not decoded yet |
| 2 bit 0 / bit 1 | fire primary / fire secondary | not decoded yet |
| 3 … | extra button *i* = byte `3 + i/8`, bit `i % 8` | exactly this project's "bit n" numbering |
| 11–12 | roll, int16 | Alpha roll ✔ |
| 13–14 | pitch, int16 | Alpha pitch ✔ |
| 15–16 | yaw, int16 | never changed in any capture |
| 17–18 | throttle, uint16 | Bravo lever 1 ✔ (10-bit value scaled to 16 bits) |
| 19 + 2k | extra axis *k*, uint16 | Bravo levers 2–6 (k = 0–4), Charlie fields 29/31 (k = 5, 6) |

The device answers a capabilities request (vendor command 0x00) with extra-button, extra-axis and LED counts; the patch reads layout from that, not from metadata.

So the *byte layout* is a published, generic format, but the *assignment of Honeycomb controls to extra-button indices* is Honeycomb-specific and no public reference was found; it still has to be learned (or taken from the table above). Fire buttons in byte 2 and navigation bytes 0–1 are not used by this project yet.

## Charlie in Xbox mode (confirmed 2026-11-15)

The Hub reports the Charlie pedals as two one-way 10-bit extra axes: field 29/30 and field 31/32. Rudder travel and the toe brakes **both drive these same two fields** (rudder one way → 29, the other way → 31; each toe brake also moves its side's field). The standard FlightStick yaw (bytes 15/16) never changes. Rudder and brakes therefore cannot be separated in Xbox mode. Honeycomb Monitor offers a **Charlie mode**: *Rudder* (yaw = field 31 − field 29), *Toe brakes* (29 = left, 31 = right) or *Calibrated mappings*, with Reverse.

## Alpha yoke buttons (bytes 0–2)

The Alpha grip buttons and hat are not FlightStick *extra* buttons: they report in the navigation/fire bytes 0–2, which the app now exposes as bits 64–87 (bit `64 + 8·k + j` = payload byte `k`, bit `j`). Seen live: byte 1 bits 0–3 change like a d-pad (provisional hat ↑ 72, ↓ 73, ← 74, → 75), byte 0 bits 5 and 7 and byte 1 bit 4 also change. Learn the grip with *Learn all → Grip buttons* and *Hat*.
