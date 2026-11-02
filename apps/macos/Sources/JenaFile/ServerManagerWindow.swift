import AppKit
import JenaFileCore
import JenaFileKit

/// 서버 관리 (기획서 S-02): saved servers on the left as a tree (groups, then servers
/// without a group), the selected one on the right. Drag a server onto a group to move
/// it. Passwords go to the Keychain, never to profiles.json. Double-click or 접속 to connect.
@MainActor
final class ServerManagerWindow: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private final class GroupNode {
        let name: String
        let servers: [ServerNode]
        init(name: String, servers: [ServerNode]) { self.name = name; self.servers = servers }
    }

    private final class ServerNode {
        let profile: Profile
        init(_ profile: Profile) { self.profile = profile }
    }

    private enum Selection {
        case server(String)
        case group(String)
    }

    private static let serverType = NSPasteboard.PasteboardType("com.jenalab.jenafile.server-id")

    private let core: Core
    private let keychain: KeychainStore
    private let settings: AppSettings
    private let onConnect: (Profile) -> Void
    private var profiles: [Profile] = []
    private var tree = ServerTree(profiles: [], groupNames: [])
    private var groupNodes: [GroupNode] = []
    private var rootNodes: [ServerNode] = []
    /// Groups start open; this remembers the ones the user closed.
    private var collapsed: Set<String> = []
    /// What the form edits. `id` empty = not saved yet. Its `group` is set by the tree.
    private var editing = Profile.blank()

    private let outline = NSOutlineView()
    private let name = NSTextField()
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

    init(core: Core, keychain: KeychainStore, settings: AppSettings, onConnect: @escaping (Profile) -> Void) {
        self.core = core
        self.keychain = keychain
        self.settings = settings
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("서버 관리")
        window.minSize = NSSize(width: 840, height: 420)
        super.init(window: window)
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: .init("server"))
        col.title = L("서버")
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([Self.serverType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.menu = {
            let m = NSMenu()
            m.delegate = self
            return m
        }()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: L("새 서버"), target: self, action: #selector(newServer))
        let addGroup = NSButton(title: L("새 그룹"), target: self, action: #selector(newGroup))
        let fromSsh = NSButton(title: L("ssh 명령으로…"), target: self, action: #selector(createFromSsh))
        fromSsh.toolTip = L("평소 쓰던 ssh 명령(-L, -J 포함)을 붙여 넣어 서버를 만들어요")
        duplicate.target = self
        duplicate.action = #selector(duplicateServer)
        remove.target = self
        remove.action = #selector(deleteClicked)
        let listButtons = NSStackView(views: [add, addGroup, duplicate, remove, NSView(), fromSsh])

        port.placeholderString = "22"
        user.placeholderString = L("사용자")
        host.placeholderString = L("example.com 또는 10.0.0.5")
        password.placeholderString = L("비워 두면 접속할 때 물어요")
        name.placeholderString = L("비워 두면 호스트 이름")
        viaEndpoint.placeholderString = L("경유 서버: user@host:port")
        remoteDir.placeholderString = L("비워 두면 홈 폴더")
        localDir.placeholderString = L("비워 두면 설정의 시작 폴더")
        via.target = self
        via.action = #selector(viaChanged)
        via.toolTip = L("점프 호스트(ProxyJump, bastion)처럼 다른 서버를 거쳐 접속할 때 골라요")
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        let chooseLocal = NSButton(title: L("선택…"), target: self, action: #selector(chooseLocalDir))

        let grid = NSGridView(views: [
            [label(L("이름")), name],
            [label(L("호스트")), NSStackView(views: [host, label(L("포트")), port])],
            [label(L("사용자")), user],
            [label(L("비밀번호")), NSStackView(views: [password, savePassword])],
            [label(L("경유 서버")), via],
            [NSGridCell.emptyContentView, viaEndpoint],
            [label(L("원격 시작 폴더")), remoteDir],
            [label(L("로컬 시작 폴더")), NSStackView(views: [localDir, chooseLocal])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        self.grid = grid
        port.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for f in [name, user, remoteDir, viaEndpoint] as [NSView] {
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
            scroll.widthAnchor.constraint(equalToConstant: 360),
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

    private func reload(select: Selection? = nil) {
        do {
            profiles = try core.listProfiles()
        } catch {
            say(UserMessage.describe(error), error: true)
        }
        tree = ServerTree(profiles: profiles, groupNames: settings.serverGroups)
        groupNodes = tree.groups.map { g in GroupNode(name: g.name, servers: g.servers.map(ServerNode.init)) }
        rootNodes = tree.root.map(ServerNode.init)
        outline.reloadData()
        for g in groupNodes where !collapsed.contains(g.name) { outline.expandItem(g) }

        switch select {
        case .server(let id):
            if let node = serverNode(id) { selectItem(node) }
            load(serverNode(id)?.profile ?? editing)
        case .group(let groupName):
            if let node = groupNodes.first(where: { $0.name == groupName }) { selectItem(node) }
            load(.blank(group: groupName))
        case nil:
            if !editing.id.isEmpty, let node = serverNode(editing.id) {
                selectItem(node)
            } else if let first = groupNodes.flatMap(\.servers).first ?? rootNodes.first, editing.id.isEmpty, editing.host.isEmpty {
                selectItem(first)
                load(first.profile)
            } else if profiles.isEmpty {
                load(.blank())
            }
        }
        refreshButtons()
    }

    private func serverNode(_ id: String) -> ServerNode? {
        (groupNodes.flatMap(\.servers) + rootNodes).first { $0.profile.id == id }
    }

    private func selectItem(_ item: AnyObject) {
        if let s = item as? ServerNode, let g = groupNodes.first(where: { $0.servers.contains { $0 === s } }) {
            outline.expandItem(g)
        }
        let row = outline.row(forItem: item)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private var selectedItem: AnyObject? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as AnyObject? : nil
    }

    /// Where a new server goes: the selected group, or the selected server's group.
    private var currentGroup: String {
        switch selectedItem {
        case let g as GroupNode: g.name
        case let s as ServerNode: s.profile.group
        default: editing.id.isEmpty ? editing.group : ""
        }
    }

    private func load(_ p: Profile) {
        editing = p
        name.stringValue = p.name
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
        if !p.id.isEmpty {
            say("")
        } else if p.group.isEmpty {
            say(L("새 서버예요. 저장하면 목록에 들어가요."))
        } else {
            say(L("새 서버예요. 저장하면 \"%@\" 그룹에 들어가요.", p.group))
        }
        refreshButtons()
    }

    /// Form → profile. nil (with a message) when something required is missing.
    private func form() -> Profile? {
        var p = editing
        p.name = name.stringValue.trimmingCharacters(in: .whitespaces)
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
                say(L("경유 서버를 user@host:port 형식으로 입력해 주세요"), error: true)
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
            reload(select: .server(saved.id))
            say(L("저장했어요"))
            return saved
        } catch {
            say(UserMessage.describe(error), error: true)
            return nil
        }
    }

    /// Puts saved servers into `group` ("" = no group).
    private func move(_ ids: [String], to group: String) -> Bool {
        for id in ids {
            guard var p = profiles.first(where: { $0.id == id }), p.group != group else { continue }
            p.group = group
            do {
                _ = try core.saveProfile(profile: p)
            } catch {
                say(UserMessage.describe(error), error: true)
                return false
            }
            if editing.id == id { editing.group = group }
        }
        return true
    }

    private func say(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func refreshButtons() {
        remove.isEnabled = !editing.id.isEmpty || selectedItem is GroupNode
        duplicate.isEnabled = !editing.id.isEmpty
    }

    /// One-line text prompt as a sheet (group name).
    private func askName(_ title: String, initial: String = "", button: String, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = L("예: 고객사, 개인")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            done(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: actions

    @objc private func viaChanged() {
        // Row 5 = the "직접 입력" bastion field; hide the whole row, not just the field.
        grid?.row(at: 5).isHidden = via.indexOfSelectedItem != via.numberOfItems - 1
    }

    @objc private func newServer() {
        let group = currentGroup
        outline.deselectAll(nil)
        load(.blank(group: group))
        window?.makeFirstResponder(host)
    }

    @objc private func newGroup() {
        askName(L("새 그룹"), button: L("만들기")) { [weak self] groupName in
            guard let self else { return }
            if let problem = self.tree.problem(withGroupName: groupName) {
                self.say(problem, error: true)
                return
            }
            self.settings.serverGroups.append(groupName)
            self.reload(select: .group(groupName))
            self.say(L("\"%@\" 그룹을 만들었어요. 새 서버를 넣어 보세요.", groupName))
        }
    }

    @objc private func renameGroup() {
        guard let g = selectedItem as? GroupNode else { return }
        askName(L("그룹 이름 바꾸기"), initial: g.name, button: L("바꾸기")) { [weak self] newName in
            guard let self, newName != g.name else { return }
            if let problem = self.tree.problem(withGroupName: newName, renaming: g.name) {
                self.say(problem, error: true)
                return
            }
            guard self.move(g.servers.map(\.profile.id), to: newName) else { return }
            self.settings.serverGroups = self.settings.serverGroups.filter { $0 != g.name } + [newName]
            if self.collapsed.remove(g.name) != nil { self.collapsed.insert(newName) }
            self.reload(select: .group(newName))
        }
    }

    @objc private func duplicateServer() {
        var copy = editing
        copy.id = ""
        copy.name = editing.name + L(" 사본")
        outline.deselectAll(nil)
        load(copy)
    }

    @objc private func removeFromGroup() {
        guard let s = selectedItem as? ServerNode, move([s.profile.id], to: "") else { return }
        reload(select: .server(s.profile.id))
    }

    @objc private func deleteClicked() {
        if let g = selectedItem as? GroupNode { deleteGroup(g) } else { deleteServer() }
    }

    private func deleteServer() {
        guard !editing.id.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("\"%@\" 서버를 지울까요?", "\(editing.name)")
        alert.informativeText = L("저장된 비밀번호도 키체인에서 지워져요.")
        alert.addButton(withTitle: L("삭제"))
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.deleteProfile(self.editing.id)
                self.editing = .blank()
                self.reload()
            } catch {
                self.say(L("지울 수 없어요: ") + UserMessage.describe(error), error: true)
            }
        }
    }

    private func deleteProfile(_ id: String) throws {
        try core.deleteProfile(id: id)
        keychain.delete(id)
        keychain.delete(id + "#bastion")
    }

    /// Asks whether the servers go too; kept servers move out to the root.
    private func deleteGroup(_ g: GroupNode) {
        guard let window else { return }
        let forget = { [weak self] in
            guard let self else { return }
            self.settings.serverGroups.removeAll { $0 == g.name }
            self.collapsed.remove(g.name)
        }
        let ids = g.servers.map(\.profile.id)
        if ids.isEmpty {
            forget()
            reload()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("\"%@\" 그룹을 지울까요?", g.name)
        alert.informativeText = L("안에 있는 서버 %@개도 함께 지울까요? 남기면 그룹 없이 목록 맨 아래로 옮겨져요.", "\(ids.count)")
        alert.addButton(withTitle: L("서버는 남기기"))
        let deleteAll = alert.addButton(withTitle: L("서버도 삭제"))
        deleteAll.hasDestructiveAction = true
        alert.addButton(withTitle: L("취소")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.move(ids, to: "") else { return }
                forget()
                self.reload()
                self.say(L("그룹을 지우고 서버 %@개를 밖으로 옮겼어요", "\(ids.count)"))
            case .alertSecondButtonReturn:
                // A bastion can only go after the servers using it — retry until nothing changes.
                var left = ids
                var progressed = true
                while progressed, !left.isEmpty {
                    progressed = false
                    for id in left where (try? self.deleteProfile(id)) != nil {
                        left.removeAll { $0 == id }
                        progressed = true
                    }
                }
                if ids.contains(self.editing.id), !left.contains(self.editing.id) { self.editing = .blank() }
                _ = self.move(left, to: "")
                forget()
                self.reload()
                self.say(left.isEmpty
                    ? L("그룹과 서버 %@개를 지웠어요", "\(ids.count)")
                    : L("서버 %@개는 다른 서버의 경유 서버라 지우지 않고 밖으로 옮겼어요", "\(left.count)"),
                    error: !left.isEmpty)
            default:
                break
            }
        }
    }

    @objc private func saveClicked() { saveForm() }

    /// Button or double-click on a server (the click already selected and loaded it).
    @objc private func connectClicked() {
        guard let saved = saveForm() else { return }
        close()
        onConnect(saved)
    }

    @objc private func doubleClicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let g = item as? GroupNode {
            outline.isItemExpanded(g) ? outline.collapseItem(g) : outline.expandItem(g)
        } else if item is ServerNode {
            connectClicked()
        }
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
        let group = currentGroup
        let alert = NSAlert()
        alert.messageText = L("ssh 명령으로 서버 만들기")
        alert.informativeText = L("평소 쓰던 명령을 붙여 넣으세요. -L / -J가 있으면 경유 서버와 내부 서버를 함께 만들어요.")
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
            target.group = group
            if var bastion = made.bastion {
                guard !bastion.user.isEmpty else {
                    self.say(L("경유 서버의 사용자 이름이 명령에 없어요 (user@host로 적어 주세요)"), error: true)
                    return
                }
                bastion.savePassword = true
                bastion.group = group
                do {
                    let saved = try self.core.saveProfile(profile: bastion)
                    target.via = .server(id: saved.id)
                } catch {
                    self.say(UserMessage.describe(error), error: true)
                    return
                }
                self.reload()
            }
            self.outline.deselectAll(nil)
            self.load(target)
            if target.user.isEmpty {
                self.say(L("내부 서버의 사용자 이름을 넣고 저장하세요 (-L에는 사용자가 없어요)"))
                self.window?.makeFirstResponder(self.user)
            }
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        let add = { (title: String, action: Selector) in
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        switch row >= 0 ? outline.item(atRow: row) : nil {
        case is GroupNode:
            add(L("이 그룹에 새 서버"), #selector(newServer))
            add(L("그룹 이름 바꾸기…"), #selector(renameGroup))
            menu.addItem(.separator())
            add(L("그룹 삭제…"), #selector(deleteClicked))
        case let s as ServerNode:
            add(L("접속"), #selector(connectClicked))
            add(L("복제"), #selector(duplicateServer))
            if !s.profile.group.isEmpty { add(L("그룹에서 빼기"), #selector(removeFromGroup)) }
            menu.addItem(.separator())
            add(L("삭제…"), #selector(deleteClicked))
        default:
            outline.deselectAll(nil)
            add(L("새 서버"), #selector(newServer))
            add(L("새 그룹"), #selector(newGroup))
        }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: groupNodes.count + rootNodes.count
        case let g as GroupNode: g.servers.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? GroupNode { return g.servers[index] }
        return index < groupNodes.count ? groupNodes[index] : rootNodes[index - groupNodes.count]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is GroupNode }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is GroupNode ? 24 : 34
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let g = item as? GroupNode {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = .init("group")
                let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
                let title = NSTextField(labelWithString: "")
                title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                title.lineBreakMode = .byTruncatingTail
                let stack = NSStackView(views: [icon, title])
                stack.spacing = 5
                stack.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(stack)
                c.textField = title
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                    stack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = "\(g.name)  (\(g.servers.count))"
            return cell
        }
        guard let p = (item as? ServerNode)?.profile else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("server"), owner: self) as? NSTableCellView ?? {
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
        cell.textField?.stringValue = p.name
        let detail = (cell.subviews.first as? NSStackView)?.arrangedSubviews.last as? NSTextField
        let route = p.via == nil ? "" : " " + L(" ⇢경유")
        detail?.stringValue = p.address + route
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        switch selectedItem {
        case let s as ServerNode: load(s.profile)
        case let g as GroupNode: load(.blank(group: g.name))
        default: refreshButtons()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let g = notification.userInfo?["NSObject"] as? GroupNode { collapsed.insert(g.name) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let g = notification.userInfo?["NSObject"] as? GroupNode { collapsed.remove(g.name) }
    }

    // MARK: drag a server onto a group (or the empty area = no group)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let s = item as? ServerNode else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(s.profile.id, forType: Self.serverType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: Self.serverType),
              let p = profiles.first(where: { $0.id == id }) else { return [] }
        // Onto/among a group's servers → that group; anywhere else → no group.
        let target: GroupNode? = switch item {
        case let g as GroupNode: g
        case let s as ServerNode: groupNodes.first { $0.servers.contains { $0 === s } }
        default: nil
        }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return (target?.name ?? "") == p.group ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.serverType),
              move([id], to: (item as? GroupNode)?.name ?? "") else { return false }
        reload(select: .server(id))
        return true
    }
}
