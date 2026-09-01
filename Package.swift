// swift-tools-version: 6.0
import Foundation
import PackageDescription

let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let useCommandLineToolsTesting = ProcessInfo.processInfo.environment["CODEXNOTCH_USE_CLT_TESTING"] == "1"
let testSwiftSettings: [SwiftSetting] = useCommandLineToolsTesting
    ? [.unsafeFlags(["-F", commandLineToolsFrameworks])]
    : []
let testLinkerSettings: [LinkerSetting] = useCommandLineToolsTesting
    ? [
        .unsafeFlags([
            "-F\(commandLineToolsFrameworks)",
            "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
            "-Xlinker", "-rpath", "-Xlinker", commandLineToolsLibraries
        ])
    ]
    : []

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
            path: "Tests/CodexNotchCoreTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
