# Apple implementation

The current SmartRingKit implementation is written in Swift for **iOS 16+** and
**macOS 13+**, with Swift 6+. It implements the observed FFF0 read subset.
See [the device/firmware catalog](../../devices/README.md) for verified compatibility.

## Install

Use `Package.swift` at the repository root. In Xcode, choose **File → Add Package
Dependencies**, add this repository and select version `0.4.0` or later. Link the
**SmartRingKit** library product; the `smart-ring` executable is a separate tool.

```swift
.package(url: "https://github.com/usedhonda/smart-ring-kit.git", from: "0.4.0")
// Target dependency:
.product(name: "SmartRingKit", package: "smart-ring-kit")
```

The host app needs `NSBluetoothAlwaysUsageDescription` in Info.plist. A sandboxed
macOS host also needs `com.apple.security.device.bluetooth`. The package does not
configure host permissions or request background modes. It has no third-party
package dependencies. Include the [MIT notice](../../LICENSE) in the distributed
app's OSS acknowledgements; see [embedding notes](../../docs/licensing.md).

## Read all stored histories

Let the user select an owned, compatible ring from `try await client.discover()`.
Its `id` is a local CoreBluetooth UUID, not a Bluetooth MAC or global serial number.
A matching name/service alone does not establish compatibility.

```swift
import Foundation
import SmartRingKit

@MainActor
func captureRing(id: UUID) async throws -> RingHistorySnapshot {
    try await RingHistoryReader.readAll(from: id, onCapture: { capture in
        // Optionally persist each result here; throwing stops acquisition.
        // Inspect transferComplete, failure, decoded.issues and decoded.integrity.
        // Original/partial notifications remain in capture.raw.
    })
}
```

The reader obtains metadata, then uses a fresh local connection for each history.
Errors retain partial data; conflicting history responses stop bulk acquisition.
Protect captured health data and host-scoped identifiers. Full API/data semantics
are documented in [the data contract](../../docs/data-model.md).

For a single category, retain one `RingClient`, call `connect(to:)` after discovery,
then use `readInfo()`, `readHRVHistory()`, `readSleepHistory()` or
`readRawHistory(_:)`. Disconnect when finished. Only one operation may run per
client. Cancellation, timeout and transport/parser errors close its connection;
discover/connect again before retrying. A missing terminator fails the request.

[Examples/RingDemoView.swift](Examples/RingDemoView.swift) is a minimal foreground
SwiftUI HRV reader. Add it to a blank iOS app with the package and Bluetooth purpose
string, then display `RingDemoView()` in the app's WindowGroup.

## Interpret sleep with an exact firmware profile

```swift
@MainActor
func analyzeSleep(snapshot: RingHistorySnapshot, historicalZone: TimeZone) throws -> RingSleepAnalysis? {
    guard let profile = RingDeviceProfiles.matching(
        deviceID: "issin-smart-recovery-ring", firmware: snapshot.info.firmware
    ), let mapping = profile.sleepMapping else { return nil }
    let records = snapshot.histories.first { $0.command == .sleepHistory }?.decoded.sleep ?? []
    return try RingSleepAnalyzer.analyze(records, timeZone: historicalZone, mapping: mapping)
}
```

Establish the device model before choosing its ID; firmware alone is insufficient.
Unknown device/firmware pairs return nil. The existing `.issinFirmware0750` mapping
is an explicit opt-in, not a firmware compatibility check. Unknown sleep codes
remain unknown. Use the optional `window` argument to summarize a chosen night;
night boundaries and recovery scores are not guessed.

The ring clock has no time zone. Supply the historical zone explicitly for
analysis or `record.timestamp.date(in:)`. `hrvRaw` and `stressRaw` retain original
byte values; HRV units/algorithm and the stress scale are unestablished. Do not
write `hrvRaw` into HealthKit SDNN without establishing equivalence. Unknown
physical units remain nil; raw sample arrays with unknown spacing cannot become
per-sample timestamps. See the data contract for all supported layouts.

## macOS CLI

From the repository root, use the wrapper so the binary includes its Bluetooth
purpose string. Bluetooth permission may be attributed to the terminal/host app.
`scan` waits eight seconds and prints candidates as JSON.

```sh
bash scripts/smart-ring scan
bash scripts/smart-ring info --id <uuid-from-scan>
bash scripts/smart-ring all --id <uuid-from-scan>
bash scripts/smart-ring capture --id <uuid-from-scan> --output ./private-captures
```

`all` prints a snapshot; `capture` writes per-category results and a final snapshot
in a unique private directory. The library itself does not store or upload data.
Keep these files private and do not attach personal captures to public issues.

Offline commands need no ring or Bluetooth permission:

```sh
swift run smart-ring decode-history packets.hex
swift run smart-ring decode-sleep sleep-packets.hex
swift run smart-ring decode-raw history.json
swift run smart-ring analyze-sleep sleep-history.json --time-zone <zone> --profile issin-0.7.5.0
```

Hex inputs contain one complete notification per line. JSON inputs contain a
`RingRawHistory` object (`command` and `notifications`), available as a capture's
`raw` field. Strict sleep analysis requires the transfer terminator.

## Verification and development

All ten stored-history transfers completed on iOS hardware with one ring reporting
firmware `0.7.5.0`. Exercise was empty; not all field meanings are established.
macOS full-history radio acquisition and other devices/firmware remain unverified.
Concurrent vendor-app requests interfered with history acquisition: use exclusive
reads. Background/unattended sync and real-time measurement remain unverified.
No automatic polling or reconnect loop is started.

```sh
python3 scripts/check-catalog.py
swift test
bash scripts/smart-ring --help
xcodebuild -scheme SmartRingKit -destination 'generic/platform=iOS' \
  -derivedDataPath .local/ios-build CODE_SIGNING_ALLOWED=NO build
```

CI runs catalog/shared-vector checks, Swift tests, CLI help, iOS compilation and
SwiftUI example type-checking. Radio behavior needs hardware evidence. Protocol
code lives in `Sources/SmartRingKit/Drivers/FFF0`; its `Apple/` subdirectory owns
CoreBluetooth acquisition. See [architecture](../../docs/architecture.md),
[protocol evidence](../../protocols/fff0/README.md) and
[CONTRIBUTING](../../CONTRIBUTING.md) for extension guidance.
