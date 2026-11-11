// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Harbor", platforms: [.macOS("26.0")], products: [.executable(name: "Harbor", targets: ["Harbor"])], dependencies: [.package(path: "Vendor/Yams")], targets: [
.target(name: "HarborCore", dependencies: [.product(name: "Yams", package: "Yams")], swiftSettings: [.swiftLanguageMode(.v5)]),
.executableTarget(name: "Harbor", dependencies: ["HarborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
.testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"], swiftSettings: [.swiftLanguageMode(.v5)])])
