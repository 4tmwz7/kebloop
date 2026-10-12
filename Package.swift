// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kebloop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kebloop", targets: ["Kebloop"])],
    targets: [
        .target(name: "KebloopCore"),
        .executableTarget(name: "Kebloop", dependencies: ["KebloopCore"], resources: [.process("Resources")]),
        .testTarget(name: "KebloopCoreTests", dependencies: ["KebloopCore"]),
        .testTarget(name: "KebloopTests", dependencies: ["Kebloop"])
    ],
    swiftLanguageModes: [.v5]
)
