import AppKit
import JenaFileCore
import JenaFileKit

/// 서버 관리 (기획서 S-02): saved servers on the left, the selected one on the right.
/// Passwords go to the Keychain, never to profiles.json. Double-click or 접속 to connect.
@MainActor
final class ServerManagerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let core: Core
    private let keychain: KeychainStore
    private let onConnect: (Profile) -> Void
    private var profiles: [Profile] = []
    /// What the form edits. `id` empty = not saved yet.
    private var editing = Profile.blank()

    private let table = NSTableView()
    private let name = NSTextField()
    private let group = NSTextField()
    private let host = NSTextField()
    private let port = NSTextField()
    private let user = NSTextField()
    private let password = NSSecureTextField()
    private let savePassword = NSButton(checkboxWithTitle: L("키체인에 저장"), target: nil, action: nil)
    private let via = NSPopUpButton()
    private let viaEndpoint = NSTextField()
    private let remoteDir = NSTextField()
    private let localDir = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private let remove = NSButton(title: L("삭제"), target: nil, action: nil)
    private let duplicate = NSButton(title: L("복제"), target: nil, action: nil)
    private var grid: NSGridView?

    init(core: Core, keychain: KeychainStore, onConnect: @escaping (Profile) -> Void) {
        self.core = core
        self.keychain = keychain
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("서버 관리")
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        build()
        reload(select: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: .init("server"))
        col.title = L("서버")
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: L("새 서버"), target: self, action: #selector(newServer))
        let fromSsh = NSButton(title: L("ssh 명령으로…"), target: self, action: #selector(createFromSsh))
        fromSsh.toolTip = L("평소 쓰던 ssh 명령(-L, -J 포함)을 붙여 넣어 서버를 만들어요")
        duplicate.target = self
        duplicate.action = #selector(duplicateServer)
        remove.target = self
        remove.action = #selector(deleteServer)
        let listButtons = NSStackView(views: [add, duplicate, remove, NSView(), fromSsh])

        port.placeholderString = "22"
        user.placeholderString = L("사용자")
        host.placeholderString = L("example.com 또는 10.0.0.5")
        password.placeholderString = L("비워 두면 접속할 때 물어요")
        name.placeholderString = L("비워 두면 호스트 이름")
        group.placeholderString = L("예: 고객사, 개인")
        viaEndpoint.placeholderString = "bastion: user@host:port"
        remoteDir.placeholderString = L("비워 두면 홈 폴더")
        localDir.placeholderString = L("비워 두면 설정의 시작 폴더")
        via.target = self
        via.action = #selector(viaChanged)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        let chooseLocal = NSButton(title: L("선택…"), target: self, action: #selector(chooseLocalDir))

        let grid = NSGridView(views: [
            [label(L("이름")), name],
            [label(L("그룹")), group],
            [label(L("호스트")), NSStackView(views: [host, label(L("포트")), port])],
            [label(L("사용자")), user],
            [label(L("비밀번호")), NSStackView(views: [password, savePassword])],
            [label(L("경유(bastion)")), via],
            [NSGridCell.emptyContentView, viaEndpoint],
            [label(L("원격 시작 폴더")), remoteDir],
            [label(L("로컬 시작 폴더")), NSStackView(views: [localDir, chooseLocal])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        self.grid = grid
        port.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for f in [name, group, user, remoteDir, viaEndpoint] as [NSView] {
            f.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        host.widthAnchor.constraint(equalToConstant: 230).isActive = true
        password.widthAnchor.constraint(equalToConstant: 220).isActive = true
        localDir.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let save = NSButton(title: L("저장"), target: self, action: #selector(saveClicked))
        let connect = NSButton(title: L("접속"), target: self, action: #selector(connectClicked))
        connect.keyEquivalent = "\r"
        let formButtons = NSStackView(views: [message, NSView(), save, connect])

        for v in [scroll, listButtons, grid, formButtons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 270),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -8),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            formButtons.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            formButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            formButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    // MARK: data

    private func reload(select id: String?) {
        do {
            profiles = try core.listProfiles()
        } catch {
            say(UserMessage.describe(error), error: true)
        }
        table.reloadData()
        if let id, let row = profiles.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            load(profiles[row])
        } else if let first = profiles.first, editing.id.isEmpty, editing.host.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            load(first)
        } else if profiles.isEmpty {
            load(.blank())
        }
        refreshButtons()
    }

    private func load(_ p: Profile) {
        editing = p
        name.stringValue = p.name
        group.stringValue = p.group
        host.stringValue = p.host
        port.stringValue = p.port == 22 ? "" : String(p.port)
        user.stringValue = p.user
        password.stringValue = p.id.isEmpty ? "" : (keychain.read(p.id) ?? "")
        savePassword.state = p.savePassword ? .on : .off
        remoteDir.stringValue = p.remoteDir ?? ""
        localDir.stringValue = p.localDir ?? ""

        via.removeAllItems()
        via.addItem(withTitle: L("경유 안 함 (직접 접속)"))
        for other in profiles where other.id != p.id {
            via.addItem(withTitle: "\(other.name)  —  \(other.address)")
            via.lastItem?.representedObject = other.id
        }
        via.addItem(withTitle: L("직접 입력…"))
        viaEndpoint.stringValue = ""
        switch p.via {
        case nil: via.selectItem(at: 0)
        case .server(let id): via.selectItem(at: max(via.indexOfItem(withRepresentedObject: id), 0))
        case .endpoint(let h, let po, let u):
            via.selectItem(at: via.numberOfItems - 1)
            viaEndpoint.stringValue = po == 22 ? "\(u)@\(h)" : "\(u)@\(h):\(po)"
        }
        viaChanged()
        say(p.id.isEmpty ? L("새 서버예요. 저장하면 목록에 들어가요.") : "")
        refreshButtons()
    }

    /// Form → profile. nil (with a message) when something required is missing.
    private func form() -> Profile? {
        var p = editing
        p.name = name.stringValue.trimmingCharacters(in: .whitespaces)
        p.group = group.stringValue.trimmingCharacters(in: .whitespaces)
        p.host = host.stringValue.trimmingCharacters(in: .whitespaces)
        p.user = user.stringValue.trimmingCharacters(in: .whitespaces)
        let portText = port.stringValue.trimmingCharacters(in: .whitespaces)
        guard let po = portText.isEmpty ? 22 : UInt16(portText), po > 0 else {
            say(L("포트는 1~65535 숫자여야 해요"), error: true)
            return nil
        }
        p.port = po
        guard !p.host.isEmpty, !p.user.isEmpty else {
            say(L("호스트와 사용자는 꼭 필요해요"), error: true)
            return nil
        }
        p.savePassword = savePassword.state == .on
        p.remoteDir = remoteDir.stringValue.isEmpty ? nil : remoteDir.stringValue
        p.localDir = localDir.stringValue.isEmpty ? nil : localDir.stringValue
        let i = via.indexOfSelectedItem
        if i <= 0 {
            p.via = nil
        } else if i == via.numberOfItems - 1 {
            guard let b = QuickConnectInput.parse(host: viaEndpoint.stringValue, user: "", port: "") else {
                say(L("bastion을 user@host:port 형식으로 입력해 주세요"), error: true)
                return nil
            }
            p.via = .endpoint(host: b.host, port: b.port, user: b.user)
        } else if let id = via.selectedItem?.representedObject as? String {
            p.via = .server(id: id)
        }
        return p
    }

    @discardableResult
    private func saveForm() -> Profile? {
        guard let p = form() else { return nil }
        do {
            let saved = try core.saveProfile(profile: p)
            if saved.savePassword, !password.stringValue.isEmpty {
                keychain.save(password.stringValue, for: saved.id)
            } else if !saved.savePassword {
                keychain.delete(saved.id)
                keychain.delete(saved.id + "#bastion")
            }
            editing = saved
            reload(select: saved.id)
            say(L("저장했어요"))
            return saved
        } catch {
            say(UserMessage.describe(error), error: true)
            return nil
        }
    }

    private func say(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func refreshButtons() {
        remove.isEnabled = !editing.id.isEmpty
        duplicate.isEnabled = !editing.id.isEmpty
    }

    // MARK: actions

    @objc private func viaChanged() {
        // Row 6 = the "직접 입력" bastion field; hide the whole row, not just the field.
        grid?.row(at: 6).isHidden = via.indexOfSelectedItem != via.numberOfItems - 1
    }

    @objc private func newServer() {
        table.deselectAll(nil)
        load(.blank())
        window?.makeFirstResponder(host)
    }

    @objc private func duplicateServer() {
        var copy = editing
        copy.id = ""
        copy.name = editing.name + L(" 사본")
        table.deselectAll(nil)
        load(copy)
    }

    @objc private func deleteServer() {
        guard !editing.id.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("\"%@\" 서버를 지울까요?", "\(editing.name)")
        alert.informativeText = L("저장된 비밀번호도 키체인에서 지워져요.")
        alert.addButton(withTitle: L("삭제"))
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.core.deleteProfile(id: self.editing.id)
                self.keychain.delete(self.editing.id)
                self.keychain.delete(self.editing.id + "#bastion")
                self.editing = .blank()
                self.reload(select: nil)
            } catch {
                self.say(L("지울 수 없어요: ") + UserMessage.describe(error), error: true)
            }
        }
    }

    @objc private func saveClicked() { saveForm() }

    /// Button or double-click (the click already selected and loaded the row).
    @objc private func connectClicked() {
        guard let saved = saveForm() else { return }
        close()
        onConnect(saved)
    }

    @objc private func chooseLocalDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("선택")
        if panel.runModal() == .OK, let url = panel.url { localDir.stringValue = url.path }
    }

    /// FR-09: `ssh -L 2222:<internal>:22 user@<bastion>` → bastion + internal server.
    @objc private func createFromSsh() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("ssh 명령으로 서버 만들기")
        alert.informativeText = L("평소 쓰던 명령을 붙여 넣으세요. -L / -J가 있으면 bastion과 내부 서버를 함께 만들어요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "ssh -L 2222:10.0.0.5:22 user@bastion.example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("만들기"))
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let made = profilesFromSshCommand(text: field.stringValue) else {
                self.say(L("ssh 명령을 이해하지 못했어요"), error: true)
                return
            }
            var target = made.target
            target.savePassword = true
            if var bastion = made.bastion {
                guard !bastion.user.isEmpty else {
                    self.say(L("bastion 사용자 이름이 명령에 없어요 (user@host로 적어 주세요)"), error: true)
                    return
                }
                bastion.savePassword = true
                do {
                    let saved = try self.core.saveProfile(profile: bastion)
                    target.via = .server(id: saved.id)
                } catch {
                    self.say(UserMessage.describe(error), error: true)
                    return
                }
                self.reload(select: nil)
            }
            self.table.deselectAll(nil)
            self.load(target)
            if target.user.isEmpty {
                self.say(L("내부 서버의 사용자 이름을 넣고 저장하세요 (-L에는 사용자가 없어요)"))
                self.window?.makeFirstResponder(self.user)
            }
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profiles[row]
        let cell = tableView.makeView(withIdentifier: .init("server"), owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("server")
            let title = NSTextField(labelWithString: "")
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [title, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(stack)
            c.textField = title
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (p.group.isEmpty ? "" : "\(p.group) / ") + p.name
        let detail = (cell.subviews.first as? NSStackView)?.arrangedSubviews.last as? NSTextField
        let route = p.via == nil ? "" : "  ⇢bastion"
        detail?.stringValue = p.address + route
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < profiles.count else { return }
        load(profiles[row])
    }
}
