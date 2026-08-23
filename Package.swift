// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexNotch", targets: ["CodexNotch"]),
        .executable(name: "CodexNotchSelfTest", targets: ["CodexNotchSelfTest"])
    ],
    targets: [
        .target(
            name: "CodexNotchCore",
            path: "Sources/CodexNotchCore"
        ),
        .executableTarget(
            name: "CodexNotch",
            dependencies: ["CodexNotchCore"],
            path: "Sources/CodexNotch"
        ),
        .executableTarget(
            name: "CodexNotchSelfTest",
            dependencies: ["CodexNotchCore"],
            path: "Sources/CodexNotchSelfTest"
        ),
        .testTarget(
            name: "CodexNotchCoreTests",
            dependencies: ["CodexNotchCore"],
            path: "Tests/CodexNotchCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
