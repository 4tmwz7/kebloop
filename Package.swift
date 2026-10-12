// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kebloop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kebloop", targets: ["Kebloop"])],
    targets: [
        .target(name: "KebloopCore"),
        .executableTarget(name: "Kebloop", dependencies: ["KebloopCore"]),
        .testTarget(name: "KebloopCoreTests", dependencies: ["KebloopCore"])
    ],
    swiftLanguageModes: [.v5]
)
