# Authenticated Xbox-mode input — November 14, 2026

**Input from Alpha, Bravo and Charlie was observed through the unchanged Xbox Hub → Alpha → Mac connection.** This establishes the input-transport feasibility of the cable-minimizing setup on the tested rig. It does not yet establish every control's mapping, calibrated ranges, virtual HID output, simulator integration or switching back to Xbox.

## Initialization

The Alpha-only baseline with power-on alone produced no changing input. An experimental session-complete shortcut was followed by an unsolicited disconnect/re-enumeration; the user confirmed they had only moved the controls. That sequence did not establish a working session, and the cause of the disconnect was not isolated.

The new `--gip-authenticate` path then completed the xone-based v1 RSA handshake. The native implementation exchanged random challenges, received the device's certificate/public key, encrypted a random premaster with RSA PKCS#1, derived the source-defined master secret with HMAC-SHA256, and **verified the device-finish transcript** before sending the final session-complete control message. The short capture contains `gip_auth_verified` and closed/restored configuration successfully.

The next, longer run began receiving input immediately without a new announcement or handshake. It reused the device's initialized state from the preceding verified exchange. A successful fresh handshake is proven by `captures/xone-authenticate-2026-11-14.ndjson`; the subsequent run is input validation, not a second authentication proof.

## Isolated control-group tests

The user confirmed finishing each phase with the other groups still. Offsets below are zero-based positions **inside the 43-byte command-0x20 payload**, excluding its four-byte GIP header.

| Movement phase | Input packets | Payload positions that changed |
| --- | ---: | --- |
| Alpha yoke/buttons | 613 | 3, 4, 11–14 |
| Bravo levers/switches | 720 | 5, 7–9, 17–28 |
| Charlie rudder/toe brakes | 340 | 29–32 |

The entire long capture contains 1,673 input packets and seven status packets. No USB, authentication or GIP parse errors were reported; stop, pending-read abort, restoration and close succeeded.

The isolated changes demonstrate accessory data reaching the Mac through the Alpha. They do not determine the semantics, signedness, byte order or width of every individual axis/button field. Charlie's four changing bytes are not assumed to be four axes or two axes; the individual rudder/brake encodings remain to be measured. The approximate phase markers record the user's confirmations and packet counts. The first marker was written after the Alpha prompt; the first phase includes all packets from the beginning through its completion boundary.

## Live monitor

`Honeycomb Monitor.app` uses these observed byte groups to display movement independently in three panels. It plots raw byte levels and activity; those are uncalibrated observed channels, not named axis gauges. Only fields observed during the group tests are assigned to panels. Untested controls or other fields may not appear. It creates no virtual HID device and requires no virtual-HID entitlement.

## Evidence

- `captures/xone-alpha-only-2026-11-14.ndjson`: unsuccessful power-only Alpha baseline.
- `captures/xone-session-complete-2026-11-14.ndjson`: shortcut test, status/disconnect and cleanup failure after removal.
- `captures/xone-authenticate-2026-11-14.ndjson`: successful v1 exchange and finish verification.
- `captures/xone-authenticated-controls-2026-11-14.ndjson`: successful group movement tests.
- `captures/authenticated-controls-markers-2026-11-14.ndjson`: phase notes and cumulative input counts.

Authentication code is adapted from xone and distributed with upstream attribution under GPL-2.0-or-later; see NOTICE.md and COPYING. macOS APIs implement the crypto locally. Version 2/P-256 code is present but has not been exercised with this rig. Device public-key extraction follows xone; it is not a general certificate trust-chain attestation.
