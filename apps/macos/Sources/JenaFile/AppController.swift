import AppKit
import JenaFileCore
import JenaFileKit

/// Owns the core and connects it to the window, menus and toolbar.
/// One active target at a time, optionally behind a bastion (opened for it, or an
/// open connection reused via "내부 서버 열기"); saved servers come from 서버 관리.
@MainActor
final class AppController: NSObject, CoreEventHandler, NSToolbarDelegate, NSMenuItemValidation {
    let window: NSWindow
    private let core: Core
    private let bridge: CoreBridge
    private let settings = AppSettings()
    private let keychain = KeychainStore()
    private let quickConnect = QuickConnectBar()
    private let log = LogPane()
    private let status = NSTextField(labelWithString: "")
    private let remote: RemoteBrowser
    private let local: LocalBrowser
    private let transferList = TransferList()
    private let terminals: TerminalPane
    private var layout: MainLayout? { (window as? MainNSWindow)?.layout }
    /// Keeps the Mac awake while transfers run (기획서 §9 안정성).
    private var awake: NSObjectProtocol?
    private var prompts: PromptPresenter!
    private var serverManager: ServerManagerWindow?
    private var settingsWindow: SettingsWindow?
    private var helpWindow: HelpWindow?
    /// Every connection opened from this window, with a display title.
    private var open: [UInt64: String] = [:]
    /// The connection shown in the remote pane.
    private var active: UInt64?
    private var busy = false
    /// Passwords of open connections, so a reconnect does not ask again.
    /// Memory only, dropped when the connection ends (ARCHITECTURE §6).
    private var secrets: [UInt64: String] = [:]
    /// Route key per open connection (FR-16: unfinished transfers find their server again).
    private var keys: [UInt64: String] = [:]
    private var reconnecting: Set<UInt64> = []
    private let pendingStore: PendingStore
    /// Unfinished transfers from the last run, not yet resumed or dropped.
    private var restored: [PendingTransfer] = []
    private var savePendingScheduled = false

    /// Where the passwords of the current attempt come from / go to (FR-03a).
    private struct Attempt {
        var profile: Profile?
        var targetAccount: String?
        var bastionAccount: String?
    }
    private var attempt = Attempt()

