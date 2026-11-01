import AppKit
import JenaFileCore
import JenaFileKit

/// Remote file pane: path bar + table, with loading / empty / error / disconnected
/// states (기획서 §7.3). Double-click a folder to enter it. Drop Mac files here to
/// upload into the shown folder; drag rows to the local pane to download, or to
/// the terminal to type their paths.
final class RemotePane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let browser: RemoteBrowser
    private let pathField = NSTextField()
    private let upButton = FileTable.button("arrow.up", "상위 폴더")
    private let refreshButton = FileTable.button("arrow.clockwise", "새로 고침")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let overlay = NSTextField(wrappingLabelWithString: "")
    /// "여기서 터미널 열기" (FR-33): folder to cd into.
    var onOpenTerminal: ((String) -> Void)?
    /// "경로를 터미널에 넣기": paths to type.
    var onInsertPaths: (([String]) -> Void)?
    /// Selected remote paths → download into the local pane's folder.
    var onDownload: (([String]) -> Void)?
    /// Mac files dropped here → upload into `browser.path`.
    var onUploadHere: (([String]) -> Void)?

    init(browser: RemoteBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        pathField.placeholderString = "원격 경로"
        pathField.target = self
        pathField.action = #selector(goToTypedPath)
        upButton.target = self
        upButton.action = #selector(goUp)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        FileTable.addColumns(table, permissions: true)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        table.menu = contextMenu()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        FileTable.layout(in: self, bar: [upButton, pathField, refreshButton], scroll: scroll, overlay: overlay)
        browser.onChange = { [weak self] in self?.render() }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        let connected = browser.connection != nil
        pathField.stringValue = browser.path
        for c in [pathField, upButton, refreshButton] as [NSControl] { c.isEnabled = connected }
        table.reloadData()
        switch browser.state {
        case .disconnected:
            show("서버에 접속하면 여기에 원격 폴더가 보여요")
        case .loading:
            table.alphaValue = 0.4   // keep the previous listing, dimmed
            show(browser.entries.isEmpty ? "불러오는 중…" : nil)
            return
        case .loaded:
            show(browser.entries.isEmpty ? "빈 폴더예요" : nil)
        case .failed(let message):
            show(message, error: true)
        }
        table.alphaValue = 1
    }

    private func show(_ message: String?, error: Bool = false) {
        overlay.stringValue = message ?? ""
        overlay.isHidden = message == nil
        overlay.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: context menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "다운로드", action: #selector(downloadSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "여기서 터미널 열기", action: #selector(openTerminalHere), keyEquivalent: "").target = self
        menu.addItem(withTitle: "경로를 터미널에 넣기", action: #selector(insertPaths), keyEquivalent: "").target = self
        return menu
    }

    /// Rows the menu acts on: the clicked row (plus selection if it is part of it).
    private func targetRows() -> [Int] {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return Array(table.selectedRowIndexes)
    }

    private func path(_ row: Int) -> String { RemotePath.join(browser.path, browser.entries[row].name) }

    @objc private func downloadSelected() {
        let paths = targetRows().map(path)
        if !paths.isEmpty { onDownload?(paths) }
    }

    @objc private func openTerminalHere() {
        guard browser.connection != nil else { return }
        let folder = targetRows().first { browser.entries[$0].isDir }
        onOpenTerminal?(folder.map(path) ?? browser.path)
    }

    @objc private func insertPaths() {
        let rows = targetRows()
        onInsertPaths?(rows.isEmpty ? [browser.path] : rows.map(path))
    }

    // MARK: actions

    @objc private func openSelected() {
        let row = table.clickedRow
        guard row >= 0, row < browser.entries.count else { return }
        let entry = browser.entries[row]
        Task { await browser.enter(entry) }
    }

    @objc private func goUp() { Task { await browser.goUp() } }
    @objc private func refresh() { Task { await browser.refresh() } }
    @objc private func goToTypedPath() {
        let p = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        Task { await browser.open(p) }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { browser.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let e = browser.entries[row]
        let cell = FileTable.cell(tableView, id, owner: self)
        switch id {
        case "name": FileTable.setName(cell, e.name, isDir: e.isDir, isLink: e.isSymlink)
        case "size": cell.textField?.stringValue = Format.size(e.size, isDir: e.isDir)
        case "modified": cell.textField?.stringValue = Format.date(e.modified)
        default: cell.textField?.stringValue = Format.permissions(e.permissions)
        }
        return cell
    }

    /// Plain path (for the terminal) + an app-private type (for the local pane).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < browser.entries.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(path(row), forType: .string)
        if let data = try? JSONEncoder().encode([path(row)]) { item.setData(data, forType: FileTable.remotePathsType) }
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard browser.connection != nil, info.draggingSource as? NSTableView !== table,
              !DropPaths.read(info.draggingPasteboard).isEmpty,
              info.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)   // whole table = current folder
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let paths = DropPaths.read(info.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onUploadHere?(paths)
        return true
    }
}
