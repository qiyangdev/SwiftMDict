// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftMDictDictionaryDemo",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "DictionaryDemo",
      type: .dynamic,
      targets: ["DictionaryDemo"]
    )
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(
      name: "DictionaryDemo",
      dependencies: [
        .product(name: "SwiftMDict", package: "SwiftMDict")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
