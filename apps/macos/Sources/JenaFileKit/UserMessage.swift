import JenaFileCore

/// Korean, user-facing text for core errors. Says which side failed (bastion / server).
public enum UserMessage {
    public static func describe(_ error: Error) -> String {
        guard let e = error as? CoreError else { return error.localizedDescription }
        switch e {
        case .Connect(let hop, let message): return "\(where_(hop))에 연결하지 못했어요 (\(message))"
        case .Auth(let hop): return "\(where_(hop)) 인증에 실패했어요. 사용자 이름과 비밀번호를 확인해 주세요."
        case .HostKeyRejected(let hop): return "\(where_(hop))의 호스트 키를 신뢰하지 않아 접속을 멈췄어요."
        case .HostKeyChanged(let hop): return "\(where_(hop))의 호스트 키가 바뀌어서 접속을 멈췄어요."
        case .PasswordExpired(let hop): return "\(where_(hop)) 계정의 비밀번호가 만료됐어요. 터미널에서 비밀번호를 바꾼 뒤 다시 접속해 주세요."
        case .Server(let hop, let message, let detail):
            return "\(where_(hop)) 오류: \(message)" + (detail.map { "\n서버 메시지: \($0)" } ?? "")
        case .Cancelled: return "접속을 취소했어요."
        case .NotConnected: return "연결이 끊겨 있어요."
        case .LimitReached(let max): return "최대 \(max)개까지 연결할 수 있어요. 하나를 끊고 다시 시도해 주세요."
        }
    }

    private static func where_(_ hop: Hop) -> String {
        switch hop {
        case .bastion: return "bastion"
        case .target: return "서버"
        }
    }
}
