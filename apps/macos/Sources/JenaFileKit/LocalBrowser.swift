import Foundation

public struct LocalEntry: Equatable {
    public let name: String
    public let size: UInt64
    public let isDir: Bool
    public let modified: UInt64?
}

/// Left pane: this Mac's file system (기획서 §7.1). Same shape as RemoteBrowser.
@MainActor
public final class LocalBrowser {
    public enum State: Equatable {
        case loaded
        case failed(String)
    }

    public private(set) var path: String
    public private(set) var entries: [LocalEntry] = []
    public private(set) var state: State = .loaded
    /// Like Finder: dot-files hidden locally (the remote pane shows them).
    public var showsHidden = false {
        didSet { refresh() }
    }
    public var onChange: (() -> Void)?

    public init(path: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.path = path
    }

    public func open(_ newPath: String) {
        let url = URL(fileURLWithPath: (newPath as NSString).expandingTildeInPath).standardizedFileURL
        do {
            entries = try Self.list(url, showsHidden: showsHidden)
            path = url.path
            state = .loaded
        } catch {
            state = .failed("이 폴더를 열 수 없어요 (\(error.localizedDescription))")
        }
        onChange?()
    }

    public func refresh() { open(path) }
    public func goUp() { open((path as NSString).deletingLastPathComponent) }

    public func enter(_ entry: LocalEntry) {
        if entry.isDir { open((path as NSString).appendingPathComponent(entry.name)) }
    }

    public func fullPath(_ entry: LocalEntry) -> String {
        (path as NSString).appendingPathComponent(entry.name)
    }

    /// Folders first, then name (case-insensitive) — same order as the remote pane.
    public static func list(_ dir: URL, showsHidden: Bool = false) throws -> [LocalEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                               options: showsHidden ? [] : [.skipsHiddenFiles])
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LocalEntry(name: u.lastPathComponent,
                              size: UInt64(v?.fileSize ?? 0),
                              isDir: v?.isDirectory ?? false,
                              modified: v?.contentModificationDate.map { UInt64($0.timeIntervalSince1970) })
        }
        .sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