    init(dataDir: String) {
        bridge = CoreBridge()
        core = Core(dataDir: dataDir, userKnownHosts: AppPaths.userKnownHosts, listener: bridge)
        pendingStore = PendingStore(dataDir: URL(fileURLWithPath: dataDir))
        remote = RemoteBrowser(core: core)
        local = LocalBrowser(path: settings.localFolder ?? FileManager.default.homeDirectoryForCurrentUser.path)
        terminals = TerminalPane(core: core)
        let remotePane = RemotePane(browser: remote)
        let localPane = LocalPane(browser: local)
        window = MainWindow.make(MainWindowParts(
            quickConnect: quickConnect, log: log, transfers: TransferPane(list: transferList, core: core),
            local: localPane, remote: remotePane, terminal: terminals, status: status))
        super.init()
        localPane.onUpload = { [weak self] paths in self?.upload(paths) }
        remotePane.onUploadHere = { [weak self] paths in self?.upload(paths) }
        remotePane.onDownload = { [weak self] paths in self?.download(paths) }
        localPane.onDownloadHere = { [weak self] paths in self?.download(paths) }
        transferList.onFinished = { [weak self] t in self?.transferFinished(t) }
        prompts = PromptPresenter(window: window) { [core] id, answer in _ = core.respond(prompt: id, answer: answer) }
        prompts.sessionSecret = { [weak self] id in self?.secrets[id] }
        bridge.handler = self
        quickConnect.onSubmit = { [weak self] in self?.submit() }
        terminals.onOpenInternal = { [weak self] via in self?.askInternalServer(via: via) }
        remotePane.onOpenTerminal = { [terminals] dir in terminals.open(startDir: dir) }
        remotePane.onInsertPaths = { [terminals] paths in
            terminals.insert(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        }
        installToolbar()
        applySettings()
        for pane in [Pane.log, .transfers, .terminal] where !isOn(pane) { layout?.setVisible(pane, false) }
        log.errorsOnly = settings.logErrorsOnly
        refresh()
        log.append("jena-file core \(CoreInfo.version)")
        restored = pendingStore.load()
        if !restored.isEmpty {
            log.append(L("끝나지 않은 전송 %@개가 남아 있어요. 같은 서버에 접속하면 이어서 할지 물어볼게요.", "\(restored.count)"))
        }
    }

    /// Dev convenience: JENAFILE_DEV_CONNECT=user@host:port, JENAFILE_DEV_PASSWORD,
    /// JENAFILE_DEV_VIA=user@bastion:port, JENAFILE_DEV_VIA_PASSWORD, JENAFILE_DEV_UPLOAD=/a:/b.
    func applyDevAutoConnect() {
        let env = ProcessInfo.processInfo.environment
        // JENAFILE_DEV_SHOW=servers|settings|help opens that window (screenshots without clicking).
        switch env["JENAFILE_DEV_SHOW"] {
        case "servers": showServerManager(nil)
        case "settings": showSettings(nil)
        case "help": openHelp(nil)
        default: break
        }
        // JENAFILE_DEV_PROFILE=<saved server id> connects it like a double-click.
        if let id = env["JENAFILE_DEV_PROFILE"], let p = (try? core.listProfiles())?.first(where: { $0.id == id }) {
            // Passwords from env instead of the Keychain (no Keychain prompts while testing).
            var dev: [Hop: String] = [:]
            dev[.target] = env["JENAFILE_DEV_PASSWORD"]
            dev[.bastion] = env["JENAFILE_DEV_VIA_PASSWORD"]
            connect(profile: p, override: dev)
            return
        }
        guard let target = env["JENAFILE_DEV_CONNECT"] else { return }
        quickConnect.host.stringValue = target
        quickConnect.password.stringValue = env["JENAFILE_DEV_PASSWORD"] ?? ""
        if let via = env["JENAFILE_DEV_VIA"] {
            quickConnect.apply(QuickConnectFill(host: target, user: "", port: "", bastion: via, note: ""))
            quickConnect.host.stringValue = target
        }
        submit(devBastionPassword: env["JENAFILE_DEV_VIA_PASSWORD"])
    }

    // MARK: settings

    private func applySettings() {
        core.setTransferLimit(limit: UInt32(settings.transferLimit))
        if local.showsHidden != settings.showLocalHidden { local.showsHidden = settings.showLocalHidden }
    }

    // MARK: quick connect

    private func submit(devBastionPassword: String? = nil) {
        if !open.isEmpty { disconnectAll(nil); return }

        let typed = quickConnect.host.stringValue.trimmingCharacters(in: .whitespaces)
        if typed.hasPrefix("ssh ") {
            guard let parsed = parseSshCommand(text: typed), let fill = QuickConnectFill(parsed) else {
                log.append(L("ssh 명령을 이해하지 못했어요. 예: ssh -L 2222:10.0.0.5:22 user@bastion"), tone: .warn)
                return
            }
            quickConnect.apply(fill)
            log.append(fill.note)
            if fill.user.isEmpty { return }   // let the user add the server login first
        }

        guard let target = QuickConnectInput.parse(host: quickConnect.host.stringValue,
                                                    user: quickConnect.user.stringValue,
                                                    port: quickConnect.port.stringValue) else {
            log.append(L("호스트와 사용자 이름을 입력해 주세요 (예: jena@example.com:22)"), tone: .warn)
            return
        }
        var via: Via?
        var bastionTitle: String?
        if let text = quickConnect.bastionText {
            guard let b = QuickConnectInput.parse(host: text, user: "", port: "") else {
                log.append(L("경유 서버를 user@host:port 형식으로 입력해 주세요"), tone: .warn)
                return
            }
            via = .endpoint(endpoint: b.endpoint)
            bastionTitle = b.display
        }
        attempt = Attempt()
        var known: [Hop: String] = [.target: quickConnect.password.stringValue]
        if let devBastionPassword { known[.bastion] = devBastionPassword }
        prompts.beginAttempt(known: known)
        quickConnect.password.stringValue = ""   // don't keep secrets in the UI
        terminals.reset()
        connect(target.endpoint, title: target.display, via: via, bastionTitle: bastionTitle)
    }

    /// Connect a saved server (서버 관리 / double-click).
    private func connect(profile p: Profile, override: [Hop: String] = [:]) {
        if !open.isEmpty { disconnectAll(nil) }
        let all = (try? core.listProfiles()) ?? []
        guard let route = ProfileRoute(p, all: all) else {
            log.append(L("\"%@\"의 경유 서버를 찾을 수 없어요. 서버 관리에서 경유 서버 설정을 확인해 주세요.", "\(p.name)"), tone: .error)
            return
        }
        attempt = Attempt(profile: p, targetAccount: route.targetAccount, bastionAccount: route.bastionAccount)
        var known: [Hop: String] = [:]
        if let a = route.targetAccount { known[.target] = keychain.read(a) }
        if let a = route.bastionAccount { known[.bastion] = keychain.read(a) }
        known.merge(override) { _, dev in dev }
        prompts.beginAttempt(known: known)
        // Show what is being connected in the bar, like a quick connect.
        quickConnect.host.stringValue = p.address
        quickConnect.user.stringValue = ""
        quickConnect.port.stringValue = ""
        if let p = p.localDir { local.open(p) }
        terminals.reset()
        connect(route.target, title: route.title, via: route.via, bastionTitle: route.bastionTitle,
                startPath: p.remoteDir)
    }

    private func connect(_ target: Endpoint, title baseTitle: String, via: Via?, bastionTitle: String?,
                         withSftp: Bool = true, startPath: String? = nil) {
        busy = true
        refresh()
        let routed = bastionTitle != nil || viaConnection(via) != nil
        let title = baseTitle + (routed ? L(" ⇢경유") : "")
        let route = (bastionTitle ?? viaConnection(via).flatMap { open[$0] }).map { L(" (%@ 경유)", "\($0)") } ?? ""
        log.append(L("%@%@ 연결 중…", "\(baseTitle)", "\(route)"))
        let viaKey: String? = switch via {
        case .endpoint(let e): RouteKey.of(e)
        case .connection(let id): keys[id]
        case nil: nil
        }
        let key = RouteKey.of(target, viaKey: viaKey)
        Task {
            do {
                let c = try await core.connect(endpoint: target, via: via, withSftp: withSftp)
                if let b = c.bastion, let bastionTitle {
                    open[b] = bastionTitle
                    keys[b] = viaKey
                    secrets[b] = prompts.used[.bastion]
                    terminals.connected(b, title: L("%@ (경유 서버)", bastionTitle), makeActive: false)
                }
                open[c.id] = title
                keys[c.id] = key
                secrets[c.id] = prompts.used[.target]
                active = c.id
                busy = false
                terminals.connected(c.id, title: title)       // AC-1/2: list + shell from one login
                log.append(L("연결됐어요 · %@", "\(title)"))
                refresh()
                offerToSaveTypedPasswords()
                if withSftp {
                    await remote.attach(c.id, startPath: startPath)
                    offerRestore(key: key, connection: c.id)
                    // Dev only: JENAFILE_DEV_UPLOAD=/path/a:/path/b queues uploads after connecting.
                    if let dev = ProcessInfo.processInfo.environment["JENAFILE_DEV_UPLOAD"] {
                        upload(dev.split(separator: ":").map(String.init))
                    }
                } else {
                    remote.detach()
                    log.append(L("터미널에서 새 비밀번호로 바꾼 뒤, 끊고 다시 접속해 주세요."))
                }
            } catch let e as CoreError {
                busy = false
                refresh()
                log.append(UserMessage.describe(e), tone: .error)
                if case .PasswordExpired = e {
                    offerPasswordChange(target, title: baseTitle, via: via, bastionTitle: bastionTitle)
                }
            } catch {
                busy = false
                refresh()
                log.append(error.localizedDescription, tone: .error)
            }
        }
    }

    /// FR-03a: the user typed a password that worked — offer to keep it in the Keychain.
    private func offerToSaveTypedPasswords() {
        let pending: [(account: String, password: String, label: String)] = [
            (attempt.targetAccount, prompts.typed[.target], L("서버")),
            (attempt.bastionAccount, prompts.typed[.bastion], L("경유 서버")),
        ].compactMap { a, p, l in
            guard let a, let p, !p.isEmpty, keychain.read(a) != p else { return nil }
            return (a, p, l)
        }
        guard !pending.isEmpty else { return }
        let alert = NSAlert()
        let hadSaved = pending.contains { keychain.read($0.account) != nil }
        alert.messageText = hadSaved ? L("저장된 비밀번호를 바꿀까요?") : L("비밀번호를 저장할까요?")
        alert.informativeText = pending.map(\.label).joined(separator: "·")
            + L(" 비밀번호를 키체인에 저장해 두면 다음부터 묻지 않아요.")
        alert.addButton(withTitle: hadSaved ? L("바꾸기") : L("저장"))
        alert.addButton(withTitle: L("그대로 두기"))
        alert.beginSheetModal(for: window) { [keychain] response in
            guard response == .alertFirstButtonReturn else { return }
            for p in pending { keychain.save(p.password, for: p.account) }
        }
    }

    // MARK: FR-16 — unfinished transfers across restarts

    /// Live unfinished transfers + restored ones not yet claimed, debounced.
    private func schedulePendingSave() {
        guard !savePendingScheduled else { return }
        savePendingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.savePendingScheduled = false
            self?.savePending()
        }
    }

