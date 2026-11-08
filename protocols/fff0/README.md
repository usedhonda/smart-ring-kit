# Initial FFF0 read driver

## Evidence and provenance

The initial implementation was written in Swift using observed BLE traffic and
protocol details inspected in the publicly accessible
[auriahringsdk repository](https://github.com/hatkg/auriahringsdk/tree/5a868e9e36373e1eb2b936b523f4a629c19bfb05/blesdk_2301/src/main/java/com/jstyle/blesdk2301).
Relevant references are `Util/BleSDK.java` (read request formats),
`constant/DeviceConst.java` (command IDs), and `other/ResolveUtil.java` (field
layout). The reference commit is `5a868e9e36373e1eb2b936b523f4a629c19bfb05`.
No redistribution license was identified through the repository metadata.
No reference SDK source, binaries, or bundled application assets are included
here. This is not a claim of a clean-room implementation or an official SDK.

A direct probe on an issin Smart Recovery Ring reporting firmware `0.7.5.0`
confirmed successful firmware, battery, and HRV-history reads. The capture
contained 38 history notifications: 37 of 240 bytes and one of 122 bytes,
representing 600 records and a two-byte terminator. Device identifiers and
health values remain private. Verification of this protocol on one device does
not establish support for every product using FFF0.

## GATT transport

| Role | UUID | Operation |
| --- | --- | --- |
| Service | FFF0 | Discover |
| Request | FFF6 | Write with response |
| Response | FFF7 | Subscribe to notifications |

The observed ring did not advertise service UUIDs. Discovery scans unfiltered
and identifies `SRR-*` names or advertised FFF0 service candidates. Service and
characteristic properties are checked after connecting. System-connected FFF0
devices are also returned using
[retrieveConnectedPeripherals(withServices:)](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)).
The client must still call `connect` before using such a peripheral.

## Requests

Each request is 16 bytes, initially zero-filled. Byte 0 is the command and byte
15 is the sum of bytes 0–14 modulo 256. History byte 1 is `0x00` for the
initial read and `0x02` for continuation. This library exposes no generic write or delete-mode API.

| Command | Meaning | Response used |
| --- | --- | --- |
| 0x27 | Firmware | Bytes 1–4, hexadecimal components joined by dots |
| 0x13 | Battery | Byte 1, percentage 0–100 |
| 0x56 | HRV history | Record-aligned notifications ending in `56 ff` |
| 0x53 | Sleep history (experimental) | SDK layouts below; ends in `53 ff` |
| 0x54 | Dynamic heart-rate history | 24-byte rows; 15 bpm samples |
| 0x55 | Spot heart-rate history | 10-byte rows |
| 0x62 | Temperature history | Legacy 11/observed 15-byte rows |
| 0x66 | Automatic oxygen history | 10-byte rows |
| 0x67 | Manual oxygen history | Legacy 10/observed opaque 31-byte rows |
| 0x52 | Detailed activity history | 25-byte rows |
| 0x51 | Daily activity history | 26/27-byte rows |
| 0x5c | Exercise history | 25-byte rows; empty transfer verified |
| 0x41 | Device clock | Read-only BCD wall clock, no time zone |

Response checksums have not been established. The parser validates response
type, necessary lengths, calendar fields, battery range, record limits, and
history framing. It does not claim cryptographic integrity or authentication.

## History records

Each record is 15 bytes. A notification contains whole records; the final
notification may append the two bytes `56 ff`, or carry only that terminator.
A final byte `ff` inside a full record is not treated as completion. Truncated
notifications and missing completion are errors. Version 0.3.0 adds read-only
continuation, described in [the data contract](../../docs/data-model.md).

| Offset | Meaning |
| --- | --- |
| 0 | 0x56 |
| 1–2 | Observed record counter; diagnostic interpretation only |
| 3–8 | BCD year (2000+), month, day, hour, minute, second |
| 9 | SDK-labelled HRV raw value |
| 10 | Uninterpreted |
| 11 | SDK-labelled heart rate in bpm |
| 12 | SDK-labelled stress raw value |
| 13–14 | Uninterpreted |

All bytes are retained. The time zone, HRV algorithm/unit, stress scale, and
equivalence with values displayed by the vendor app are not established.

## Experimental sleep layout

The SDK's `getSleepData` describes a single 130-byte record carrying one-minute
categories, or notifications of one or more 34-byte records carrying five-minute
categories. A final notification may append `53 ff`; that marker can also arrive
alone. Offsets 3–8 are the same BCD date/time fields as HRV, byte 9 is the number
of category bytes, and categories start at byte 10. Counts must fit the record
(120 or 24). The decoder rejects unknown layouts, invalid clocks and oversized
category counts atomically. It retains full records without labelling category
numbers as clinical sleep stages. A marker-like sequence inside a complete
record is not treated as completion.

These formats and additional command IDs are SDK evidence, not proof that every
command works on the target ring. Raw transfers only check the response header,
byte budget and command/ff terminator; they do not validate field semantics or
prove that all historical pages have been read. Version 0.3.0 continues after an
idle page boundary. Timeouts fail, and the optional notification callback lets researchers
keep partial responses locally. No vendor SDK source is bundled.

An iOS hardware check with this implementation discovered the existing
system-connected ring and read firmware, battery and sleep history. It received
174 packets of 130 bytes and one `53 ff` marker. All 174 records and 15,607
category bytes passed the decoder with original bytes preserved. This verifies
the one-minute layout on that device. Later stage-duration comparison is described
below; sleep-score equivalence remains unverified. No firmware/configuration
writes were used. A dynamic heart-rate probe returned 50 packets of 168 bytes but no final
marker before timeout in 0.2.0. Version 0.3.0 added idle-aware continuation and
completed this command, along with every other stored-history command listed above.

Separate fresh iOS connections completed raw temperature (120 notifications),
automatic oxygen (86), detailed activity (238) and daily activity (3) transfers,
including their command/ff markers. These are verified byte transfers, not typed
measurement validation. Personal payloads and peripheral identifiers are omitted.

## Compatibility work remaining

- Establish a coordination method for vendor-app sync; simultaneous history
  requests interfered with acquisition on the tested device.
- Evaluate background restoration and iOS scheduling on a dedicated app.
- Add another model only with protocol evidence and synthetic regression cases.

## 0.3.0 source/interpretation boundary

Continuation evidence is the reference SDK sample's `HeartRateInfoActivity.java`
and `DetailSleepActivity.java`: mode 2 is requested at 50 notifications. The
client waits for a three-second idle boundary because tested firmware streams
some categories past that count automatically, and received counts can stop at
49. A single public `RingHistoryReader.readAll` run completed all ten histories
on iOS hardware after the vendor app was closed, with no unexpected responses.
Earlier simultaneous vendor-app requests caused gaps and connection failures.
Counter diagnostics, unexpected notification capture and per-category failure
flags keep these visible. Dynamic heart rate completed with contiguous counters.
Detailed activity retained one counter gap: a separate reread returned exactly
the same record payloads and gap. This is reported without inventing a record.

The sleep mapping `1=deep, 2=light, 3=REM, 5=awake` is an observed profile for the
tested firmware. All four stage-duration totals matched the vendor app on two
separate nights. Codes 10/11 remain unknown. No nightly values are published.
The named profile selects only this observed mapping.
See [data-model.md](../../docs/data-model.md) for classification, overlap, missingness, units
and opaque-record handling. No score algorithm or night boundaries are invented.

No firmware modification is needed for this read subset. Firmware updates,
reset, history deletion, clock configuration, and medical interpretation are
outside the current implementation.
