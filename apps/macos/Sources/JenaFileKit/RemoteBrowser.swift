import Foundation
import JenaFileCore

/// Remote pane state (기획서 §7.3 states). Talks to the core; views observe `onChange`.
@MainActor
public final class RemoteBrowser {
    public enum State: Equatable {
        case disconnected
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var connection: UInt64?
    public private(set) var path: String = ""
    public private(set) var entries: [RemoteEntry] = []
    public private(set) var state: State = .disconnected
    public var onChange: (() -> Void)?

    private let core: Core
    private var loadToken = 0

    public init(core: Core) {
        self.core = core
    }

    public func attach(_ connection: UInt64) async {
        self.connection = connection
        do {
            let home = try await core.home(connection: connection)
            await open(home)
        } catch {
            set(.failed(UserMessage.describe(error)))
        }
    }

    public func detach() {
        connection = nil
        entries = []
        path = ""
        set(.disconnected)
    }

    /// Keeps the previous listing visible (dimmed by the view) while loading.
    public func open(_ newPath: String) async {
        guard let connection else { return }
        loadToken += 1
        let token = loadToken
        set(.loading)
        do {
            let list = try await core.list(connection: connection, path: newPath)
            guard token == loadToken else { return }   // a newer request won
            path = newPath
            entries = list
            set(.loaded)
        } catch {
            guard token == loadToken else { return }
            set(.failed(UserMessage.describe(error)))
        }
    }

    public func enter(_ entry: RemoteEntry) async {
        guard entry.isDir || entry.isSymlink else { return }
        await open(RemotePath.join(path, entry.name))
    }

    public func goUp() async {
        await open(RemotePath.parent(path))
    }

    public func refresh() async {
        await open(path)
    }

    private func set(_ s: State) {
        state = s
        onChange?()
    }
}

/// POSIX remote paths (never use the local file system's rules for these).
public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/", let slash = path.dropLast(path.hasSuffix("/") ? 1 : 0).lastIndex(of: "/") else { return "/" }
        let p = String(path[..<slash])
        return p.isEmpty ? "/" : p
    }
}

public enum Format {
    public static func size(_ bytes: UInt64, isDir: Bool) -> String {
        isDir ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    public static func date(_ unix: UInt64?) -> String {
        guard let unix else { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// `rwxr-xr-x` from mode bits.
    public static func permissions(_ mode: UInt32?) -> String {
        guard let mode else { return "" }
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
