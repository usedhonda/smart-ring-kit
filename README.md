# SmartRingKit

An open-source toolkit for reading smart-ring data directly over Bluetooth LE,
with shared protocol specifications, device/firmware profiles and platform implementations.

The project brings protocol evidence and reusable test data together so contributors
can add devices, firmware variants and platform ports in one place. The first
implementation targets the **issin Smart Recovery Ring**, firmware `0.7.5.0`,
using the observed FFF0 protocol. This is an experimental, unofficial project,
unaffiliated with issin or J-Style.

## Current support

| Component | Status |
| --- | --- |
| Device | issin Smart Recovery Ring; other devices unverified |
| Firmware | Exactly `0.7.5.0`; other versions do not inherit its interpretation profile |
| iOS | Swift implementation; all ten stored-history transfers verified on one ring |
| macOS | Same Apple implementation and CLI; build/codec tests pass; full-history radio acquisition unverified |
| Android | Not implemented; [porting guide](platforms/android/README.md) available |

Compatibility is tracked by **device + exact firmware + platform**, not inferred
from a matching BLE service or advertising name. See the [device catalog](devices/README.md)
for evidence and field-level limitations.

## Data available today

The current FFF0 implementation reads firmware, battery, device clock and ten
stored-history categories:

- Raw HRV/fatigue (legacy `stressRaw`), dynamic heart rate and spot heart rate.
- Sleep categories, with an explicitly selected deep/light/REM/awake profile.
- Temperature, automatic oxygen and manual oxygen.
- Detailed activity, daily activity and exercise.

Transfers retain original notifications, decoded records, opaque records,
per-category failures and observed counter gaps. A completed transfer does not
mean every field is understood or every past measurement is still retained.
Manual oxygen's observed 31-byte records remain opaque; some units are unknown.
Exercise returned an empty history on hardware, so nonempty decoding remains
hardware-unverified. Sleep-stage totals matched the vendor app on two nights;
unknown codes, conflicts and missing coverage remain visible. No score is invented.
Timestamp resume hints are available for spot heart rate, HRV and ordinary
temperature; unmatched hints may return all retained history. The vendor app's finer-grained stress score is not decoded;
see [stress evidence and ingestion timing](docs/stress-and-ingestion.md).
See the [data contract](docs/data-model.md) for details.

[Multimodal stress research inputs](docs/stress-analysis.md) combine heart rate,
raw HRV/fatigue, activity, temperature, oxygen and explicitly mapped sleep with
source times, age limits and conflicts preserved. The Apple API and offline CLI
include a descriptive heart-rate reference, not a validated stress score.

[Experimental native-fatigue estimation](docs/native-fatigue-estimation.md) learns
from prior device observations and emits ten-minute slots with explicit native,
estimated or unavailable status. Four correction methods support comparison;
no psychological-stress accuracy or iOS scheduling guarantee is claimed.

All implemented device requests are read-only. The toolkit does not configure
sampling, erase data, update firmware or access the manufacturer's account/cloud.
Concurrent vendor-app history requests interfered with acquisition; use exclusive
reads. Background sync and real-time measurements remain unverified.

## Use it in your application

- **iOS/macOS:** [Apple installation, capture API, sleep analysis and CLI](platforms/apple/README.md).
  The current library uses Swift Package Manager; its module is `SmartRingKit`.
- **Android:** no library artifact yet. Start with the [platform contribution guide](platforms/android/README.md).
- **Other devices/firmware:** check the [catalog](devices/README.md) before reusing
  a driver or mapping. Unknown firmware receives no automatic interpretation.

Shared specifications and synthetic fixtures are language-neutral. A port can
reuse them without depending on the Apple implementation.

## Repository map

| Location | Purpose |
| --- | --- |
| [`protocols/`](protocols/fff0/README.md) | Wire formats, evidence and synthetic cross-language decoder vectors |
| [`devices/`](devices/README.md) | Product compatibility and exact firmware profiles |
| [`platforms/apple/`](platforms/apple/README.md) | Current Swift library, macOS CLI, tests and examples |
| [`platforms/android/`](platforms/android/README.md) | Future Android implementation boundary and porting guide |
| [`docs/architecture.md`](docs/architecture.md) | Protocol, device/firmware and platform boundaries |
| [`Package.swift`](Package.swift) | Stable root entry point for the Apple package |

## Contribute

[CONTRIBUTING.md](CONTRIBUTING.md) walks through adding another device, a firmware
variant or a platform implementation, constructing synthetic test data and opening
a PR. Document what was actually tested; preserve unknown fields and compatibility
limits. Do not publish personal health captures, device identifiers or proprietary
SDK artifacts. The PR template covers evidence, validation and provenance.

[Latest release](https://github.com/usedhonda/smart-ring-kit/releases/latest) ·
[Changelog](CHANGELOG.md)

## License

Original implementation, documentation and synthetic fixtures: [MIT](LICENSE).
Commercial and closed-source embedding is permitted with the required notices.
Read the [embedding and third-party reference notes](docs/licensing.md); this
project's MIT license does not relicense a vendor's SDK, firmware or assets.
