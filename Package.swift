// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "lxspike",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "lxspike", targets: ["lxspike"]),
    .executable(name: "Cadence", targets: ["Cadence"]),
  ],
  targets: [
    .target(name: "CZlib", path: "Sources/CZlib"),
    .target(
      name: "LxSourceKit",
      dependencies: ["CZlib"],
      path: "Sources/LxSourceKit",
      resources: [.process("glue.js")]
    ),
    .executableTarget(name: "lxspike", dependencies: ["LxSourceKit"], path: "Sources/lxspike"),
    .executableTarget(name: "Cadence", dependencies: ["LxSourceKit"], path: "Sources/Cadence"),
  ]
)
