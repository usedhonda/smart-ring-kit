# Device and firmware catalog

| Device ID | Firmware | Protocol | Apple | Android |
| --- | --- | --- | --- | --- |
| [issin-smart-recovery-ring](issin-smart-recovery-ring/README.md) | `0.7.5.0` | `fff0` | Hardware transfer verified; field limits documented | Not implemented |

Do not infer compatibility across firmware versions or from a shared service UUID.
A profile records evidence, not a medical certification or guarantee of every metric.

## Manifest format, version 1

Each `devices/<device-id>/firmware/<exact-version>.json` contains:

- `formatVersion`: integer 1; change the format version for incompatible changes.
- `id`: stable profile identifier, unique across the catalog.
- `deviceID`: directory slug, independent of advertising name or personal serial.
- `firmware`: exact reported string, matching the JSON filename. No implicit ranges.
- `protocolID`: existing directory under `protocols/`.
- `status`: `documented`, `synthetic-tested` or `hardware-verified`.
- `implementations`: platform IDs and evidence levels; omit unimplemented ports.
- `historyCommands`: protocol-specific integer byte IDs supported by this profile.
- `sleepStages`: established numeric-code-to-stage mapping, possibly empty.
- `unknownSleepCodes`: observed codes with no established mapping.
- `evidence`: relative path to a public-safe evidence document.
- `limitations`: specific known limits; required even for hardware-verified profiles.

`hardware-verified` means the documented tested scope only. Per-command/field
limits belong in the evidence document; e.g. an empty transfer cannot validate
nonempty record semantics. Unknown ports and firmware remain absent, not assumed.

Run `python3 scripts/check-catalog.py` to check cross-references, exact version
filenames, identifiers and mapping consistency. Swift tests also verify that the
current runtime profile and shared synthetic vectors agree with this catalog.
