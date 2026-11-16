// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Topside",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopsideRunners", targets: ["TopsideRunners"]),
    ],
    targets: [
        // Data model, task state machine, runner protocol. No AppKit, no agent names.
        .target(name: "TopsideCore"),
        // Newline-delimited JSON over a Unix domain socket.
        .target(name: "TopsideIPC"),
        // One runner per agent: command lines and event-stream parsers.
        .target(name: "TopsideRunners", dependencies: ["TopsideCore"]),

        .testTarget(name: "TopsideCoreTests", dependencies: ["TopsideCore"]),
        .testTarget(name: "TopsideIPCTests", dependencies: ["TopsideIPC"]),
        .testTarget(name: "TopsideRunnersTests", dependencies: ["TopsideRunners", "TopsideCore"]),
    ]
)
