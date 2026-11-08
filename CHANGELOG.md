# Changelog

## Unreleased

- Exclude the current heart-rate observation from its own descriptive reference, including when evaluation occurs after the observation.
- Include the overlapping portion of completed sleep samples at a historical window boundary while excluding samples still in progress at evaluation.

## 0.7.0 — 2026-11-08

- Add an experimental native-fatigue predictor with explicit carry, regression, residual and learned-decay modes; no pretrained weights or psychological-stress validation.
- Track measurement and availability times, preserve native versus estimated versus unavailable results, and exclude current HRV/fatigue inputs from the feature adapter.
- Fit decay using past-day prediction errors, reject missing/stale/conflicting/extrapolated inputs, and add an offline ten-minute replay CLI.
- Document chronological hidden-anchor evaluation, uncertain modality meanings and iOS scheduling limits.

## 0.6.0 — 2026-11-08

- Assemble multimodal stress-research inputs with explicit historical clocks, age policy, latest-record conflicts, missing categories and preserved unknown units.
- Add optional descriptive median/MAD heart-rate references and explicitly windowed/profiled sleep context; no validated stress score or fusion weights are introduced.
- Add an offline `analyze-stress-inputs` CLI and document scientific references, source limitations and evaluation requirements.
- Record experimentally verified ten-minute native HRV/fatigue storage and the limits of the offline app-stress observation.

## 0.5.0 — 2026-11-08

- Resume spot-heart-rate, HRV and ordinary-temperature history from an existing record timestamp, preserving the hint during pagination; document full-history fallback for unmatched timestamps.
- Clarify the distinction between raw fatigue and vendor-app stress; document sample/receipt timing and incremental ingestion.

## 0.4.1 — 2026-11-08

- Keep CLI capture directories ignored and harden CI checkout credentials, pinning and timeouts.
- Require record-aligned history terminators so marker-shaped payload bytes do not end a transfer early.
- Reject timestamp conversions that normalize invalid or daylight-saving-skipped local times.
- Isolate raw-read callbacks and cancel stale pagination waits before they can affect another operation.
- Bound partial capture buffers and preserve conflict detection when byte budgets are exhausted.
- Validate snapshot limits before Bluetooth initialization and avoid unused CLI Bluetooth clients.
- Update project/Apple usage documentation and correct published commit attribution.

## 0.4.0 — 2026-11-08

- Separate platform implementations, protocol evidence/vectors and exact device/firmware profiles.
- Preserve root Swift Package entry points and existing public APIs.
- Add exact firmware profile lookup without fallback to unknown devices or versions.
- Check shared synthetic decoder vectors and Swift/catalog agreement in CI.
- Document contributions for new devices, firmware and Android ports, plus embedding/license obligations.

## 0.3.0 — 2026-11-08

- Read all ten stored-history categories in one call with raw data, decoded records and per-category failures.
- Complete dynamic heart-rate pagination using idle-aware read-only continuation.
- Decode supported heart-rate, oxygen, temperature, activity and exercise layouts.
- Preserve unknown 31-byte manual-oxygen records and unknown units without fabricating values.
- Add an explicit firmware-specific deep/light/REM/awake mapping, checked against two vendor-app nights.
- Produce deduplicated sleep timelines and stage durations with unknown/conflicting/missing data visible.
- Add read-only device-clock metadata, durable private CLI capture and offline decoding/analysis.

## 0.2.0 — 2026-11-07

- Add experimental SDK-layout sleep-history reads and offline sleep decoding.
- Preserve unlabelled sleep category arrays, sample intervals and original bytes.
- Add bounded raw-history probes for heart rate, temperature, oxygen and activity.
- Add a notification callback for private partial-capture diagnostics.
- Keep firmware/configuration/deletion operations outside the API.

## 0.1.0 — 2026-11-07

- Initial experimental Swift library for the observed FFF0 read protocol.
- Firmware, battery, and HRV-history reads using CoreBluetooth.
- Strict history decoding, raw value preservation, explicit time-zone conversion.
- macOS CLI, offline packet decoding, and a SwiftUI reader example.
- Synthetic tests and macOS/iOS CI; no personal captures or third-party SDK code.
