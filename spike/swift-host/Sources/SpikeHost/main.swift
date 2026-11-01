// Drives the Rust core from Swift: async/await, throws, callbacks.
// Usage: SpikeHost <host> <port> <user>  [--via <host> <port> <user>]   (password from SPIKE_PASSWORD)
import Foundation
import JenaFileCore

final class Listener: EventListener, @unchecked Sendable {
    func onLog(hop: String, message: String) {
        print("[\(hop)] \(message)  (thread: \(Thread.isMainThread ? "main" : "background"))")
    }
    func onHostKey(hop: String, algorithm: String, fingerprint: String) -> Bool {
        // SPIKE_REJECT_HOP=bastion|target simulates the user pressing "don't trust".
        let reject = ProcessInfo.processInfo.environment["SPIKE_REJECT_HOP"] == hop
        print("[\(hop)] host key \(algorithm) \(fingerprint) -> \(reject ? "REJECT" : "trust") (spike)")
        return !reject
    }
}

let args = CommandLine.arguments
guard args.count >= 4, let password = ProcessInfo.processInfo.environment["SPIKE_PASSWORD"] else {
    print("usage: SpikeHost <host> <port> <user> [--via <host> <port> <user>]  (SPIKE_PASSWORD)")
    exit(2)
}
let target = Endpoint(host: args[1], port: UInt16(args[2])!, user: args[3], password: password)
var via: Endpoint? = nil
if let i = args.firstIndex(of: "--via"), args.count >= i + 4 {
    via = Endpoint(host: args[i + 1], port: UInt16(args[i + 2])!, user: args[i + 3], password: password)
}

let started = Date()
do {
    let conn = try await connect(target: target, via: via, listener: Listener())
    print("connected in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
    let home = try await conn.home()
    // SFTP listing and a shell command on the same session, concurrently.
    async let files = conn.list(path: home)
    async let uname = conn.run(command: "hostname; uname -sr")
    let (entries, out) = try await (files, uname)
    print("home \(home):")
    for e in entries { print("  \(e.isDir ? "d" : "-") \(e.name) \(e.size)") }
    print("shell: \(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
} catch let e as CoreError {
    print("CoreError: \(e)")
    exit(1)
}