    func savePending() {
        let live = transferList.items.filter { PendingTransfer.unfinished($0.state) }.compactMap { t -> PendingTransfer? in
            guard let key = keys[t.connection] else { return nil }
            return PendingTransfer(key: key, upload: t.direction == .upload, local: t.localPath, remote: t.remotePath, size: t.size)
        }
        pendingStore.save(restored + live)
    }

    private func offerRestore(key: String, connection: UInt64) {
        let mine = restored.filter { $0.key == key }
        guard !mine.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("끝나지 않은 전송 %@개가 있어요", "\(mine.count)")
        alert.informativeText = L("지난번에 이 서버로 보내다 만 파일이에요. 받다 만 지점부터 이어서 할까요?\n")
            + mine.prefix(5).map { "· " + ($0.upload ? $0.remote : $0.local) }.joined(separator: "\n")
            + (mine.count > 5 ? L("\n… 외 %@개", "\(mine.count - 5)") : "")
        alert.addButton(withTitle: L("이어서 하기"))
        alert.addButton(withTitle: L("나중에"))
        alert.addButton(withTitle: L("버리기"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.restored.removeAll { $0.key == key }
                self.resume(mine, on: connection)
            case .alertThirdButtonReturn:
                self.restored.removeAll { $0.key == key }
                self.savePending()
            default:
                break
            }
        }
    }

