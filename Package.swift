// swift-tools-version:5.10
import PackageDescription

// Apple's on-device model only exists on macOS 26+; weak-link so older systems still launch.
let weakFoundationModels = LinkerSetting.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])

let package = Package(
    name: "Freshflo",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable lives in the library; the app target is just the entry point.
        .target(
            name: "FreshfloKit",
            path: "Sources/FreshfloKit",
            linkerSettings: [weakFoundationModels]
        ),
        .executableTarget(
            name: "Freshflo",
            dependencies: ["FreshfloKit"],
            path: "Sources/Freshflo",
            linkerSettings: [weakFoundationModels]
        ),
        // `swift run FreshfloChecks`: logic tests that run with just the Command Line Tools.
        .executableTarget(
            name: "FreshfloChecks",
            dependencies: ["FreshfloKit"],
            path: "Sources/FreshfloChecks",
            linkerSettings: [weakFoundationModels]
        ),
    ]
)
