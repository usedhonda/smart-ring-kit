# Repository architecture

SmartRingKit is one repository with language-neutral protocol evidence and a
working Apple implementation. Android is an extension point, not implemented support.

```text
Package.swift                         Stable root Swift Package entry point
platforms/apple/
  Sources/SmartRingKit/
    Drivers/FFF0/                     Current wire codecs and FFF0 data types
      Apple/                          CoreBluetooth client and acquisition workflow
    Profiles/                         Swift mirror of exact device/firmware profiles
    Analysis/                         Sleep timeline analysis with explicit mapping
  Sources/smart-ring/                 macOS CLI
  Tests/SmartRingKitTests/            Apple implementation and catalog/vector checks
  Examples/                          SwiftUI example and CLI purpose string
platforms/android/README.md           Porting contract; no Android artifact yet
protocols/<protocol-id>/              Wire specification and synthetic JSON vectors
devices/<device-id>/
  README.md                          Product evidence, platform matrix, limitations
  firmware/<exact-version>.json       Versioned compatibility/interpretation evidence
```

## Boundaries

1. **Protocol family** owns requests, framing and byte layouts. FFF0 is the first
   family, not a generic meaning of every service named FFF0. Another protocol
   belongs in its own directory/driver; do not add its command IDs to FFF0's enum.
2. **Device plus firmware** owns compatibility evidence and interpretations such
   as sleep codes. A second model may share proven codecs without inheriting the
   first model's sleep mapping. A newer firmware version is unknown until checked.
3. **Platform** owns Bluetooth lifecycle, permissions, cancellation and persistence.
   Apple code stays under `platforms/apple`; a Kotlin/Android implementation can
   use the shared specifications and vectors without depending on Swift.
4. **Analysis** takes decoded records and an explicit interpretation. Unknown
   fields/codes, units, timestamps and gaps retain their current semantics.

All current `RingClient`, `RingReadCommand`, codec and capture APIs still refer to
FFF0. Their public module/product remains `SmartRingKit` to preserve existing
callers. There is no universal client, driver auto-detection or plug-in registry.
When a second implemented driver needs a common facade, design that API from both
real implementations rather than routing unrelated devices through FFF0 types.
The root `Package.swift` uses custom source paths; consumers keep the same URL,
product, module import and CLI wrapper.

## Exact firmware selection

```swift
let info = try await client.readInfo()
if let profile = RingDeviceProfiles.matching(
    deviceID: "issin-smart-recovery-ring", firmware: info.firmware
), let mapping = profile.sleepMapping {
    let analysis = try RingSleepAnalyzer.analyze(records, timeZone: zone, mapping: mapping)
    // Consume analysis here.
}
```

The caller must establish the device model; matching a name/service is insufficient.
Unknown device/firmware returns nil. This lookup does not block raw reads or select
another driver. The existing `.issinFirmware0750` constant remains an explicit opt-in,
not an automatic compatibility check. Do not apply it to a new firmware by default.
Snapshots already retain the reported firmware in `info.firmware`; persist the
selected profile ID with downstream interpretations when applicable.

`devices/` JSON is the cross-platform compatibility catalog. Swift mirrors the
currently supported profile in code, so no network or runtime file lookup is
needed. Tests compare the mirror with the shared manifest, including the sleep
mapping and history-command inventory. A port must do the same. Shared JSON
vectors describe synthetic inputs and expected decoder results; each implementation
runs them rather than maintaining a divergent copy of the examples.

See [CONTRIBUTING](../CONTRIBUTING.md) for adding a protocol, device, firmware or port.
