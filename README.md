# SwiftMDict

SwiftMDict is a Swift 6 library for reading MDict 2.x dictionary (`.mdx`) and
resource (`.mdd`) archives.

## Capabilities

- MDX dictionary and MDD resource containers
- Uncompressed, LZO1X, and zlib blocks
- Encrypted key-block metadata (`Encrypted="2"`)
- UTF-8, UTF-16, GBK/GB18030, Big5, Shift-JIS, and EUC-JP keys
- Exact and prefix lookup using declared MDict key semantics
- Checked container layout, block checksums, and configurable resource limits
- In-memory or mapped-file loading with bounded block caching

Full-content encryption (`Encrypted="1"`) and MDict 1.x are not supported.

## Installation

Add this package to a SwiftPM target:

```swift
.package(url: "https://github.com/qiyangdev/SwiftMDict.git", from: "0.1.0")
```

SwiftMDict requires Swift 6.0 or newer.

Linux builds require the zlib development package (`zlib1g-dev` on Debian and
Ubuntu). Apple platforms use the system zlib library.

## Usage

```swift
import SwiftMDict

let dictionary = try MDict(contentsOf: dictionaryURL)
let definition = try dictionary.text(for: "apple")

let suggestions = dictionary.entries(matchingPrefix: "app", limit: 10)
let record = try dictionary.record(for: suggestions[0])
```

Resource archives use the same interface:

```swift
let resources = try MDict(contentsOf: resourceURL)
let fontData = try resources.data(for: "\\font\\DictBats.ttf")
```

For UI code, move file loading away from the caller's executor:

```swift
let dictionary = try await MDict.open(contentsOf: dictionaryURL)
```

An interactive SwiftUI example for browsing and querying the local ignored Oxford
fixture is available as a separate package under `Examples/DictionaryDemo`.
Open that package with Xcode 26 or newer, select the `DictionaryDemo` scheme,
and run the `Local MDict Browser` playground. Keeping the demo in a nested
package prevents Apple-only playground tooling from affecting the portable
library build or Linux CI.

## Resource Policy

`MDictOptions` controls:

- mapped or in-memory file loading
- exact and prefix index construction
- decompressed-block cache count and byte limits
- maximum file, header, entry, block, decompressed, and record sizes

Defaults are intended for normal desktop and mobile dictionaries. Tighten
`MDictLimits` when processing untrusted files in constrained environments.

## Key Semantics

Lookup and prefix search apply `KeyCaseSensitive` and `StripKey` from the
container header. Returned entries retain their original spelling and file
order. Entries are owned by the dictionary that created them; passing an entry
to another dictionary throws `MDictError.foreignEntry`.

## Testing

The committed tests generate portable MDX fixtures in memory, including
corruption, limit, alias, duplicate-key, cross-block, and LZO cases. A local
Oxford MDX/MDD pair can be placed under `Tests/oxfordstu_no_audio/` for optional
integration coverage; those files remain ignored because redistribution rights
are unknown.

## License

SwiftMDict is available under the MIT License. The LZO1X decoder is adapted from
the Apache-2.0-licensed Aircompressor project. See `NOTICE` and
`LICENSES/Apache-2.0.txt` for attribution and license terms.
