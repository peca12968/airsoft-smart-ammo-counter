// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AirsoftSmartAmmo", platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)], products: [.library(name: "AmmoCore", targets: ["AmmoCore"])], targets: [.target(name: "AmmoCore"), .testTarget(name: "AmmoCoreTests", dependencies: ["AmmoCore"])])