    /// Re-queues them with "resume": a partial destination continues, a bigger one asks.
    private func resume(_ items: [PendingTransfer], on connection: UInt64) {
        let ups = Dictionary(grouping: items.filter(\.upload)) { RemotePath.parent($0.remote) }
        let downs = Dictionary(grouping: items.filter { !$0.upload }) { ($0.local as NSString).deletingLastPathComponent }
        Task {
            do {
                for (dir, group) in ups {
                    _ = try await core.upload(connection: connection, localPaths: group.map(\.local), remoteDir: dir, onConflict: .resume)
                }
                for (dir, group) in downs {
                    _ = try await core.download(connection: connection, remotePaths: group.map(\.remote), localDir: dir, onConflict: .resume)
                }
                log.append(L("끝나지 않은 전송 %@개를 이어서 하고 있어요", "\(items.count)"))
            } catch {
                log.append(UserMessage.describe(error), tone: .error)
            }
            savePending()
        }
    }

    private func viaConnection(_ via: Via?) -> UInt64? {
        if case .connection(let id) = via { return id }
        return nil
    }

    // MARK: transfers (M4)

    /// Local files / folders → the folder shown in the remote pane.
    private func upload(_ localPaths: [String]) {
        guard let id = active, remote.connection == id, !remote.path.isEmpty else {
            log.append(L("업로드하려면 먼저 서버에 접속해 주세요"), tone: .warn)
            return
        }
        let target = remote.path
        let onConflict = settings.onConflict.action
        Task {
            do {
                let ids = try await core.upload(connection: id, localPaths: localPaths, remoteDir: target, onConflict: onConflict)
                log.append(L("업로드 %@개를 대기열에 넣었어요 → %@", "\(ids.count)", "\(target)"))
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
        let onConflict = settings.onConflict.action
        Task {
            do {
                let ids = try await core.download(connection: id, remotePaths: remotePaths, localDir: target, onConflict: onConflict)
                log.append(L("다운로드 %@개를 대기열에 넣었어요 → %@", "\(ids.count)", "\(target)"))
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
                                                          reason: L("jena-file 파일 전송 중"))
        } else if !transferList.hasActive, let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    // MARK: FR-21 — open a server behind an open connection

    private func askInternalServer(via: UInt64) {
        let alert = NSAlert()
        alert.messageText = L("내부 서버 열기")
        alert.informativeText = L("%@를 거쳐 접속해요. 경유 서버 비밀번호는 다시 묻지 않아요.", "\(open[via] ?? L("이 서버"))")
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        let host = NSTextField(string: "")
        host.placeholderString = L("user@내부서버:22")
        let password = NSSecureTextField(string: "")
        password.placeholderString = L("비밀번호 (비워 두면 접속할 때 물어요)")
        for f in [host, password] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 280).isActive = true
            fields.addArrangedSubview(f)
        }
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = host
        alert.addButton(withTitle: L("접속"))
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let target = QuickConnectInput.parse(host: host.stringValue, user: "", port: "") else {
                self.log.append(L("내부 서버를 user@host:port 형식으로 입력해 주세요"), tone: .warn)
                return
            }
            self.attempt = Attempt()
            self.prompts.beginAttempt(known: [.target: password.stringValue])
            self.connect(target.endpoint, title: target.display, via: .connection(id: via), bastionTitle: nil)
        }
    }

