# SmartRingKit contributor instructions

- Keep the public package independent of any consuming app.
- The initial driver implements the observed FFF0 read subset; do not imply support for all rings.
- Keep all device requests read-only. Do not add reset, erase, pairing changes, clock setting, or firmware update commands without an explicit design decision.
- Keep personal captures, device identifiers, credentials, and machine-specific paths outside tracked files. Use synthetic fixtures.
- Keep raw SDK-labelled values distinct from interpreted health metrics. Timestamps have no inherent time zone.
- Run `swift test` for parser/client changes. Build the library for iOS for Apple transport changes. Do not require a physical ring in CI.
- CoreBluetooth callbacks use the main queue; RingClient and its delegate conformances rely on main-actor execution.
- Maintain protocol evidence and limitations in docs/protocol.md. Do not vendor third-party SDK source without an applicable redistribution license.
