// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Topside",
    platforms: [.macOS(.v14)],
    products: [

    ],
    targets: [
        // Data model, task state machine, runner protocol. No AppKit, no agent names.
        .target(name: "TopsideCore"),
        // Newline-delimited JSON over a Unix domain socket.
        .target(name: "TopsideIPC"),

        .testTarget(name: "TopsideCoreTests", dependencies: ["TopsideCore"]),
        .testTarget(name: "TopsideIPCTests", dependencies: ["TopsideIPC"]),
    ]
)
