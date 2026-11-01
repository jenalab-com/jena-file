import Foundation
import JenaFileCore

/// Receives core events on the main thread, in order.
@MainActor
public protocol CoreEventHandler: AnyObject {
    func handle(_ event: CoreEvent)
}

/// UniFFI calls `onEvent` from tokio threads (UniFFI spike). This hops every
/// event onto the main queue, which is FIFO, so handlers see them in order.
public final class CoreBridge: CoreListener, @unchecked Sendable {
    @MainActor public weak var handler: CoreEventHandler?

    public init() {}

    public func onEvent(event: CoreEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handler?.handle(event) }
        }
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/jena-file (app's own known_hosts lives here).
    public static func dataDirectory() throws -> URL {
        // Dev / tests: JENAFILE_DATA_DIR keeps experiments out of the real app data.
        if let dev = ProcessInfo.processInfo.environment["JENAFILE_DATA_DIR"] {
            let dir = URL(fileURLWithPath: dev, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("jena-file", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Read-only (ADR-006).
    public static var userKnownHosts: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path
    }
}
