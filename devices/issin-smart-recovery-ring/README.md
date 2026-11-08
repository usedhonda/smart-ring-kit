# issin Smart Recovery Ring

Device ID: `issin-smart-recovery-ring`. Observed protocol: `fff0`.
This unofficial implementation is not endorsed by the manufacturer.

## Firmware 0.7.5.0

[Machine-readable profile](firmware/0.7.5.0.json)

- Apple/iOS: all ten stored-history transfers completed in one public API run on
  one ring. Exercise returned a valid empty history; nonempty exercise decoding
  is supported by reference SDK evidence and remains hardware-unverified.
- Apple/macOS: package/CLI build and synthetic tests; all-history radio acquisition
  on macOS has not been hardware-verified.
- Android: no implementation or hardware verification yet.
- Sleep mapping: 1 deep, 2 light, 3 REM, 5 awake. All four duration totals matched
  the vendor app on two nights. Codes 10/11 remain unknown. This is interpretation
  of device output, not an independently validated sleep classifier.
- Temperature: observed 15-byte rows extend the legacy 11-byte layout. Units and
  extension fields remain unestablished. Manual oxygen's observed 31-byte rows
  remain opaque. A stable activity counter gap is retained and reported.
- Concurrent vendor-app history requests interfered with acquisition. Use exclusive
  reads; same-command collisions cannot be distinguished by the protocol.

See [protocol evidence and pinned references](../../protocols/fff0/README.md) and
[data interpretation limits](../../docs/data-model.md). Public examples are synthetic;
no personal captures, device identifiers or proprietary SDK artifacts are bundled.
Other firmware versions are unverified and must receive separate evidence/profile PRs.
