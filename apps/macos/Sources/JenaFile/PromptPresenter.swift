import AppKit
import JenaFileCore
import JenaFileKit

/// Shows core prompts as window sheets, one at a time (ARCHITECTURE §5).
/// Sheets keep the run loop alive, so events keep flowing while the user decides.
@MainActor
final class PromptPresenter {
    private weak var window: NSWindow?
    private var queue: [(UInt64, Hop, PromptKind)] = []
    private var showing = false
    private let answer: (UInt64, PromptAnswer) -> Void
    /// Passwords we already have for this connect attempt (quick-connect field or
    /// Keychain), per hop. Used once for the first attempt, then forgotten.
    var known: [Hop: String] = [:]
    /// Passwords the user typed in a sheet during this attempt, per hop — the
    /// caller offers to save them once the connection works (FR-03a).
    private(set) var typed: [Hop: String] = [:]
    /// The password last sent per hop in this attempt (known or typed) — kept by the
    /// caller for the life of the connection so a reconnect does not ask again.
    private(set) var used: [Hop: String] = [:]
    /// Password of an open connection, for reconnects (memory only, never disk).
    var sessionSecret: ((UInt64) -> String?)?

    func beginAttempt(known: [Hop: String]) {
        self.known = known.filter { !$0.value.isEmpty }
        typed = [:]
        used = [:]
    }

    init(window: NSWindow, answer: @escaping (UInt64, PromptAnswer) -> Void) {
        self.window = window
        self.answer = answer
    }

    func present(prompt: UInt64, connection: UInt64, hop: Hop, kind: PromptKind) {
        if case .password(_, _, 1) = kind, let pw = known.removeValue(forKey: hop) ?? sessionSecret?(connection) {
            used[hop] = pw
            answer(prompt, .secret(value: pw))
            return
        }
        queue.append((prompt, hop, kind))
        showNext()
    }

    private func showNext() {
        guard !showing, let window, !queue.isEmpty else { return }
        showing = true
        let (prompt, hop, kind) = queue.removeFirst()
        let (alert, read) = makeAlert(kind, hop: hop)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.answer(prompt, read(response))
            self.showing = false
            self.showNext()
        }
    }

    private func makeAlert(_ kind: PromptKind, hop: Hop) -> (NSAlert, (NSApplication.ModalResponse) -> PromptAnswer) {
        let alert = NSAlert()
        let side = hop == .bastion ? "bastion " : ""
        switch kind {
        case .hostKeyUnknown(let host, let port, let key):
            alert.messageText = L("처음 접속하는 %@예요", "\(side.isEmpty ? L("서버") : "bastion")")
            alert.informativeText = L("%@의 호스트 키를 확인해 주세요.", "\(hostLabel(host, port))")
                + "\n\n\(key.algorithm)\n\(key.fingerprint)\n\n"
                + L("서버 관리자에게 받은 지문과 같다면 신뢰하고 접속하세요.")
            alert.addButton(withTitle: L("신뢰하고 접속"))
            alert.addButton(withTitle: L("취소"))
            return (alert, { $0 == .alertFirstButtonReturn ? .accept : .reject })

        case .hostKeyChanged(let host, let port, let key):
            alert.alertStyle = .critical
            alert.messageText = L("서버의 호스트 키가 바뀌었어요")
            alert.informativeText = L("%@의 호스트 키가 전에 기록한 것과 달라요.", "\(hostLabel(host, port))")
                + "\n" + L("서버를 다시 설치했을 수도 있지만, 누군가 중간에서 접속을 가로채고 있을 수도 있어요.")
                + "\n\n" + L("새 키: %@", "\(key.algorithm)") + "\n\(key.fingerprint)\n\n"
                + L("바뀐 이유를 확인하기 전에는 접속하지 마세요.")
            alert.addButton(withTitle: L("접속 취소"))          // default = safe choice
            alert.addButton(withTitle: L("새 키를 신뢰하고 접속"))
            return (alert, { $0 == .alertSecondButtonReturn ? .accept : .reject })

        case .password(let user, let host, let attempt):
            alert.messageText = attempt > 1 ? L("%@비밀번호가 맞지 않아요", "\(side)") : L("%@비밀번호를 입력해 주세요", "\(side)")
            alert.informativeText = "\(user)@\(host)" + (attempt > 1 ? L(" (%@번째 시도)", "\(attempt)") : "")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: L("접속"))
            alert.addButton(withTitle: L("취소"))
            return (alert, { [weak self] response in
                guard response == .alertFirstButtonReturn else { return .cancel }
                self?.typed[hop] = field.stringValue
                self?.used[hop] = field.stringValue
                return .secret(value: field.stringValue)
            })

        case .conflict(let direction, let destination, let sourceSize, let sourceModified,
                       let destinationSize, let destinationModified, let canResume):
            alert.messageText = L("같은 이름의 파일이 이미 있어요")
            let whereText = direction == .upload ? L("서버") : L("이 Mac")
            func line(_ label: String, _ size: UInt64, _ modified: UInt64?) -> String {
                "\(label): \(Format.size(size, isDir: false))" + (modified.map { " · \(Format.date($0))" } ?? "")
            }
            var info = L("%@의 %@\n\n", "\(whereText)", "\(destination)")
            info += line(L("보낼 파일"), sourceSize, sourceModified) + "\n"
            info += line(L("이미 있는 파일"), destinationSize, destinationModified)
            if canResume { info += L("\n\n이미 있는 파일이 더 작아요. 받다 만 파일이면 이어받기를 고르세요.") }
            alert.informativeText = info
            var actions: [ConflictAction] = [.overwrite]
            alert.addButton(withTitle: L("덮어쓰기"))
            if canResume {
                alert.addButton(withTitle: L("이어받기"))
                actions.append(.resume)
            }
            alert.addButton(withTitle: L("이름 바꿔 저장"))
            actions.append(.rename)
            alert.addButton(withTitle: L("건너뛰기"))
            actions.append(.skip)
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("나머지 파일에도 같은 선택 적용")
            return (alert, { response in
                let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard i >= 0, i < actions.count else { return .cancel }
                return .conflict(action: actions[i], applyToAll: alert.suppressionButton?.state == .on)
            })

        case .keyboardInteractive(let name, let instructions, let prompts):
            alert.messageText = name.isEmpty ? L("서버가 추가 인증을 요청해요") : name
            alert.informativeText = instructions
            let fields: [NSTextField] = prompts.map { p in
                let f: NSTextField = p.echo ? NSTextField() : NSSecureTextField()
                f.placeholderString = p.text.trimmingCharacters(in: .whitespaces)
                f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                return f
            }
            let stack = NSStackView(views: prompts.enumerated().flatMap { i, p in
                [NSTextField(labelWithString: p.text), fields[i]] as [NSView]
            })
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(prompts.count) * 48)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = fields.first
            alert.addButton(withTitle: L("확인"))
            alert.addButton(withTitle: L("취소"))
            return (alert, { $0 == .alertFirstButtonReturn ? .responses(values: fields.map(\.stringValue)) : .cancel })
        }
    }

    private func hostLabel(_ host: String, _ port: UInt16) -> String {
        port == 22 ? host : "\(host):\(port)"
    }
}
