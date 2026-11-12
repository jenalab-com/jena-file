import Foundation

/// 이름 / 상대 경로 / 절대 경로 복사 and rename checks, shared by both panes.
/// Paths are POSIX ("/"-separated) on both sides.
public enum PathText {
    public enum Kind {
        case name, relative, absolute
    }

    /// One line per path. Relative = from `home` (the Mac's home folder, or the
    /// server's login folder); a path outside `home` stays absolute.
    public static func text(_ paths: [String], _ kind: Kind, home: String) -> String {
        paths.map { p in
            switch kind {
            case .name: (p as NSString).lastPathComponent
            case .absolute: p
            case .relative: relative(p, to: home)
            }
        }.joined(separator: "\n")
    }

    public static func relative(_ path: String, to home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == base { return "." }
        if !base.isEmpty, path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return path
    }

    /// Why `name` can't replace `current` in a folder holding `siblings`; nil = fine.
    public static func renameProblem(_ name: String, current: String, siblings: [String]) -> String? {
        if name.isEmpty { return L("이름을 입력해 주세요") }
        if name.contains("/") || name == "." || name == ".." { return L("이름에 / 를 쓰거나 . / .. 로만 지을 수 없어요") }
        if name != current, siblings.contains(name) { return L("\"%@\"이(가) 이미 있어요", name) }
        return nil
    }
}
