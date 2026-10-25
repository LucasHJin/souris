// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SourisCore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "SourisCore", targets: ["SourisCore"]),
    .executable(name: "souris-replay", targets: ["SourisReplay"]),
  ],
  targets: [
    .target(name: "SourisCore"),
    .executableTarget(
      name: "SourisReplay",
      dependencies: ["SourisCore"],
      path: "Sources/souris-replay"),
    .testTarget(name: "SourisCoreTests", dependencies: ["SourisCore"]),
  ]
)
