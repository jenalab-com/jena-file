import AppKit
import JenaFileKit

/// Left pane: this Mac — folder tree above, the chosen folder's contents below
/// (FileZilla). Drag rows to the remote pane to upload; drop remote rows here to
/// download into the shown folder.
final class LocalPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let browser: LocalBrowser
    private let pathField = NSTextField()
    private let upButton = FileTable.button("arrow.up", L("상위 폴더"))
    private let homeButton = FileTable.button("house", L("홈 폴더"))
    private let volumesButton = FileTable.button("externaldrive", L("외장 디스크"))
    private let refreshButton = FileTable.button("arrow.clockwise", L("새로 고침"))
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let overlay = NSTextField(wrappingLabelWithString: "")
    private let tree: FolderTree
    private var split: NSSplitView?
    private let ratios = SplitRatios(key: "localTree", defaults: [0.35])
    private var ratiosApplied = false
    private var treeShowsHidden: Bool
    /// Selected local paths → upload into the remote pane's folder.
    var onUpload: (([String]) -> Void)?
    /// Remote paths dropped here → download into `browser.path`.
    var onDownloadHere: (([String]) -> Void)?

    init(browser: LocalBrowser) {
        self.browser = browser
        tree = FolderTree { [weak browser] folder in try browser?.folders(at: folder) ?? [] }
        treeShowsHidden = browser.showsHidden
        super.init(frame: .zero)
        tree.onSelect = { [weak browser] path in browser?.open(path) }
        tree.outline.menu = {
            let m = NSMenu()
            FileTable.addPathItems(to: m, target: self, copy: #selector(copyPaths(_:)), rename: #selector(renameClicked(_:)))
            return m
        }()
        pathField.placeholderString = L("로컬 경로")
        pathField.target = self
        pathField.action = #selector(goToTypedPath)
        for (b, sel) in [(upButton, #selector(goUp)), (homeButton, #selector(goHome)), (volumesButton, #selector(showVolumes)), (refreshButton, #selector(refresh))] {
            b.target = self
            b.action = sel
        }
        FileTable.addColumns(table, permissions: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([FileTable.remotePathsType])
        table.menu = {
            let m = NSMenu()
            m.addItem(withTitle: L("업로드"), action: #selector(uploadSelected), keyEquivalent: "").target = self
            m.addItem(.separator())
            FileTable.addPathItems(to: m, target: self, copy: #selector(copyPaths(_:)), rename: #selector(renameClicked(_:)))
            m.addItem(.separator())
            m.addItem(withTitle: L("숨김 파일 보기"), action: #selector(toggleHidden), keyEquivalent: "").target = self
            return m
        }()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        split = FileTable.layout(in: self, bar: [upButton, homeButton, volumesButton, pathField, refreshButton],
                                 tree: tree, scroll: scroll, overlay: overlay)
        browser.onChange = { [weak self] in self?.render() }
        browser.refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Restore the tree | list divider once the pane has its real height.
        if !ratiosApplied, let split, split.bounds.height > 100 {
            ratiosApplied = true
            // Not inside this layout pass: positions set here get laid over again.
            DispatchQueue.main.async { [ratios] in ratios.apply(to: split) }
        }
    }

    private func render() {
        pathField.stringValue = browser.path
        table.reloadData()
        if treeShowsHidden != browser.showsHidden {
            treeShowsHidden = browser.showsHidden
            tree.reset()
        }
        switch browser.state {
        case .loaded:
            tree.update(browser.path, folders: browser.entries.filter(\.isDir).map(\.name))
            let path = browser.path
            Task { await tree.reveal(path) }
            overlay.stringValue = browser.entries.isEmpty ? L("빈 폴더예요") : ""
            overlay.textColor = .secondaryLabelColor
        case .failed(let message):
            overlay.stringValue = message
            overlay.textColor = .systemRed
        }
        overlay.isHidden = overlay.stringValue.isEmpty
    }

    private func targetRows() -> [Int] {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return Array(table.selectedRowIndexes)
    }

    @objc private func uploadSelected() {
        let paths = targetRows().map { browser.fullPath(browser.entries[$0]) }
        if !paths.isEmpty { onUpload?(paths) }
    }

    @objc private func toggleHidden() { browser.showsHidden.toggle() }

    // MARK: 경로 복사 · 이름 바꾸기 (tree and list)

    private func fromTree(_ item: NSMenuItem) -> Bool { item.menu === tree.outline.menu }

    /// The right-clicked rows; the shown folder when the click was on empty space.
    private func menuPaths(_ item: NSMenuItem) -> [String] {
        if fromTree(item) { return tree.clickedPath.map { [$0] } ?? [] }
        let rows = targetRows()
        return rows.isEmpty ? [browser.path] : rows.map { browser.fullPath(browser.entries[$0]) }
    }

    @objc private func copyPaths(_ sender: NSMenuItem) {
        let paths = menuPaths(sender)
        guard !paths.isEmpty else { return }
        FileTable.copyToPasteboard(PathText.text(paths, FileTable.copyKind(sender.tag), home: NSHomeDirectory()))
    }

    @objc private func renameClicked(_ sender: NSMenuItem) {
        let path: String, isDir: Bool, siblings: [String]
        if fromTree(sender) {
            guard let p = tree.clickedPath, p != "/" else { return }
            (path, isDir, siblings) = (p, true, tree.siblingNames(of: p))
        } else {
            let rows = targetRows()
            guard rows.count == 1 else { return }
            let e = browser.entries[rows[0]]
            (path, isDir, siblings) = (browser.fullPath(e), e.isDir, browser.entries.map(\.name))
        }
        let current = (path as NSString).lastPathComponent
        FileTable.askNewName(in: window, current: current, isDir: isDir) { [weak self] name in
            guard let self, name != current else { return }
            if let problem = PathText.renameProblem(name, current: current, siblings: siblings) {
                FileTable.showError(problem, in: self.window)
                return
            }
            let parent = RemotePath.parent(path)
            let to = RemotePath.join(parent, name)
            do {
                try LocalBrowser.rename(path, to: to)
            } catch {
                FileTable.showError(L("이름을 바꾸지 못했어요 (%@)", error.localizedDescription), in: self.window)
                return
            }
            // The shown folder (or one above it) was renamed: follow it.
            let shown = self.browser.path
            if shown == path || shown.hasPrefix(path + "/") {
                self.browser.open(to + shown.dropFirst(path.count))
            } else {
                self.browser.refresh()
            }
            Task { await self.tree.reload(parent) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(renameClicked(_:)) else { return true }
        if fromTree(item) { return tree.clickedPath.map { $0 != "/" } ?? false }
        return targetRows().count == 1
    }

    @objc private func openSelected() {
        let row = table.clickedRow
        guard row >= 0, row < browser.entries.count else { return }
        browser.enter(browser.entries[row])
    }

    @objc private func goUp() { browser.goUp() }
    @objc private func goHome() { browser.open(FileManager.default.homeDirectoryForCurrentUser.path) }
    @objc private func refresh() { browser.refresh() }

    /// Mounted drives as a menu under the button, like Finder's Locations.
    @objc private func showVolumes() {
        let m = NSMenu()
        let volumes = LocalBrowser.volumes()
        for url in volumes {
            let item = m.addItem(withTitle: FileManager.default.displayName(atPath: url.path),
                                 action: #selector(openVolume(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url.path
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        if volumes.isEmpty { m.addItem(withTitle: L("연결된 외장 디스크가 없어요"), action: nil, keyEquivalent: "").isEnabled = false }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: volumesButton.bounds.height + 4), in: volumesButton)
    }

    @objc private func openVolume(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { browser.open(path) }
    }
    @objc private func goToTypedPath() { browser.open(pathField.stringValue) }

    var currentPath: String { browser.path }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { browser.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let e = browser.entries[row]
        let cell = FileTable.cell(tableView, id, owner: self)
        switch id {
        case "name": FileTable.setName(cell, e.name, isDir: e.isDir)
        case "size": cell.textField?.stringValue = Format.size(e.size, isDir: e.isDir)
        default: cell.textField?.stringValue = Format.date(e.modified)
        }
        return cell
    }

    /// Drag out as file URLs: the remote pane uploads them, Finder copies them.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        URL(fileURLWithPath: browser.fullPath(browser.entries[row])) as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.availableType(from: [FileTable.remotePathsType]) != nil else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)   // whole table = current folder
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let paths = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: FileTable.remotePathsType) }
            .compactMap { try? JSONDecoder().decode([String].self, from: $0) }.flatMap { $0 }
        guard !paths.isEmpty else { return false }
        onDownloadHere?(paths)
        return true
    }
}
