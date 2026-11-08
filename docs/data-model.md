# All-history capture and data interpretation

Version 0.3.0 reads the ten stored-history commands in the reference SDK. It never
erases history, configures the ring, starts measurements or updates firmware.
This is a supported-protocol inventory; undocumented/future commands are not claimed.

## One-call snapshot

```swift
let snapshot = try await RingHistoryReader.readAll(from: selectedPeripheralID) { capture in
    // Persist progress here if needed; this callback may throw on storage failure.
    // capture.raw retains notifications within its byte budget, including partial reads.
    // capture.transferComplete / failure describe the transfer, not interpretation.
    // capture.decoded separates usable records, opaque records and parsing issues.
}
```

The reader obtains firmware, battery and the device wall clock, then uses a fresh
local connection per history. A failed history does not discard earlier results
or prevent later categories being attempted, except for a conflicting history
response: that stops the sequence to avoid moving another reader's shared cursor. Cancellation delivers the current
partial capture before throwing. Initial connection/metadata failures throw;
clock failure is recorded separately. The ring clock has no time zone.
Each snapshot and standalone capture retains the selected CoreBluetooth
`peripheralID` for provenance. This is a private, host-scoped identifier, not a
global device serial/MAC; protect it along with the health data. Capture times
describe a sequential acquisition, not an atomic measurement of every category.
Unattempted categories have `startedAt: nil`.
Per-history limits default to 2 MB and 120 seconds. The callback can persist each
attempt before the next begins. Invalid limits fail before Bluetooth initialization.
Each snapshot capture stream retains complete notification boundaries within its
own byte budget. A packet that would exceed that budget is omitted and the failure
is recorded; a conflicting history still stops acquisition even if that packet
cannot fit. Packet-level journaling is also possible through
`RingClient.readRawHistory(_:onNotification:)`; custom callbacks manage their own
storage limits and may synchronously call `disconnect()` to stop the read.

## Coverage

| Command | History | Structured representation |
| --- | --- | --- |
| 0x56 | HRV | Raw HRV/stress, heart rate, timestamp and full bytes |
| 0x53 | Sleep | One/five-minute arrays and explicit-profile classification |
| 0x54 | Dynamic heart rate | Timestamp and 15 bpm samples; sample spacing unknown |
| 0x55 | Spot heart rate | Timestamp and bpm |
| 0x62 | Temperature | SDK-scaled value/raw integer; unit unset; full 11/15-byte rows |
| 0x66 | Automatic oxygen | Timestamp and SDK-labelled saturation percent |
| 0x67 | Manual oxygen | Legacy 10-byte decoding or observed 31-byte opaque rows |
| 0x52 | Detailed activity | Steps, SDK-scaled calories/distance, ten step bytes |
| 0x51 | Daily activity | Date-only unsigned totals and raw time/goal fields |
| 0x5c | Exercise | SDK mode, bpm, steps, pace components, SDK float values |

All ten transfers completed on the tested iOS/ring combination. Exercise returned
a valid empty history. Detailed activity retained one observed counter gap; a
separate reread returned exactly the same record payloads and gap. The library
reports that gap rather than filling it or claiming complete physiological
coverage. Temperature extends the legacy 11-byte layout to 15 bytes;
extra bytes remain uninterpreted. Manual oxygen uses 31-byte rows incompatible
with the old SDK's 10-byte format. Those rows remain `opaqueRecords`, with no
fabricated dates or oxygen values. Other model/firmware support is unverified.

`RingHistoryCodec.decode` returns `hrv`, `sleep`, `sensors`, `opaqueRecords`,
`issues` and `unparsedNotifications`. Unknown/corrupt notifications retain their
index/error and bytes while other packets remain available. Each sensor record
retains `rawBytes`, `format`, `dateOnly`, measurements and sample series. The
capture also retains the exact original notifications.

Units are supplied where established (`bpm`, `%`, `count`). `unit: nil` means
unknown, not unitless. Temperature, calories, distance, time and goal values do
not acquire guessed units; some depend on device settings/extensions. A series
with `intervalSeconds: nil` cannot be expanded into per-sample timestamps.
Zero and out-of-range values are preserved, not certified as valid measurements.

## Pagination

The SDK sample requests read mode 2 after 50 notifications. Some tested histories
stream beyond that boundary themselves; dynamic heart rate really stalls there.
A hardware attempt also stalled after 49 received notifications, so a received
packet count cannot safely determine a page boundary. The client continues only
after three seconds without another matching notification. A new packet cancels
the pending continuation wait, including one already ready to resume. Total request timeout
and byte/record limits still bound the transfer. This completed the previously
partial heart-rate history. Erase mode 0x99 is never exposed.

