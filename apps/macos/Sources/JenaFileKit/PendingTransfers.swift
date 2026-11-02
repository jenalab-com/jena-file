import Foundation
import JenaFileCore

/// An unfinished transfer kept across app restarts (기획서 FR-16). `key` names the
/// route (target + bastion) so it comes back for the same server however it is
/// connected (quick connect or 서버 관리).
public struct PendingTransfer: Codable, Equatable {
    public var key: String
    public var upload: Bool
    public var local: String
    public var remote: String
    public var size: UInt64

    public init(key: String, upload: Bool, local: String, remote: String, size: UInt64) {
        self.key = key; self.upload = upload; self.local = local; self.remote = remote; self.size = size
    }

    /// Worth restoring: not done, skipped or cancelled.
    public static func unfinished(_ s: TransferState) -> Bool {
        switch s {
        case .queued, .running, .paused, .waiting, .failed: true
        case .done, .skipped, .cancelled: false
        }
    }
}

public struct PendingStore {
    public let url: URL

    public init(dataDir: URL) {
        url = dataDir.appendingPathComponent("pending-transfers.json")
    }

    public func load() -> [PendingTransfer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingTransfer].self, from: data)) ?? []
    }

    public func save(_ items: [PendingTransfer]) {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }
}

public enum RouteKey {
    public static func of(_ e: Endpoint) -> String { "\(e.user)@\(e.host):\(e.port)" }

    /// `target via bastion` — same text for quick connect and saved servers.
    public static func of(_ target: Endpoint, viaKey: String?) -> String {
        of(target) + (viaKey.map { " via " + $0 } ?? "")
    }
}
