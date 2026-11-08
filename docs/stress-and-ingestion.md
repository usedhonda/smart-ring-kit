# Stress evidence and ingestion timing

## Separate the measurements

On the tested issin firmware `0.7.5.0`, a roughly thirty-minute capture of normal
vendor-app synchronization showed approximately ten-minute spot-heart-rate
records and finer-grained stress points in the app's diagnostic summaries.
HRV history was much coarser (hourly timestamps, with gaps). These are observations
of existing settings and retained records, not fixed guarantees or SDK read limits.

The vendor diagnostic log names byte 12 of the 0x56 HRV record `fatigue`.
`RingHRVRecord.stressRaw` preserves its legacy public name for compatibility,
but must not be advertised as the app's stress score. The app's fine stress
endpoints often share spot-heart-rate timestamps, and overlapping daily counts
frequently match. This suggests an association; it does not establish the formula
or show that the heart-rate row itself contains stress.

Normal synchronization in the captured window used FFF6 writes and FFF7
notifications. No separate fine-stress request was identified in that path.
An additional GATT service was discovered but its purpose remains unknown;
metadata discovery is not evidence of readable stress. This observation does not
rule out a different path in other app states or firmware.

Only summary endpoints were recovered from the app log, not its complete stress
arrays. A Mac-connected diagnostic capture is not a production iOS stress API.
The vendor formula, full history access and whether processing is local or remote
remain unresolved. SmartRingKit currently exposes no equivalent app stress score.
No app binary, SDK binary or vendor health data is distributed with this project.

## Sample time is different from receipt time

In this capture, newly observed app points appeared about 21–289 seconds after
their labelled times. The labels' start/end semantics are unknown, so this is
point-to-log timing, not a measured Bluetooth latency or a real-time guarantee.
A record timestamped during a multi-minute radio disconnection was recovered
following reconnection. A lost connection therefore does not establish that the
ring stopped measuring. Foreground app sync observations do not establish iOS
background scheduling behavior.

## Guidance for Recall and other consumers

Keep original ring-local components, the chosen historical time-zone basis,
measurement time, receipt time, device/firmware, requested resume hint, raw bytes and
transfer status. Backfill delayed records at their measurement times. Track
freshness per metric: one successful category read must not refresh every metric.
An incomplete transfer must not advance a durable cursor past unpersisted data.

Resume supported histories from a retained record timestamp and keep overlapping
anchors. Arbitrary cutoffs returned all retained data on the tested firmware; a
resume hint is not a date-filter guarantee. Accept older responses and deduplicate
using device/source, measurement time and record content, excluding transfer
sequence counters. Do not assume record arrival order
or infer missing sensor measurements solely from a communication gap. Periodic
broader backfill may recover older data; timestamp resumption cannot recover expired
storage. Preserve incomplete transfers and counter diagnostics separately.

Scheduling is a separate concern from acquisition. Reading one category per
background wake can leave each category stale for an entire rotation. Prioritize
recent heart-rate/HRV inputs, track each category's successful coverage, and use
foreground opportunities to catch up. An earliest background request time is
not a guaranteed execution interval. Do not fabricate ten-minute HRV or stress
points from hourly data.

Keep source semantics when combining HealthKit and direct ring data. Raw HRV is
not HealthKit SDNN. The fatigue byte is not vendor stress. Overlapping heart-rate,
oxygen and activity records need provenance-aware selection/deduplication rather
than summation or interchange. A future independently derived stress estimate
must have its own name, algorithm version and validity limits.

This document records integration guidance. It does not change Recall's code,
scheduling, HealthKit writes or user interface.
