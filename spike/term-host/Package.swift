// swift-tools-version:5.9
// SwiftTerm Korean IME check. The real app feeds TerminalView from a russh
// channel instead of a local process, but IME handling lives in the view.
import PackageDescription

let package = Package(
    name: "TermHost",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0")],
    targets: [.executableTarget(name: "TermHost", dependencies: ["SwiftTerm"], path: "Sources/TermHost")]
)
