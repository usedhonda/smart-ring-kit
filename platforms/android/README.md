# Android implementation — not implemented

This directory reserves the platform boundary; there is no Gradle project, Maven
artifact, Bluetooth client or Android compatibility claim yet.

An Android contribution should provide:

1. A Kotlin codec for a named protocol family, using the language-neutral spec and
   `protocols/<id>/fixtures` vectors. Unknown/opaque bytes and units stay visible.
2. Android Bluetooth transport separate from pure decoding, with host-managed
   permissions, cancellation, bounds and connection lifecycle. Keep all commands
   read-only and document exclusive-read requirements.
3. Exact device/firmware selection using `devices/` evidence. Do not turn one
   Apple hardware result into an Android hardware claim.
4. A reproducible Gradle build, JVM codec tests using the shared vectors and an
   Android CI job in the same PR. Do not require connected hardware in CI.
5. Installation/use documentation, dependency licenses and an honest verification
   matrix before publishing an artifact.

Keep the first port within `platforms/android`; do not relocate the root Swift
Package or copy proprietary vendor SDK code/binaries. Shared spec/catalog/vector
changes belong outside either platform and need both implementations' checks once
both exist. See [CONTRIBUTING](../../CONTRIBUTING.md).
