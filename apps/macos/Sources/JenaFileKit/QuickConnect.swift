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
    public var display: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}
