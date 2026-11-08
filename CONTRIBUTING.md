# Contributing

Start with [the architecture](docs/architecture.md) and [device/firmware catalog](devices/README.md).
The current implementation is experimental FFF0 on Apple platforms. Contributions
for other devices and Android are welcome, but only claim what you can demonstrate.

## First local run

Fork and clone the repository, then run from its root:

```sh
python3 scripts/check-catalog.py
swift test
bash scripts/smart-ring --help
```

Apple development needs Swift 6+; iOS compilation also needs Xcode and the iOS SDK.
Codec tests do not need a ring or Bluetooth permission. Use a branch for your work.
The package root, product and module names remain stable despite platform folders.

## Commit attribution

Use your own name or handle and an email linked to your GitHub account. For email
privacy, copy the no-reply address issued in your own GitHub email settings;
`noreply@users.noreply.github.com` is not a generic anonymous address. Check
`git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT` before committing.
Add `Co-authored-by` only for actual co-authors, using an address they have confirmed.

The early placeholder identity was corrected in the published Git history and
release tags. A mailmap is not a replacement for setting the correct stored author
and committer identity. If you cloned before that correction, use a fresh clone
before contributing so that the old history is not accidentally reintroduced.

## Choose your contribution

### Another device

1. Identify the product and reported firmware privately. A BLE service UUID or
   similar product appearance does not establish compatibility.
2. Check `protocols/`: if the wire format matches an existing family, document
   the evidence and reuse it. If it differs, create a separate protocol directory
   and platform driver; do not stretch the FFF0 command enum to cover both.
3. Add `devices/<device-id>/README.md` with a platform/firmware evidence matrix,
   source references and specific limitations. Use a stable product slug, never
   a personal serial/MAC/advertising suffix.
4. Add an exact firmware manifest under `firmware/`. Start at `documented` or
   `synthetic-tested` if hardware is unavailable. Unknown interpretations stay
   unmapped; an unsupported firmware need not prevent preserving raw data.
5. Add the smallest codec/transport change needed, synthetic vectors for the new
   byte format and targeted tests. Keep requests read-only.

### New firmware on an existing device

1. Record the exact version string; do not edit the older profile to mean all
   newer versions. Add a new manifest and explain what changed or was rechecked.
2. Compare framing/layouts and interpreted fields separately. A completed transfer
   does not validate units, sleep mapping, scores or every retained sample.
3. Reuse codecs only for confirmed matching layouts. Firmware-specific meanings
   belong in profiles; include unknown values and regression cases for differences.
4. Update runtime profile selection and its catalog-consistency test. A known
   profile must never silently match an unknown firmware version.

### Android or another platform

Follow [the Android porting contract](platforms/android/README.md). Share protocol
specification, exact compatibility profiles and synthetic vectors. Keep Bluetooth
and permission handling native to the platform. Include the new platform's build
and codec test CI in the PR. Do not add an empty build or mark a planned port supported.

## Evidence without publishing personal data

Use your own device. Begin with discovery/metadata and known read-only requests;
do not brute-force undocumented commands because some may erase/configure a device.
Keep captures under ignored `.local/`. Shut down competing history sync before
reading; retain errors, partial packets, opaque rows and counter diagnostics.
Do not upload health histories, screenshots of personal metrics, identifiers,
account tokens, pairing secrets or proprietary firmware/SDK artifacts to issues/PRs.

Publish **constructed synthetic vectors** that reproduce the format or bug, rather
than lightly redacting an actual health capture. Put language-neutral packet data
and expected decoder results in `protocols/<id>/fixtures/` with a format version,
`synthetic: true` and the protocol ID. The first example is
[FFF0 history-v1.json](protocols/fff0/fixtures/history-v1.json); its inputs use decimal
byte arrays and expected record counts/selected fields. Keep shared expectations
independent of Swift/Kotlin APIs; add assertions to every implemented port's runner
when the vector format gains fields. Unknown vector format versions must fail.

Hardware reports should name the product, exact firmware, platform/OS, commands
attempted, completion/error status and interpretation checks. No identifiers or
actual health values are needed. State `not tested` where evidence is absent.
No one needs to own every supported device to submit a codec or documentation PR.

## Licensing and provenance

Contribute code/docs/synthetic fixtures that you have the right to submit under
this repository's MIT license. Keep existing copyright notices. This project
uses the same license for contributions; no CLA is required.

For external references, include the source URL, pinned commit/version, what was
learned and redistribution license if code is copied. A public repository without
an identified license does not grant permission to copy its SDK source, binaries
or assets into this MIT project. Port your own implementation from documented
behavior and respect applicable agreements. Do not label referenced implementation
work as clean-room unless that process actually occurred. New dependencies require
compatible licenses and retained notices; explain their need before adding them.
See [embedding and license notes](docs/licensing.md).

## Before opening a PR

- Run `python3 scripts/check-catalog.py` for catalog/spec changes.
- Run `swift test` for Apple codecs, profiles or analysis. Shared vector changes
  must be checked by every implemented platform runner.
- Build for iOS for Apple transport/package/layout changes using the command in
  [platforms/apple](platforms/apple/README.md). Keep hardware out of CI.
- Update the relevant protocol, device/firmware entry and usage documentation.
- Check the diff for private captures, identifiers, local paths and third-party code.

Use the PR template: describe the product/firmware/platform and what actually
works, the evidence, commands run and remaining unknowns. A small, reproducible
PR is easier to evaluate than broad unverified support claims. Preserve existing
public APIs or explain a required breaking change explicitly.
