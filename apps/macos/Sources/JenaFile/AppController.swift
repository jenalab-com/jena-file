import AppKit
import JenaFileCore
import JenaFileKit

/// Owns the core and connects it to the window. M1: one direct SFTP connection.
@MainActor
final class AppController: CoreEventHandler {
    let window: NSWindow
    private let core: Core
    private let bridge: CoreBridge
    private let quickConnect = QuickConnectBar()
    private let log = LogPane()
    private let status = NSTextField(labelWithString: "")
    private let remote: RemoteBrowser
    private let terminals: TerminalPane
    private var prompts: PromptPresenter!
    private var connection: UInt64?
    private var target: QuickConnectInput?
    private var busy = false

    init() throws {
        bridge = CoreBridge()
        core = Core(dataDir: try AppPaths.dataDirectory().path, userKnownHosts: AppPaths.userKnownHosts, listener: bridge)
        remote = RemoteBrowser(core: core)
        terminals = TerminalPane(core: core)
        let remotePane = RemotePane(browser: remote)
        window = MainWindow.make(MainWindowParts(
            quickConnect: quickConnect, log: log, remote: remotePane, terminal: terminals, status: status))
        remotePane.onOpenTerminal = { [terminals] dir in terminals.open(startDir: dir) }
        remotePane.onInsertPaths = { [terminals] paths in
            terminals.insert(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        }
        prompts = PromptPresenter(window: window) { [core] id, answer in _ = core.respond(prompt: id, answer: answer) }
        bridge.handler = self
        quickConnect.onSubmit = { [weak self] in self?.connectOrDisconnect() }
        updateStatus()
        log.append("jena-file core \(CoreInfo.version)")
    }

    /// Dev convenience: JENAFILE_DEV_CONNECT=user@host:port (+ JENAFILE_DEV_PASSWORD) fills and submits the bar.
    func applyDevAutoConnect() {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["JENAFILE_DEV_CONNECT"] else { return }
        quickConnect.host.stringValue = target
        quickConnect.password.stringValue = env["JENAFILE_DEV_PASSWORD"] ?? ""
        connectOrDisconnect()
    }

    private func connectOrDisconnect() {
        if let id = connection {
            busy = true
            refreshBar()
            Task {
                await core.disconnect(connection: id)
            }
            return
        }
        guard let input = QuickConnectInput.parse(host: quickConnect.host.stringValue,
                                                   user: quickConnect.user.stringValue,
                                                   port: quickConnect.port.stringValue) else {
            log.append("호스트와 사용자 이름을 입력해 주세요 (예: jena@example.com:22)", tone: .warn)
            return
        }
        target = input
        prompts.pendingPassword = quickConnect.password.stringValue
        quickConnect.password.stringValue = ""   // don't keep secrets in the UI
        busy = true
        refreshBar()
        Task {
            do {
                let id = try await core.connect(endpoint: input.endpoint)
                connection = id
                busy = false
                refreshBar()
                terminals.connected(id, title: input.display)   // AC-1: list + shell from one login
                await remote.attach(id)
            } catch {
                busy = false
                prompts.pendingPassword = nil
                refreshBar()
                log.append(UserMessage.describe(error), tone: .error)
            }
        }
    }

    // MARK: core events

    func handle(_ event: CoreEvent) {
        switch event {
        case .log(_, _, let level, let message):
            // The core logs in English for diagnostics; the UI writes its own Korean
            // lines from state changes and errors, so only surface core warnings here.
            if level == .warn { log.append(message, tone: .warn) }
        case .promptRequested(let prompt, _, _, let kind):
            prompts.present(prompt: prompt, kind: kind)
        case .stateChanged(let id, let state):
            switch state {
            case .connecting(let step):
                if step == .dialing { log.append("\(target?.display ?? "") 연결 중…") }
                status.stringValue = "\(target?.display ?? "") 연결 중… (\(stepText(step)))"
            case .ready:
                log.append("연결됐어요 · SFTP 준비 완료")
                updateStatus()
            case .failed, .closed:
                if case .closed = state, connection == id { log.append("연결을 끊었어요") }
                if case .failed(let error) = state, connection == id { log.append(UserMessage.describe(error), tone: .error) }
                if connection == id {
                    connection = nil
                    busy = false
                    remote.detach()
                    terminals.disconnected()
                    refreshBar()
                }
                updateStatus()
            }
        }
    }

    private func stepText(_ step: ConnectStep) -> String {
        switch step {
        case .dialing: "접속"
        case .auth: "인증"
        case .sftp: "SFTP 시작"
        }
    }

    private func refreshBar() {
        quickConnect.setConnected(connection != nil, busy: busy)
        updateStatus()
    }

    private func updateStatus() {
        let state = connection != nil ? "연결됨: \(target?.display ?? "")" : "연결 안 됨"
        status.stringValue = "core \(CoreInfo.version) · \(state)"
    }
}
