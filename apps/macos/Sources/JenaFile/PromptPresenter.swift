import AppKit
import JenaFileCore

/// Shows core prompts as window sheets, one at a time (ARCHITECTURE §5).
/// Sheets keep the run loop alive, so events keep flowing while the user decides.
@MainActor
final class PromptPresenter {
    private weak var window: NSWindow?
    private var queue: [(UInt64, PromptKind)] = []
    private var showing = false
    private let answer: (UInt64, PromptAnswer) -> Void
    /// Quick-connect password, used once for the first attempt then forgotten.
    var pendingPassword: String?

    init(window: NSWindow, answer: @escaping (UInt64, PromptAnswer) -> Void) {
        self.window = window
        self.answer = answer
    }

    func present(prompt: UInt64, kind: PromptKind) {
        if case .password(_, _, let attempt) = kind, attempt == 1, let pw = pendingPassword, !pw.isEmpty {
            pendingPassword = nil
            answer(prompt, .secret(value: pw))
            return
        }
        queue.append((prompt, kind))
        showNext()
    }

    private func showNext() {
        guard !showing, let window, !queue.isEmpty else { return }
        showing = true
        let (prompt, kind) = queue.removeFirst()
        let (alert, read) = makeAlert(kind)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.answer(prompt, read(response))
            self.showing = false
            self.showNext()
        }
    }

    private func makeAlert(_ kind: PromptKind) -> (NSAlert, (NSApplication.ModalResponse) -> PromptAnswer) {
        let alert = NSAlert()
        switch kind {
        case .hostKeyUnknown(let host, let port, let key):
            alert.messageText = "처음 접속하는 서버예요"
            alert.informativeText = """
            \(hostLabel(host, port))의 호스트 키를 확인해 주세요.

            \(key.algorithm)
            \(key.fingerprint)

            서버 관리자에게 받은 지문과 같다면 신뢰하고 접속하세요.
            """
            alert.addButton(withTitle: "신뢰하고 접속")
            alert.addButton(withTitle: "취소")
            return (alert, { $0 == .alertFirstButtonReturn ? .accept : .reject })

        case .hostKeyChanged(let host, let port, let key):
            alert.alertStyle = .critical
            alert.messageText = "서버의 호스트 키가 바뀌었어요"
            alert.informativeText = """
            \(hostLabel(host, port))의 호스트 키가 전에 기록한 것과 달라요.
            서버를 다시 설치했을 수도 있지만, 누군가 중간에서 접속을 가로채고 있을 수도 있어요.

            새 키: \(key.algorithm)
            \(key.fingerprint)

            바뀐 이유를 확인하기 전에는 접속하지 마세요.
            """
            alert.addButton(withTitle: "접속 취소")          // default = safe choice
            alert.addButton(withTitle: "새 키를 신뢰하고 접속")
            return (alert, { $0 == .alertSecondButtonReturn ? .accept : .reject })

        case .password(let user, let host, let attempt):
            alert.messageText = attempt > 1 ? "비밀번호가 맞지 않아요" : "비밀번호를 입력해 주세요"
            alert.informativeText = "\(user)@\(host)" + (attempt > 1 ? " (\(attempt)번째 시도)" : "")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "접속")
            alert.addButton(withTitle: "취소")
            return (alert, { $0 == .alertFirstButtonReturn ? .secret(value: field.stringValue) : .cancel })

        case .keyboardInteractive(let name, let instructions, let prompts):
            alert.messageText = name.isEmpty ? "서버가 추가 인증을 요청해요" : name
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
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "취소")
            return (alert, { $0 == .alertFirstButtonReturn ? .responses(values: fields.map(\.stringValue)) : .cancel })
        }
    }

    private func hostLabel(_ host: String, _ port: UInt16) -> String {
        port == 22 ? host : "\(host):\(port)"
    }
}
