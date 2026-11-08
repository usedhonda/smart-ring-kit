# Changelog

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
