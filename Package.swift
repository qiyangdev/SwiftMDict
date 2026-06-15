// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftMDict",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
    .tvOS(.v15),
    .watchOS(.v8),
    .visionOS(.v1),
  ],
  products: [
    .library(
      name: "SwiftMDict",
      targets: ["SwiftMDict"]
    )
  ],
  targets: [
    .systemLibrary(
      name: "CZlib",
      providers: [
        .apt(["zlib1g-dev"]),
        .brew(["zlib"]),
      ]
    ),
    .target(
      name: "SwiftMDict",
      dependencies: ["CZlib"]
    ),
    .testTarget(
      name: "SwiftMDictTests",
      dependencies: ["SwiftMDict", "CZlib"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
