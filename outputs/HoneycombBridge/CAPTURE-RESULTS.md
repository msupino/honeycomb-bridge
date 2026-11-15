# Connected-rig test — November 13, 2026

**Superseded by successful authenticated Xbox-mode input tests on November 14.** See [the current results](AUTHENTICATED-RESULTS.md). Earlier negative tests below describe incomplete initialization.

The user kept Bravo and Charlie on the Honeycomb Xbox Hub and connected the Alpha XPC's main USB connection to the Mac. For the second test, the user switched the Alpha to PC mode, reconnected, and confirmed moving all three devices.

| Test | Result |
| --- | --- |
| Xbox mode | Alpha detected as `294b:1904`, firmware bcdDevice `0x0116`. Vendor-specific class/subclass/protocol `ff/47/d0`; no HID service appeared. |
| Xbox USB configuration | One advertised configuration, selected configuration 0 (unconfigured) when read. Interface 0 advertises 64-byte interrupt OUT `0x01` and IN `0x81`; interface 1 also advertises isochronous endpoints on alternate setting 1. No configuration or initialization commands were sent. |
| PC mode | Alpha detected as `294b:1900` with a standard HID joystick service. Non-seizing HID open succeeded. |
| PC-mode motion | 605 changed 64-byte reports over approximately 44 seconds. Changes after the initial report occurred only at byte offsets 1–4, corresponding to the two descriptor-defined Alpha axes. |
| Bravo / Charlie | Neither enumerated separately. No additional report changes were observed during the user's combined test. The descriptor's 53-byte vendor-defined input field remained all zero. This test supplies no evidence of their input reaching the Mac through the Xbox Hub in PC mode. |
| Virtual HID | Not tested; no approved entitlement/provisioning setup established. |

The counts describe the movement interval inspected immediately after the user confirmed the test. The full capture can include later idle/noise events before capture shutdown.

The PC-mode HID descriptor describes two standard axes, a hat, 35 buttons and a vendor-defined field. The unknown field was captured without assigning it a protocol or inventing control mappings. The measured Alpha mapping includes the two axes and first 32 buttons; button operation was not independently tested in this movement test.

## Consequence

The Alpha works as a readable PC-mode HID input device. This test did not establish the desired full-rig pass-through in PC mode. Xbox mode needs further raw-USB transport/configuration/initialization research before the existing HID mapper can receive its control inputs. The advertised endpoint types alone do not identify or decode the Honeycomb accessory protocol.

## Evidence

- `captures/xbox-first-connection.ndjson`: Xbox-mode filtered inventory and HID-watch startup, with no HID arrival.
- `captures/xbox-usb-descriptors.ndjson`: Xbox USB configuration bytes and parsed interface/endpoint metadata.
- `captures/pc-usb-descriptors.ndjson`: PC-mode USB metadata.
- `captures/pc-controls.ndjson`: actual PC-mode HID descriptor, elements, raw reports and scalar values.
- `captures/alpha-pc.mapping.json`: measured descriptor-based source bindings for this connection.
- `captures/alpha-pc-states.ndjson`: log-only mapper replay of the physical Alpha capture; this does not create an OS-visible controller.

The first real capture exposed a boolean-versus-number JSON mismatch between the probe and mapper. The probe now emits a JSON boolean, and the mapper also accepts legacy 0/1 flags so the original capture can replay unchanged. A regression test covers both formats.

## Isolated Bravo follow-up

The user then kept the Alpha and Charlie still and confirmed completing a Bravo-only lever/switch test in PC mode. The fresh `captures/pc-bravo-only.ndjson` capture contains one initial 64-byte HID report, zero subsequent changed reports, zero scalar value events, and no reported errors. The Alpha HID open succeeded. No Bravo input reached the observed Alpha HID service during this test. This reinforces the result for this exact PC-mode wiring; it does not establish whether Xbox-mode initialization could enable accessory input.

## Xbox-mode raw endpoint follow-up

After the user returned the Alpha to Xbox mode and reconnected, it was again detected as `294b:1904` with selected USB configuration 0. The user reported Charlie lit, Alpha and Bravo unlit (Alpha had lit in PC mode). Lights establish an observed power/indicator state, not input delivery or a diagnosis.

The new `honeycomb-usb-read` executable selected the advertised configuration 1, opened interface 0 without seizure, located its advertised interrupt IN endpoint `0x81`, and queued a 64-byte asynchronous read. Every setup operation succeeded. No vendor-specific or Xbox initialization packets were sent.

During the 30-second window, the user confirmed moving Bravo and reported unchanged lights. Zero input packets arrived. The pending read was aborted successfully; restoration to configuration 0 and device close both succeeded. Evidence: `captures/xbox-reconnected-descriptors.ndjson` and `captures/xbox-raw-read.ndjson`.

This confirms that user-space access to the endpoint is feasible on this Mac, while standard configuration and a queued read alone do not start an input stream in this test. Xbox initialization/handshake and any downstream accessory protocol remain unimplemented and unverified. No generic Xbox packet is guessed from descriptor IDs. A verified protocol implementation or a working-host capture is needed next.

## November 14 update

The zero-packet result above was superseded by xone-based startup experiments. Reset plus explicit audio-interface alternate 0 produced announcements, identification replies were fully captured, and a source-backed power command visibly powered the Alpha on. One initial input packet arrived, but no sustained or Bravo-correlated input followed during the test. See [the detailed xone record](XONE-RESEARCH.md). Bravo lighting is simulator-controlled according to the user and is not used as an input/power test.

## Isolated Charlie test — November 14

The user reported Charlie lit immediately on connection, then confirmed sweeping the rudder and operating both toe brakes while Alpha and Bravo stayed still. A fresh Xbox-mode startup/identification/power-on capture recorded command counts {2: 103, 4: 8, 32: 1, 3: 1}. There was one initial 43-byte input payload and no subsequent changing input reports during the test. Its payload matches the initial payload in the earlier Bravo test. No USB or GIP parse errors were reported. The tool stopped cleanly and restored the original USB configuration.

This supplies no Charlie movement data from the tested session. The continuing input session remains incomplete, so the result does not distinguish downstream input unavailability from missing host initialization. Charlie's illumination is not used as evidence of USB input delivery. Evidence: `captures/charlie-pretest-2026-11-14.ndjson` and `captures/xone-charlie-only-2026-11-14.ndjson`.
