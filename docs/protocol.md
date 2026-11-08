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
15 is the sum of bytes 0–14 modulo 256. History byte 1 is always `0x00`, the
initial read mode. This library exposes no generic write or delete-mode API.

| Command | Meaning | Response used |
| --- | --- | --- |
| 0x27 | Firmware | Bytes 1–4, hexadecimal components joined by dots |
| 0x13 | Battery | Byte 1, percentage 0–100 |
| 0x56 | HRV history | Record-aligned notifications ending in `56 ff` |

Response checksums have not been established. The parser validates response
type, necessary lengths, calendar fields, battery range, record limits, and
history framing. It does not claim cryptographic integrity or authentication.

## History records

Each record is 15 bytes. A notification contains whole records; the final
notification may append the two bytes `56 ff`, or carry only that terminator.
A final byte `ff` inside a full record is not treated as completion. Truncated
notifications and missing completion are errors. Additional transfer modes,
pagination/continuation beyond the observed transfer, and different framing
variants are not implemented.

| Offset | Meaning |
| --- | --- |
| 0 | 0x56 |
| 1–2 | Uninterpreted |
| 3–8 | BCD year (2000+), month, day, hour, minute, second |
| 9 | SDK-labelled HRV raw value |
| 10 | Uninterpreted |
| 11 | SDK-labelled heart rate in bpm |
| 12 | SDK-labelled stress raw value |
| 13–14 | Uninterpreted |

All bytes are retained. The time zone, HRV algorithm/unit, stress scale, and
equivalence with values displayed by the vendor app are not established.

## Compatibility work remaining

- Verify the released RingClient's full transfer against hardware, separately
  from the initial probe and offline capture replay.
- Test iOS co-connection with the vendor app and collisions between requests.
- Evaluate background restoration and iOS scheduling on a dedicated app.
- Add another model only with protocol evidence and synthetic regression cases.

No firmware modification is needed for this read subset. Firmware updates,
reset, history deletion, clock configuration, and medical interpretation are
outside the current implementation.
