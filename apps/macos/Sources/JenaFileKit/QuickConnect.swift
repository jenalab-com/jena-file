import JenaFileCore

/// What the user typed into the quick-connect bar.
public struct QuickConnectInput: Equatable {
    public var host: String
    public var user: String
    public var port: UInt16

    /// Accepts `host`, `user@host`, `host:port`, `user@host:port`, `sftp://user@host:port`.
    /// Values written in the host field win over the separate user/port fields.
    public static func parse(host raw: String, user: String, port: String) -> QuickConnectInput? {
        var rest = raw.trimmingCharacters(in: .whitespaces)
        if let r = rest.range(of: "://") { rest = String(rest[r.upperBound...]) }
        if rest.hasSuffix("/") { rest.removeLast() }
        var u = user.trimmingCharacters(in: .whitespaces)
        if let at = rest.lastIndex(of: "@") {
            u = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var p = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 22
        if let colon = rest.lastIndex(of: ":"), !rest.hasPrefix("[") {
            guard let parsed = UInt16(rest[rest.index(after: colon)...]) else { return nil }
            p = parsed
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, !u.isEmpty, p > 0 else { return nil }
        return QuickConnectInput(host: rest, user: u, port: p)
    }

    public var endpoint: Endpoint { Endpoint(host: host, port: port, user: user) }

    /// `user@host[:port]` as typed in the bar's host field.
    public var field: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
    public var display: String { field }
}

/// What to put in the quick-connect bar for a pasted `ssh` command (FR-09).
public struct QuickConnectFill: Equatable {
    public var host: String
    public var user: String
    public var port: String
    /// `user@host[:port]` of the bastion, if the command went through one.
    public var bastion: String?
    /// Human-readable summary for the status log.
    public var note: String

    public init?(_ parsed: ParsedSsh) {
        guard let t = parsed.target else { return nil }
        host = t.host
        user = t.user ?? ""
        port = t.port == 22 ? "" : String(t.port)
        bastion = parsed.bastion.map { b in
            let h = b.port == 22 ? b.host : "\(b.host):\(b.port)"
            return b.user.map { "\($0)@\(h)" } ?? h
        }
        var parts: [String] = []
        if let bastion { parts.append(L("%@ 경유", "\(bastion)")) }
        parts.append(L("서버 %@:%@", "\(t.host)", "\(t.port)"))
        if let p = parsed.droppedLocalPort { parts.append(L("로컬 포트 %@는 이제 필요 없어요", "\(p)")) }
        if t.user == nil { parts.append(L("서버 사용자 이름을 입력해 주세요")) }
        note = L("명령을 해석했어요: ") + parts.joined(separator: " · ")
    }

    public init(host: String, user: String, port: String, bastion: String?, note: String) {
        self.host = host; self.user = user; self.port = port; self.bastion = bastion; self.note = note
    }
}
