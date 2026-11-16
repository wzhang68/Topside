// swift-tools-version:5.10
// M0 spike: island window prototype. Throwaway code, not part of the product.
import PackageDescription

let package = Package(
    name: "WindowSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WindowSpike", path: "Sources")
    ]
)
