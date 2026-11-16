// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Topside",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopsideEngine", targets: ["TopsideEngine"]),
        .library(name: "TopsideRunners", targets: ["TopsideRunners"]),
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

        .testTarget(name: "TopsideCoreTests", dependencies: ["TopsideCore"]),
        .testTarget(name: "TopsideIPCTests", dependencies: ["TopsideIPC"]),
        .testTarget(name: "TopsideEngineTests",
                    dependencies: ["TopsideEngine", "TopsideRunners", "TopsideCore"]),
        .testTarget(name: "TopsideRunnersTests", dependencies: ["TopsideRunners", "TopsideCore"]),
    ]
)
