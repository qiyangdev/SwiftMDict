# Contributing

## Development

SwiftMDict uses SwiftPM, Swift 6 language mode, and Swift Testing.

```sh
swift test
swift test -c release
```

Linux development requires the zlib development package.

The optional Oxford MDX/MDD fixtures belong under
`Tests/oxfordstu_no_audio/`. They are intentionally ignored and must not be
committed unless their redistribution rights are established.

## Pull Requests

- Add focused tests for parser and lookup behavior changes.
- Keep untrusted-input limits and checked arithmetic intact.
- Format Swift sources with `swift-format`.
- Update `README.md` or DocC when public API behavior changes.
- Do not add generated `.swiftpm`, `.build`, Xcode user-data, or dictionary
  fixtures.
