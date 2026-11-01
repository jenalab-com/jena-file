import JenaFileCore

/// How to connect to a saved server, and which Keychain entries hold its passwords.
public struct ProfileRoute {
    public let target: Endpoint
    public let via: Via?
    public let title: String
    /// Shown for the bastion's terminal tab when one is opened for this server.
    public let bastionTitle: String?
    /// Keychain accounts (nil = not saved).
    public let targetAccount: String?
    public let bastionAccount: String?

    /// `all` resolves a bastion that is another saved server.
    public init?(_ p: Profile, all: [Profile]) {
        target = Endpoint(host: p.host, port: p.port, user: p.user)
        title = p.name.isEmpty ? p.host : p.name
        targetAccount = p.savePassword ? p.id : nil
        switch p.via {
        case nil:
            via = nil
            bastionTitle = nil
            bastionAccount = nil
        case .server(let id):
            guard let b = all.first(where: { $0.id == id }) else { return nil }
            via = .endpoint(endpoint: Endpoint(host: b.host, port: b.port, user: b.user))
            bastionTitle = b.name.isEmpty ? b.host : b.name
            bastionAccount = b.savePassword ? b.id : nil
        case .endpoint(let host, let port, let user):
            via = .endpoint(endpoint: Endpoint(host: host, port: port, user: user))
            bastionTitle = port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
            bastionAccount = p.savePassword ? p.id + "#bastion" : nil
        }
    }
}

public extension Profile {
    static func blank() -> Profile {
        Profile(id: "", name: "", group: "", host: "", port: 22, user: "", via: nil,
                remoteDir: nil, localDir: nil, savePassword: true)
    }

    /// `user@host[:port]`
    var address: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}
