// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "DshBar",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "DshBar", targets: ["DshBar"]),
    .executable(name: "dshbar-snap", targets: ["DshBarSnapshot"]),
    .executable(name: "dshbar-check", targets: ["DshBarCheck"]),
    .executable(name: "dshbar-smoke", targets: ["DshBarSmoke"]),
  ],
  targets: [
    .target(name: "DshBarKit", path: "Sources/DshBarKit"),
    .executableTarget(
      name: "DshBar",
      dependencies: ["DshBarKit"],
      path: "Sources/DshBar"
    ),
    .executableTarget(
      name: "DshBarSnapshot",
      dependencies: ["DshBarKit"],
      path: "Sources/DshBarSnapshot"
    ),
    .executableTarget(
      name: "DshBarCheck",
      dependencies: ["DshBarKit"],
      path: "Sources/DshBarCheck"
    ),
    .executableTarget(
      name: "DshBarSmoke",
      dependencies: ["DshBarKit"],
      path: "Sources/DshBarSmoke"
    ),
  ]
)
