import Foundation
import JenaFileCore

/// 서버 관리 tree: groups (folders) of servers, then servers without a group at the
/// root. A group exists while a server is in it or the user made it — empty ones are
/// kept in `AppSettings.serverGroups`, the rest come from each profile's `group`.
public struct ServerTree {
    public struct Group {
        public let name: String
        public let servers: [Profile]
    }

    public let groups: [Group]
    public let root: [Profile]

    public init(profiles: [Profile], groupNames: [String]) {
        var names: [String] = []
        for n in groupNames + profiles.map(\.group) where !n.isEmpty && !names.contains(n) { names.append(n) }
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        groups = names.map { n in Group(name: n, servers: profiles.filter { $0.group == n }) }
        root = profiles.filter { $0.group.isEmpty }
    }

    /// Why `name` can't be used for a new or renamed group; nil when it can.
    /// `renaming` is the group's current name (renaming to itself is fine).
    public func problem(withGroupName name: String, renaming: String? = nil) -> String? {
        if name.isEmpty { return L("그룹 이름을 입력해 주세요") }
        if groups.contains(where: { $0.name != renaming && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return L("\"%@\" 그룹이 이미 있어요", name)
        }
        return nil
    }
}
