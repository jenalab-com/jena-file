import JenaFileCore

/// Korean, user-facing text for core errors. Says which side failed (경유 서버 / 서버).
public enum UserMessage {
    public static func describe(_ error: Error) -> String {
        guard let e = error as? CoreError else { return error.localizedDescription }
        switch e {
        case .Connect(let hop, let message): return friendly(hop, message)
        case .Auth(let hop): return L("%@ 인증에 실패했어요. 사용자 이름과 비밀번호를 확인해 주세요.", "\(where_(hop))")
        case .HostKeyRejected(let hop): return L("%@의 호스트 키를 신뢰하지 않아 접속을 멈췄어요.", "\(where_(hop))")
        case .HostKeyChanged(let hop): return L("%@의 호스트 키가 바뀌어서 접속을 멈췄어요.", "\(where_(hop))")
        case .PasswordExpired(let hop): return L("%@ 계정의 비밀번호가 만료됐어요. 터미널에서 비밀번호를 바꾼 뒤 다시 접속해 주세요.", "\(where_(hop))")
        case .Server(let hop, let message, let detail):
            return L("%@ 오류: %@", "\(where_(hop))", "\(message)") + (detail.map { L("\n서버 메시지: %@", "\($0)") } ?? "")
        case .TunnelFailed(let host, let port, let message):
            return L("경유 서버까지는 연결됐지만 %@:%@에 닿지 못했어요 (%@)", "\(host)", "\(port)", "\(message)")
        case .Local(let message): return L("이 Mac에서 문제가 생겼어요: %@", "\(message)")
        case .Cancelled: return L("접속을 취소했어요.")
        case .NotConnected: return L("연결이 끊겨 있어요.")
        case .LimitReached(let max): return L("최대 %@개까지 연결할 수 있어요. 하나를 끊고 다시 시도해 주세요.", "\(max)")
        }
    }

    /// Common network failures in plain words; the raw text stays in brackets.
    static func friendly(_ hop: Hop, _ message: String) -> String {
        let m = message.lowercased()
        let w = where_(hop)
        if m.contains("connection lost") { return L("%@와의 연결이 끊겼어요.", "\(w)") }
        if m.contains("connection refused") {
            return L("%@가 연결을 거부했어요. 호스트와 포트가 맞는지, 서버가 켜져 있는지 확인해 주세요.", "\(w)")
        }
        if m.contains("lookup") || m.contains("nodename nor servname") || m.contains("name or service not known") {
            return L("%@ 주소를 찾을 수 없어요. 호스트 이름을 확인해 주세요.", "\(w)")
        }
        if m.contains("timed out") || m.contains("timeout") { return L("%@가 응답하지 않아요 (시간 초과).", "\(w)") }
        if m.contains("unreachable") || m.contains("no route to host") {
            return L("%@에 닿을 수 없어요. 네트워크(VPN 등) 연결을 확인해 주세요.", "\(w)")
        }
        return L("%@에 연결하지 못했어요 (%@)", "\(w)", "\(message)")
    }

    private static func where_(_ hop: Hop) -> String {
        switch hop {
        case .bastion: return L("경유 서버")
        case .target: return L("서버")
        }
    }
}
