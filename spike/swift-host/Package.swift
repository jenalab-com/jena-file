// swift-tools-version:5.9
// Swift side of the UniFFI spike. Same layout jena-note uses for Kiwi:
// Rust staticlib packed as an xcframework binaryTarget + a thin Swift wrapper target.
import PackageDescription

let package = Package(
    name: "SpikeHost",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "jenafile_coreFFI", path: "../core-ffi/out/JenaFileCore.xcframework"),
        .target(name: "JenaFileCore", dependencies: ["jenafile_coreFFI"], path: "Sources/JenaFileCore"),
        .executableTarget(name: "SpikeHost", dependencies: ["JenaFileCore"], path: "Sources/SpikeHost"),
    ]
)
