// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JenaFile",
    platforms: [.macOS(.v13)],
    dependencies: [
        // jenalab fork: keeps the caret visible during Korean IME composition (ADR-008).
        .package(url: "https://github.com/jenalab-com/SwiftTerm", exact: "1.99.2-jenafile.1"),
    ],
    targets: [
        // Built by scripts/build-core.sh (not committed).
        .binaryTarget(name: "jenafile_ffiFFI", path: "Vendor/JenaFileCore.xcframework"),
        // UniFFI-generated Swift (not committed).
        .target(name: "JenaFileCore", dependencies: ["jenafile_ffiFFI"], path: "Sources/JenaFileCore"),
        .target(name: "JenaFileKit", dependencies: ["JenaFileCore"], path: "Sources/JenaFileKit"),
        .executableTarget(name: "JenaFile", dependencies: ["JenaFileKit", "SwiftTerm"], path: "Sources/JenaFile"),
        .testTarget(name: "JenaFileKitTests", dependencies: ["JenaFileKit"], path: "Tests/JenaFileKitTests"),
    ]
)