    // MARK: FR-03b — expired password

    private func offerPasswordChange(_ target: Endpoint, title: String, via: Via?, bastionTitle: String?) {
        let alert = NSAlert()
        alert.messageText = L("비밀번호가 만료됐어요")
        alert.informativeText = L("%@ 계정의 비밀번호를 바꿔야 접속할 수 있어요.\n터미널을 열어 드릴게요. 서버가 현재 비밀번호와 새 비밀번호를 물어요.", "\(title)")
        alert.addButton(withTitle: L("터미널에서 변경"))
        alert.addButton(withTitle: L("닫기"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // Same route; passwords are asked again (we never keep typed ones around).
            self.prompts.beginAttempt(known: [:])
            self.terminals.reset()
            self.connect(target, title: title, via: via, bastionTitle: bastionTitle, withSftp: false)
        }
    }

    // MARK: core events

    func handle(_ event: CoreEvent) {
        switch event {
        case .log(_, _, let level, let message):
            // The core logs in English for diagnostics; the UI writes its own Korean
            // lines from state changes and errors, so only surface core warnings here.
            if level == .warn { log.append(message, tone: .warn) }
        case .promptRequested(let prompt, let connection, let hop, let kind):
            prompts.present(prompt: prompt, connection: connection, hop: hop, kind: kind)
        case .transfer(let info):
            transferList.update(info)
            updateAwake()
            schedulePendingSave()
            if case .failed(let m) = info.state {
                log.append(L("전송 실패: %@ — %@", "\((info.remotePath as NSString).lastPathComponent)", "\(m)"), tone: .error)
            }
        case .stateChanged(let id, let state):
            switch state {
            case .connecting(let step):
                status.stringValue = L("연결 중… (%@)", "\(stepText(step))")
            case .reconnecting(let attempt, let max):
                if attempt == 1, let title = open[id] {
                    log.append(L("연결이 끊겼어요 · %@ — 다시 연결하는 중…", "\(title)"), tone: .warn)
                }
                reconnecting.insert(id)
                status.stringValue = L("다시 연결 중… (%@/%@)", "\(attempt)", "\(max)")
            case .ready:
                // First connects are logged by connect() with a readable title.
                guard reconnecting.remove(id) != nil else { break }
                log.append(L("다시 연결됐어요 · %@", "\(open[id] ?? "")"))
                terminals.reconnected(id)
                if active == id { Task { await remote.refresh() } }
                refresh()
            case .failed(let error):
                if open[id] != nil { log.append(UserMessage.describe(error), tone: .error) }
                closed(id)
            case .closed:
                if let title = open[id] { log.append(L("연결을 끊었어요 · %@", "\(title)")) }
                closed(id)
            }
        }
    }

    private func closed(_ id: UInt64) {
        secrets[id] = nil
        reconnecting.remove(id)
        guard open.removeValue(forKey: id) != nil else { return }
        schedulePendingSave()   // keep failed transfers' keys before forgetting the route
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.keys[id] = nil }
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
        case .dialing: L("접속")
        case .auth: L("인증")
        case .sftp: L("SFTP 시작")
        }
    }

    private func refresh() {
        quickConnect.setConnected(!open.isEmpty, busy: busy)
        let state = active.flatMap { open[$0] }.map { L("연결됨: %@", "\($0)") } ?? (open.isEmpty ? L("연결 안 됨") : L("연결됨"))
        status.stringValue = "core \(CoreInfo.version) · \(state)"
    }

    // MARK: toolbar

    private static let serversItem = NSToolbarItem.Identifier("servers")

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .expanded
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.serversItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.serversItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.serversItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = L("서버 관리")
        item.paletteLabel = L("서버 관리")
        item.toolTip = L("저장된 서버 (⌘K)")
        item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: L("서버 관리"))
        item.target = self
        item.action = #selector(showServerManager(_:))
        return item
    }

    // MARK: menu actions

    @objc func showServerManager(_ sender: Any?) {
        if serverManager == nil {
            serverManager = ServerManagerWindow(core: core, keychain: keychain, settings: settings) { [weak self] p in self?.connect(profile: p) }
        }
        serverManager?.showWindow(nil)
        serverManager?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(settings: settings) { [weak self] in self?.applySettings() }
        }
        settingsWindow?.reload()
        settingsWindow?.showWindow(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: L("원격 파일 전송과 터미널을 한 화면에서.\ncore %@ · MIT License\ngithub.com/jenalab-com/jena-file", "\(CoreInfo.version)"),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "jena-file", .credits: credits])
    }

    @objc func openHelp(_ sender: Any?) {
        if helpWindow == nil { helpWindow = HelpWindow() }
        helpWindow?.show()
    }

    @objc func newShell(_ sender: Any?) { terminals.open(startDir: nil) }

    @objc func disconnectAll(_ sender: Any?) {
        guard !open.isEmpty else { return }
        busy = true
        refresh()
        let ids = Array(open.keys)
        Task {
            for id in ids { await core.disconnect(connection: id) }
        }
    }

    @objc func toggleLog(_ sender: Any?) { toggle(.log) }
    @objc func toggleTransfers(_ sender: Any?) { toggle(.transfers) }
    @objc func toggleTerminal(_ sender: Any?) { toggle(.terminal) }

    @objc func toggleErrorsOnly(_ sender: Any?) {
        settings.logErrorsOnly.toggle()
        log.errorsOnly = settings.logErrorsOnly
        if !isOn(.log), settings.logErrorsOnly { toggle(.log) }
    }

    @objc func toggleLocalHidden(_ sender: Any?) {
        settings.showLocalHidden.toggle()
        applySettings()
        settingsWindow?.reload()
    }

    private func isOn(_ pane: Pane) -> Bool {
        switch pane {
        case .log: settings.showLog
        case .transfers: settings.showTransfers
        case .terminal: settings.showTerminal
        }
    }

    private func toggle(_ pane: Pane) {
        let on = !isOn(pane)
        switch pane {
        case .log: settings.showLog = on
        case .transfers: settings.showTransfers = on
        case .terminal: settings.showTerminal = on
        }
        layout?.setVisible(pane, on)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLog(_:)): item.state = isOn(.log) ? .on : .off
        case #selector(toggleTransfers(_:)): item.state = isOn(.transfers) ? .on : .off
        case #selector(toggleTerminal(_:)): item.state = isOn(.terminal) ? .on : .off
        case #selector(toggleErrorsOnly(_:)): item.state = settings.logErrorsOnly ? .on : .off
        case #selector(toggleLocalHidden(_:)): item.state = settings.showLocalHidden ? .on : .off
        case #selector(newShell(_:)): return terminals.active != nil
        case #selector(disconnectAll(_:)): return !open.isEmpty
        default: break
        }
        return true
    }
}
