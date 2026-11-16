// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Topside",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "topside", targets: ["topside"]),
        .library(name: "TopsideCore", targets: ["TopsideCore"]),
        .library(name: "TopsideEngine", targets: ["TopsideEngine"]),
        .library(name: "TopsideRunners", targets: ["TopsideRunners"]),
        .library(name: "TopsideUIModel", targets: ["TopsideUIModel"]),
    ],
    targets: [
        // Data model, task state machine, runner protocol. No AppKit, no agent names.
        .target(name: "TopsideCore"),
        // Newline-delimited JSON over a Unix domain socket.
        .target(name: "TopsideIPC"),
        // Task engine: processes, worktrees, persistence, scheduling. No agent names.
        .target(name: "TopsideEngine", dependencies: ["TopsideCore", "TopsideIPC"]),
        // One runner per agent: command lines and event-stream parsers.
        .target(name: "TopsideRunners", dependencies: ["TopsideCore"]),
        // What the island shows, without AppKit: notch geometry, list order, launcher state.
        // The app (App/, built with XcodeGen) adds the windows and views on top.
        .target(name: "TopsideUIModel", dependencies: ["TopsideCore", "TopsideEngine"]),
        // Command-line entry point.
        .executableTarget(name: "topside",
                          dependencies: ["TopsideCore", "TopsideEngine", "TopsideRunners", "TopsideIPC"]),

        .testTarget(name: "TopsideCoreTests", dependencies: ["TopsideCore"]),
        .testTarget(name: "TopsideIPCTests", dependencies: ["TopsideIPC"]),
        .testTarget(name: "TopsideRunnersTests", dependencies: ["TopsideRunners", "TopsideCore"]),
        .testTarget(name: "TopsideEngineTests",
                    dependencies: ["TopsideEngine", "TopsideRunners", "TopsideCore"]),
        .testTarget(name: "TopsideUIModelTests", dependencies: ["TopsideUIModel", "TopsideCore"]),
    ]
)
