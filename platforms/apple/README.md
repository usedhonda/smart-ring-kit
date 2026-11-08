# Apple implementation

Swift 6+, iOS 16+ and macOS 13+. Use `Package.swift` at the repository root;
`import SmartRingKit`, the library product and CLI product names remain unchanged.

From the repository root:

```sh
swift test
bash scripts/smart-ring --help
xcodebuild -scheme SmartRingKit -destination 'generic/platform=iOS' \
  -derivedDataPath .local/ios-build CODE_SIGNING_ALLOWED=NO build
```

`Drivers/FFF0` owns the current protocol. Its `Apple/` subdirectory owns
CoreBluetooth acquisition. New protocols get sibling driver directories; device
and firmware interpretations get profiles and catalog entries. Radio behavior
requires hardware evidence; CI exercises codecs, catalog consistency and builds.
See [architecture](../../docs/architecture.md) and [contribution guide](../../CONTRIBUTING.md).
