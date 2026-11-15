# xone-based experiments — November 14, 2026

**Current result:** the v1 authentication handshake verified, followed by live input from Alpha, Bravo and Charlie in isolated tests. See [AUTHENTICATED-RESULTS.md](AUTHENTICATED-RESULTS.md) and the README for the successful path. The earlier experiments below document how it was reached.

## Source and limits

Research used [medusalix/xone commit 3484f603484782dd7551c64e5a33fc602b127051](https://github.com/medusalix/xone/tree/3484f603484782dd7551c64e5a33fc602b127051), saved separately under the development workspace's `work/xone`. It is GPL-2.0-or-later; this deliverable does not bundle that repository or link Linux kernel code. The macOS code expresses the observed wire facts using IOKit, and records all transmissions. Preserve attribution and review applicable source licenses before incorporating upstream code into further work.

Relevant upstream locations:

- `transport/wired.c`: vendor/interface matching and `xone_wired_probe`, `xone_wired_init_audio_port`.
- `bus/protocol.c`: GIP header framing, announcement handling, identification requests, chunk acknowledgements, power command.
- `bus/protocol.h`: power-on mode value.
- `driver/gamepad.c`: use of power-on followed by authentication in the gamepad path.
- `auth/auth.c` and `auth/crypto.c`: the newer native authentication adaptation; see GIPAuth.m, NOTICE.md and COPYING.

Vendor `294b` is in xone's wired table (labelled Snakebyte), matched with interface class/subclass/protocol `ff/47/d0` and interface 0. This matches the measured Alpha transport signature, but does not mean xone includes a Honeycomb flight-stick decoder. This checkout has no FlightStick device-class driver.

## Commands added

The normal raw reader remains read-only at the GIP layer. Explicit research flags are restricted to measured Alpha `294b:1904`, configuration 1, data interface 0, interrupt IN endpoint `0x81`:

```sh
.build/release/honeycomb-usb-read --vid 0x294b --pid 0x1904 \
  --configuration 1 --interface 0 --endpoint 0x81 \
  --xone-setup --seconds 10
```

`--xone-setup` adds a USB reset and opens audio interface 1 to select alternate setting 0 before opening the data interface. Opening the audio interface is necessary on this Mac: an initial attempt through a device-level request failed with `0xe00002cd`, and was corrected to use the interface API. That first failed attempt and cleanup are preserved in the logs.

Replace `--xone-setup` with `--gip-identify` to additionally reply to valid 28-byte announcements with a GIP identification request, and acknowledge requested inbound chunks. The small parser bounds-checks variable-length headers and chunk ranges, tracks sequential offsets, and logs parsed headers. It is a research subset: no authentication, outgoing chunked transfers, automatic class driver, or control mapping.

Replace it with `--gip-power-on` to additionally send power-on after an identification transfer completes. This is an explicit experiment using xone's defined command; the full gamepad driver sequence has not been ported and is not assumed to apply unchanged to the advertised flight-stick class. No firmware, rumble, LED, audio-streaming, or authentication commands are sent.

The requests sent in the observed session were identification `04 20 01 00`, required per-chunk acknowledgements retaining the device's sequence, and power-on `05 20 02 01 00`. These bytes follow upstream framing and field values; they are not guessed Honeycomb report layouts.

Run the hardware-independent framing tests with:

```sh
.build/release/honeycomb-usb-read --gip-self-test
```

They cover announcement response, duplicate announcement suppression, chunk ACK layout, malformed varint rejection and power-on framing. The raw reader still attempts to restore the original USB configuration on exit. A USB reset can restart device state; restore of the configuration is not a restoration of every internal device setting.

## Observed results

1. Startup with reset and claimed audio alternate 0 produced **16 announcement packets in eight seconds**, compared with zero packets in the previous configuration-only experiment. Both steps were introduced together, so the capture does not isolate which was necessary. Cleanup succeeded.
2. The identification/ACK experiment captured **all 355 bytes** of the identification response, including its completion marker. Offline reassembly confirmed every byte was present. The raw response is retained as hex.
3. The identification names `Microsoft.Xbox.Input.FlightStick` and `Windows.Xbox.Input.NavigationController`. Its reported HID-descriptor offset is zero. This identifies a GIP flight-stick class, not a standard USB HID interface or a known axis layout.
4. The power-on experiment captured **95 packets in 45 seconds**: 85 announcements, eight identification chunks/completion frames, one input packet (`0x20`, 43-byte payload), and one status packet (`0x03`). The user reported that the Alpha powered on after the command.
5. The user moved Bravo during this test. No subsequent changing input packets were observed. Repeated announcements continued. This is an incomplete startup/input session, not a successful Bravo mapping or proof that the accessory data cannot become available after further initialization.
6. The user clarified that Bravo's lights normally appear under simulator control, for example X-Plane. Their absence is not treated as a power failure or a pass/fail test for input delivery.

The observed input payload is preserved unchanged. No gamepad layout is assigned to it. The next work is to establish the remaining flight-stick initialization/authentication requirements and collect labelled changing inputs. xone's authenticated gamepad path supplies further research material, but this prototype does not claim to implement it or bypass it. Virtual HID remains a separate entitlement-dependent output stage.

## Evidence

- `captures/xone-startup-2026-11-14.ndjson`: initial audio-interface API failure and cleanup.
- `captures/xone-startup-claimed-audio-2026-11-14.ndjson`: successful startup and announcements.
- `captures/xone-identify-2026-11-14.ndjson`: full raw identification exchange and transmitted ACKs.
- `captures/xone-identification-2026-11-14.hex`: reassembled 355-byte identification payload.
- `captures/xone-power-on-2026-11-14.ndjson`: power-on, input/status packet, continued announcements, and cleanup.

## Isolated Charlie test — November 14

The user reported Charlie lit immediately on connection, then confirmed sweeping the rudder and operating both toe brakes while Alpha and Bravo stayed still. A fresh Xbox-mode startup/identification/power-on capture recorded command counts {2: 103, 4: 8, 32: 1, 3: 1}. There was one initial 43-byte input payload and no subsequent changing input reports during the test. Its payload matches the initial payload in the earlier Bravo test. No USB or GIP parse errors were reported. The tool stopped cleanly and restored the original USB configuration.

This supplies no Charlie movement data from the tested session. The continuing input session remains incomplete, so the result does not distinguish downstream input unavailability from missing host initialization. Charlie's illumination is not used as evidence of USB input delivery. Evidence: `captures/charlie-pretest-2026-11-14.ndjson` and `captures/xone-charlie-only-2026-11-14.ndjson`.
