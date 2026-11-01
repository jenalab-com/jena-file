import AppKit
import JenaFileCore
import JenaFileKit

/// Owns the core and connects it to the window.
/// M3: one active target, optionally behind a bastion (opened for it, or an
/// open connection reused via "내부 서버 열기").
@MainActor
final class AppController: CoreEventHandler {
    let window: NSWindow
    private let core: Core
    private let bridge: CoreBridge
    private let quickConnect = QuickConnectBar()
    private let log = LogPane()
    private let status = NSTextField(labelWithString: "")
    private let remote: RemoteBrowser
    private let local = LocalBrowser()
    private let transferList = TransferList()
    private let terminals: TerminalPane
    /// Keeps the Mac awake while transfers run (기획서 §9 안정성).
    private var awake: NSObjectProtocol?
    private var prompts: PromptPresenter!
    /// Every connection opened from this window, with a display title.
    private var open: [UInt64: String] = [:]
    /// The connection shown in the remote pane.
    private var active: UInt64?
    private var busy = false

    init() throws {
        bridge = CoreBridge()
        core = Core(dataDir: try AppPaths.dataDirectory().path, userKnownHosts: AppPaths.userKnownHosts, listener: bridge)
        remote = RemoteBrowser(core: core)
        terminals = TerminalPane(core: core)
        let remotePane = RemotePane(browser: remote)
        let localPane = LocalPane(browser: local)
        window = MainWindow.make(MainWindowParts(
            quickConnect: quickConnect, log: log, transfers: TransferPane(list: transferList, core: core),
            local: localPane, remote: remotePane, terminal: terminals, status: status))
        localPane.onUpload = { [weak self] paths in self?.upload(paths) }
        remotePane.onUploadHere = { [weak self] paths in self?.upload(paths) }
        remotePane.onDownload = { [weak self] paths in self?.download(paths) }
        localPane.onDownloadHere = { [weak self] paths in self?.download(paths) }
        transferList.onFinished = { [weak self] t in self?.transferFinished(t) }
        prompts = PromptPresenter(window: window) { [core] id, answer in _ = core.respond(prompt: id, answer: answer) }
        bridge.handler = self
        quickConnect.onSubmit = { [weak self] in self?.submit() }
        terminals.onOpenInternal = { [weak self] via in self?.askInternalServer(via: via) }
        remotePane.onOpenTerminal = { [terminals] dir in terminals.open(startDir: dir) }
        remotePane.onInsertPaths = { [terminals] paths in
            terminals.insert(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        }
        refresh()
        log.append("jena-file core \(CoreInfo.version)")
    }

    /// Dev convenience: JENAFILE_DEV_CONNECT=user@host:port, JENAFILE_DEV_PASSWORD,
    /// JENAFILE_DEV_VIA=user@bastion:port, JENAFILE_DEV_VIA_PASSWORD.
    func applyDevAutoConnect() {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["JENAFILE_DEV_CONNECT"] else { return }
        quickConnect.host.stringValue = target
        quickConnect.password.stringValue = env["JENAFILE_DEV_PASSWORD"] ?? ""
        prompts.pendingBastionPassword = env["JENAFILE_DEV_VIA_PASSWORD"]
        if let via = env["JENAFILE_DEV_VIA"] {
            quickConnect.apply(QuickConnectFill(host: target, user: "", port: "", bastion: via, note: ""))
            quickConnect.host.stringValue = target
        }
        submit()
    }

    // MARK: quick connect

    private func submit() {
        if !open.isEmpty { disconnectAll(); return }

        let typed = quickConnect.host.stringValue.trimmingCharacters(in: .whitespaces)
        if typed.hasPrefix("ssh ") {
            guard let parsed = parseSshCommand(text: typed), let fill = QuickConnectFill(parsed) else {
                log.append("ssh 명령을 이해하지 못했어요. 예: ssh -L 2222:10.0.0.5:22 user@bastion", tone: .warn)
                return
            }
            quickConnect.apply(fill)
            log.append(fill.note)
            if fill.user.isEmpty { return }   // let the user add the server login first
        }

        guard let target = QuickConnectInput.parse(host: quickConnect.host.stringValue,
                                                    user: quickConnect.user.stringValue,
                                                    port: quickConnect.port.stringValue) else {
            log.append("호스트와 사용자 이름을 입력해 주세요 (예: jena@example.com:22)", tone: .warn)
            return
        }
        var via: Via?
        var bastionTitle: String?
        if let text = quickConnect.bastionText {
            guard let b = QuickConnectInput.parse(host: text, user: "", port: "") else {
                log.append("bastion을 user@host:port 형식으로 입력해 주세요", tone: .warn)
                return
            }
            via = .endpoint(endpoint: b.endpoint)
            bastionTitle = b.display
        }
        prompts.pendingPassword = quickConnect.password.stringValue
        quickConnect.password.stringValue = ""   // don't keep secrets in the UI
        terminals.reset()
        connect(target, via: via, bastionTitle: bastionTitle)
    }

    private func connect(_ target: QuickConnectInput, via: Via?, bastionTitle: String?, withSftp: Bool = true) {
        busy = true
        refresh()
        let title = target.display + (bastionTitle != nil || viaConnection(via) != nil ? " ⇢bastion" : "")
        let route = bastionTitle.map { " (bastion \($0) 경유)" } ?? viaConnection(via).flatMap { open[$0] }.map { " (\($0) 경유)" } ?? ""
        log.append("\(target.display)\(route) 연결 중…")
        Task {
            do {
                let c = try await core.connect(endpoint: target.endpoint, via: via, withSftp: withSftp)
                if let b = c.bastion, let bastionTitle {
                    open[b] = bastionTitle
                    terminals.connected(b, title: "bastion \(bastionTitle)", makeActive: false)
                }
                open[c.id] = title
                active = c.id
                busy = false
                terminals.connected(c.id, title: title)       // AC-1/2: list + shell from one login
                log.append("연결됐어요 · \(title)")
                refresh()
                if withSftp {
                    await remote.attach(c.id)
                    // Dev only: JENAFILE_DEV_UPLOAD=/path/a:/path/b queues uploads after connecting.
                    if let dev = ProcessInfo.processInfo.environment["JENAFILE_DEV_UPLOAD"] {
                        upload(dev.split(separator: ":").map(String.init))
                    }
                } else {
                    remote.detach()
                    log.append("터미널에서 새 비밀번호로 바꾼 뒤, 끊고 다시 접속해 주세요.")
                }
            } catch let e as CoreError {
                busy = false
                prompts.pendingPassword = nil
                refresh()
                log.append(UserMessage.describe(e), tone: .error)
                if case .PasswordExpired = e { offerPasswordChange(target, via: via, bastionTitle: bastionTitle) }
            } catch {
                busy = false
                refresh()
                log.append(error.localizedDescription, tone: .error)
            }
        }
    }

    private func viaConnection(_ via: Via?) -> UInt64? {
        if case .connection(let id) = via { return id }
        return nil
    }

    private func disconnectAll() {
        busy = true
        refresh()
        let ids = Array(open.keys)
        Task {
            for id in ids { await core.disconnect(connection: id) }
        }
    }

    // MARK: transfers (M4)

    /// Local files / folders → the folder shown in the remote pane.
    private func upload(_ localPaths: [String]) {
        guard let id = active, remote.connection == id, !remote.path.isEmpty else {
            log.append("업로드하려면 먼저 서버에 접속해 주세요", tone: .warn)
            return
        }
        let target = remote.path
        Task {
            do {
                let ids = try await core.upload(connection: id, localPaths: localPaths, remoteDir: target)
                log.append("업로드 \(ids.count)개를 대기열에 넣었어요 → \(target)")
                await remote.refresh()   // folders are created up front
            } catch {
                log.append(UserMessage.describe(error), tone: .error)
            }
        }
    }

    /// Remote files / folders → the folder shown in the local pane.
    private func download(_ remotePaths: [String]) {
        guard let id = active else { return }
        let target = local.path
        Task {
            do {
                let ids = try await core.download(connection: id, remotePaths: remotePaths, localDir: target)
                log.append("다운로드 \(ids.count)개를 대기열에 넣었어요 → \(target)")
                local.refresh()
            } catch {
                log.append(UserMessage.describe(error), tone: .error)
            }
        }
    }

    private var refreshPending = (remote: false, local: false)

    /// Show finished files in whichever pane displays their folder (coalesced).
    private func transferFinished(_ t: TransferInfo) {
        if t.direction == .upload, RemotePath.parent(t.remotePath) == remote.path, !refreshPending.remote {
            refreshPending.remote = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.refreshPending.remote = false
                Task { await self.remote.refresh() }
            }
        }
        if t.direction == .download, (t.localPath as NSString).deletingLastPathComponent == local.path, !refreshPending.local {
            refreshPending.local = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshPending.local = false
                self?.local.refresh()
            }
        }
    }

    private func updateAwake() {
        if transferList.hasActive, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "jena-file 파일 전송 중")
        } else if !transferList.hasActive, let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    // MARK: FR-21 — open a server behind an open connection

    private func askInternalServer(via: UInt64) {
        let alert = NSAlert()
        alert.messageText = "내부 서버 열기"
        alert.informativeText = "\(open[via] ?? "이 서버")를 거쳐 접속해요. bastion 비밀번호는 다시 묻지 않아요."
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        let host = NSTextField(string: "")
        host.placeholderString = "user@내부서버:22"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "비밀번호 (비워 두면 접속할 때 물어요)"
        for f in [host, password] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 280).isActive = true
            fields.addArrangedSubview(f)
        }
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = host
        alert.addButton(withTitle: "접속")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let target = QuickConnectInput.parse(host: host.stringValue, user: "", port: "") else {
                self.log.append("내부 서버를 user@host:port 형식으로 입력해 주세요", tone: .warn)
                return
            }
            self.prompts.pendingPassword = password.stringValue
            self.connect(target, via: .connection(id: via), bastionTitle: nil)
        }
    }

    // MARK: FR-03b — expired password

    private func offerPasswordChange(_ target: QuickConnectInput, via: Via?, bastionTitle: String?) {
        let alert = NSAlert()
        alert.messageText = "비밀번호가 만료됐어요"
        alert.informativeText = "\(target.display) 계정의 비밀번호를 바꿔야 접속할 수 있어요.\n터미널을 열어 드릴게요. 서버가 현재 비밀번호와 새 비밀번호를 물어요."
        alert.addButton(withTitle: "터미널에서 변경")
        alert.addButton(withTitle: "닫기")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // Same route as before; passwords are asked again (we never keep them).
            self.terminals.reset()
            self.connect(target, via: via, bastionTitle: bastionTitle, withSftp: false)
        }
    }

    // MARK: core events

    func handle(_ event: CoreEvent) {
        switch event {
        case .log(_, _, let level, let message):
            // The core logs in English for diagnostics; the UI writes its own Korean
            // lines from state changes and errors, so only surface core warnings here.
            if level == .warn { log.append(message, tone: .warn) }
        case .promptRequested(let prompt, _, let hop, let kind):
            prompts.present(prompt: prompt, hop: hop, kind: kind)
        case .transfer(let info):
            transferList.update(info)
            updateAwake()
            if case .failed(let m) = info.state {
                log.append("전송 실패: \((info.remotePath as NSString).lastPathComponent) — \(m)", tone: .error)
            }
        case .stateChanged(let id, let state):
            switch state {
            case .connecting(let step):
                status.stringValue = "연결 중… (\(stepText(step)))"
            case .ready:
                break   // logged by connect() with a readable title
            case .failed(let error):
                if open[id] != nil { log.append(UserMessage.describe(error), tone: .error) }
                closed(id)
            case .closed:
                if let title = open[id] { log.append("연결을 끊었어요 · \(title)") }
                closed(id)
            }
        }
    }

    private func closed(_ id: UInt64) {
        guard open.removeValue(forKey: id) != nil else { return }
        terminals.disconnected(id)
        if active == id {
            active = nil
            remote.detach()
        }
        if open.isEmpty { busy = false }
        refresh()
    }

    private func stepText(_ step: ConnectStep) -> String {
        switch step {
        case .dialing: "접속"
        case .auth: "인증"
        case .sftp: "SFTP 시작"
        }
    }

    private func refresh() {
        quickConnect.setConnected(!open.isEmpty, busy: busy)
        let state = active.flatMap { open[$0] }.map { "연결됨: \($0)" } ?? (open.isEmpty ? "연결 안 됨" : "연결됨")
        status.stringValue = "core \(CoreInfo.version) · \(state)"
    }
}
