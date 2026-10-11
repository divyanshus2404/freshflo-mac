// swift-tools-version:5.10
import PackageDescription

// Apple's on-device model only exists on macOS 26+; weak-link so older systems still launch.
let weakFoundationModels = LinkerSetting.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])

let package = Package(
    name: "ExcuseMe",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable lives in the library; the app target is just the entry point.
        .target(
            name: "ExcuseMeKit",
            path: "Sources/ExcuseMeKit",
            linkerSettings: [weakFoundationModels]
        ),
        .executableTarget(
            name: "ExcuseMe",
            dependencies: ["ExcuseMeKit"],
            path: "Sources/ExcuseMe",
            linkerSettings: [weakFoundationModels]
        ),
        // `swift run ExcuseMeChecks`: logic tests that run with just the Command Line Tools.
        .executableTarget(
            name: "ExcuseMeChecks",
            dependencies: ["ExcuseMeKit"],
            path: "Sources/ExcuseMeChecks",
            linkerSettings: [weakFoundationModels]
        ),
    ]
)
