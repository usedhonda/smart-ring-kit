# SmartRingKit

A small Swift library for reading smart-ring data directly over Bluetooth LE.
The initial experimental driver targets the FFF0 protocol observed on the
**issin Smart Recovery Ring**. The package is independent of the manufacturer's
app and can be embedded in an iOS or macOS app.

**Early experimental release.** One ring with firmware `0.7.5.0` has been used
to verify firmware, battery, HRV and sleep read protocols. Other models and firmware versions are unverified.
This is an unofficial project, unaffiliated with issin or J-Style.

## What works

- Discover advertising `SRR-*` candidates and system-connected FFF0 peripherals.
- Connect, subscribe to notifications, and read firmware and battery level.
- Read existing HRV history, including SDK-labelled HRV, heart rate, and stress values.
- Decode saved notification packets offline and export structured JSON through a CLI.
- Experimental sleep-history reads with one-minute/five-minute raw category arrays.
- Raw history probes for SDK-defined heart-rate, temperature, oxygen and activity commands.
- Cancel an operation, enforce timeouts and record limits, and disconnect on transfer errors.

The implementation sends read-only requests. It does not change firmware,
delete history, configure sampling, or access the manufacturer's account/cloud.
It has no third-party package dependencies.

## Requirements and installation

Swift 6.0+, iOS 16+ or macOS 13+. Add this repository using Xcode's
**File → Add Package Dependencies**, select version `0.1.0` or later, and link
the **SmartRingKit** library product. Only add the library product to an iOS app;
the `smart-ring` executable is a separate developer tool.

In Package.swift:

```swift
.package(url: "https://github.com/usedhonda/smart-ring-kit.git", from: "0.1.0")
// Target dependency:
.product(name: "SmartRingKit", package: "smart-ring-kit")
```

The hosting app must provide `NSBluetoothAlwaysUsageDescription` in its
Info.plist. A sandboxed macOS app also needs the Bluetooth entitlement
`com.apple.security.device.bluetooth`. The package does not request background
modes or configure the host app's permissions.

## Read from an app

Use the main actor and retain one client for the connection's lifetime:

```swift
import SmartRingKit

@MainActor
func readSelectedRing(using client: RingClient, id: UUID) async throws -> [RingHRVRecord] {
    try await client.connect(to: id)
    defer { client.disconnect() }
    let info = try await client.readInfo()
    print(info.firmware, info.batteryPercent)
    return try await client.readHRVHistory()
}

// First call `try await client.discover()` and let the user select a candidate.
// Pass that candidate's `id` to readSelectedRing.
```

[Examples/RingDemoView.swift](Examples/RingDemoView.swift) is a minimal foreground
SwiftUI reader. Add it to a blank iOS app, add the package and Bluetooth purpose
string, and display `RingDemoView()` in the app's WindowGroup.

Only one operation may run on a client at a time. A disconnected read fails
immediately. Cancellation, timeouts, and transport/parser errors close the
local connection; discover/connect again before retrying. A history response
without its terminator fails rather than returning a supposedly complete set.

## Command-line tool

Sleep support (0.2.0+) is experimental. Use `try await client.readSleepHistory()`
for SDK-layout sleep records. `categoryValues` are deliberately unlabelled:
REM/deep/light/awake mappings and equivalence to the official app are unknown.
`sampleIntervalMinutes` preserves the SDK's one-minute or five-minute layout.
No sleep score, session aggregation or inferred HealthKit sleep stages are generated.

On-device verification with the new iOS client received 174 sleep blocks in the
130-byte layout, plus a separate transfer terminator. Offline decoding preserved
all blocks and their 15,607 category values, using the SDK's one-minute interval.
This sample count is not a claimed duration of sleep. Personal captures are not
included. The five-minute layout is covered by synthetic tests only.

For protocol research, `try await client.readRawHistory(.temperatureHistory)`
returns bounded, uninterpreted notification bytes. Other supported history kinds
are `.sleepHistory`, `.heartRateHistory`, `.oxygenHistory`, `.activityHistory`,
`.dailyActivityHistory` and `.hrvHistory`. An optional `onNotification` callback
can preserve partial responses when a transfer later times out. The callback
receives sensitive data; do not log it publicly. Additional device support,
metric interpretation and transfers requiring pagination remain unverified.
Fresh iOS connections completed raw temperature, oxygen, detailed-activity and
daily-activity transfers on the same ring. Their field decoding is not yet
implemented. Dynamic heart-rate history stopped after 50 notifications without
an end marker and remains incomplete; it is not advertised as a successful read.

On macOS, use the wrapper so the executable contains a Bluetooth purpose string:

```sh
bash scripts/smart-ring scan
bash scripts/smart-ring info --id <uuid-from-scan>
bash scripts/smart-ring history --id <uuid-from-scan>
bash scripts/smart-ring sleep --id <uuid-from-scan>
bash scripts/smart-ring raw-temperature --id <uuid-from-scan>
```

Bluetooth permission may be attributed to the terminal/hosting application.
`scan` returns candidates as JSON after eight seconds. Select the ring you own;
a matching name or service alone does not establish device compatibility.
The UUID is a CoreBluetooth identifier, not a Bluetooth MAC address.

Offline decoding accepts one complete notification per line as hexadecimal:

```sh
swift run smart-ring decode-history packets.hex
swift run smart-ring decode-sleep sleep-packets.hex
```

History output contains health data. The library does not store or upload it;
the CLI writes it to stdout only. Protect any files you redirect it into and
do not attach personal captures to public issues. Tests use synthetic data.

## Data meaning and current limits

`hrvRaw` and `stressRaw` retain the original unsigned byte values. The HRV
algorithm/unit and stress scale have **not** been established. A zero value is
preserved; it is not automatically treated as a missing or valid measurement.
Do not write `hrvRaw` into HealthKit's SDNN metric without validating equivalence.
`heartRateBPM` follows the SDK-labelled heart-rate field. Other fields remain in
`rawBytes` without a medical interpretation.

The ring supplies a wall-clock timestamp without a time zone. Choose the
historical time zone explicitly when calling `record.timestamp.date(in:)`.

An initial direct BLE probe read firmware, battery, and 600 history records.
Most positive timestamp gaps in that capture were about an hour. That does not
establish sensor sampling frequency. The new decoder is also checked against
that capture locally; no personal capture is distributed.

The iOS transport includes Apple's system-connected peripheral lookup, which
is useful when another app already holds a connection. **Concurrent reads with
the vendor app, unattended/background sync, and real-time measurement have not
been verified.** Two clients issuing the same command cannot be distinguished
by this protocol; avoid simultaneous sync requests. macOS and iPhone may also
compete for the ring's physical connection. No repeated polling or reconnection
is started automatically.

## Development

```sh
swift test
xcodebuild -scheme SmartRingKit -destination 'generic/platform=iOS' \
  -derivedDataPath .local/ios-build CODE_SIGNING_ALLOWED=NO build
```

CI tests synthetic packet framing, calendar validation, read request encoding,
limits, and cancellation/disconnected reads, and builds for iOS. Radio behavior
requires hardware testing. See [the protocol notes](docs/protocol.md) for evidence,
provenance, and the boundaries of current support.

## License

New implementation: [MIT](LICENSE). Third-party SDK code is not included.