An end marker is only a framing result. `decoded.integrity` exposes observed
header-counter gaps, duplicate transitions and out-of-order transitions. A gap
may indicate missing notifications, concurrent requests moving the ring's shared
cursor, or a firmware/storage gap; the library does not silently choose a cause.
The observed counter is one byte for daily totals and two bytes for other known
records, with wrap handling. Unrecognized notifications during a request are
retained separately as `unexpectedNotifications`, under their own byte budget.
Avoid vendor-app/other-client sync during an exclusive full-history read. A clean
counter range also cannot prove that the ring still retains every past measurement.
If another stored-history response arrives during a request, the client preserves
it and fails the request instead of blending responses. The bulk reader sets
`stopReason` and marks remaining categories `attempted: false`; it does not send
more requests that might reset another reader's shared history cursor. Unrelated
live/metadata notifications are preserved without being parsed as the requested kind.

## Resume history from an existing record

```swift
// Use a timestamp from a previously persisted record of the same command.
let raw = try await client.readRawHistory(.spotHeartRateHistory,
                                         resumingFrom: savedHeartRecord.timestamp)
let records = try await client.readHRVHistory(resumingFrom: savedHRVRecord.timestamp)
```

The supported subset is spot heart rate (0x55), HRV (0x56) and ordinary temperature
(0x62). On firmware 0.7.5.0, an exact retained record timestamp returned that record
and newer records. An arbitrary nonmatching cutoff instead returned all retained
history. This is an **inclusive resume hint, not a guaranteed date-range filter**.
Other firmware and missing/expired timestamps may behave differently.

Preserve the timestamp from the same device and history kind, including seconds.
It is a ring-local calendar value with no time zone. Do not substitute phone UTC,
round to a minute or use the current clock as a cursor. Years outside 2000–2099
and invalid dates fail before a Bluetooth write. Other commands reject a non-nil
hint until their behavior is established. Nil preserves the original all-retained
history request. Existing `RingTimestamp` values can be reused directly; its public
initializer is available when reconstructing persisted components.

Initial mode 0 and continuation mode 2 carry the same timestamp fields. Hardware
checks completed all three commands with exact recent timestamps, included the
anchor and returned no earlier record. Nonmatching requests completed too, but
returned old records; consumers must accept and deduplicate those records rather
than treating a requested timestamp as proof of returned coverage. The raw API
does not discard data client-side to simulate device filtering.

Persist the resume hint beside the raw result when journaling: `RingRawHistory`
contains responses, not request parameters. Advance a saved cursor only after
successful durable persistence, and retain overlapping anchors to catch late data.
The bulk snapshot API continues to read all retained categories. See
[stress and ingestion timing](stress-and-ingestion.md) for incremental ingestion.

## Sleep stages

```swift
let records = snapshot.histories.first { $0.command == .sleepHistory }?.decoded.sleep ?? []
let analysis = try RingSleepAnalyzer.analyze(
    records, timeZone: historicalTimeZone,
    mapping: .issinFirmware0750,
    window: selectedNight // optional DateInterval, no guessed night boundaries
)
```

The profile maps `1 → deep`, `2 → light`, `3 → REM`, `5 → awake`. All four
stage-duration totals matched the vendor app on two separate nights. No personal
nightly values/screenshots are distributed. This is an observed device/firmware
profile, not a universal mapping or clinical validation. Codes 10/11 and future
values stay `unknown`. Callers explicitly choose this profile or supply a custom one.

The ring stores local wall-clock components without a time zone or UTC offset.
Callers supply the historical time zone explicitly. `RingTimestamp.date(in:)`
returns `nil` if conversion in that zone cannot preserve all original calendar
components, including invalid dates and local times skipped by a daylight-saving
change. Sleep analysis rejects those records. Repeated local times during a fall
daylight-saving change remain ambiguous: the protocol has no offset to distinguish
the two occurrences, so a time zone alone cannot establish which one was recorded.

Analysis returns a timestamped timeline and durations in seconds. Source
resolution is one/five minutes; block seconds jitter. Analysis aligns starts to
minute boundaries while preserving source timestamps/records. Identical overlap
counts once; conflicting overlap becomes unknown with both raw values retained.
Gaps between covered samples become `missing`, never awake/asleep. Missing input
outside the source span is not padded. Totals are not a sleep/recovery score.

## CLI and durable capture

```sh
bash scripts/smart-ring all --id <uuid>
bash scripts/smart-ring capture --id <uuid> --output ./private-captures
swift run smart-ring decode-raw history.json
swift run smart-ring analyze-sleep sleep-history.json --time-zone <zone> --profile issin-0.7.5.0
```

`all` prints one snapshot. `capture` creates a unique private directory (0700),
writes each result atomically as it arrives (0600), then writes `snapshot.json`.
Earlier files remain if the last file cannot be completed. Protect these health
data files. Offline commands accept `{command, notifications}` JSON (the `raw`
object inside a capture). Sleep CLI analysis requires the transfer terminator.
Unknown values and failures stay visible.
