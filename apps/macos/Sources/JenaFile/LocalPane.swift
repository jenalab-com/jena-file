import AppKit
import JenaFileKit

/// Left pane: this Mac. Drag rows to the remote pane to upload; drop remote rows
/// here to download into the shown folder.
final class LocalPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let browser: LocalBrowser
    private let pathField = NSTextField()
    private let upButton = FileTable.button("arrow.up", L("상위 폴더"))
    private let homeButton = FileTable.button("house", L("홈 폴더"))
    private let refreshButton = FileTable.button("arrow.clockwise", L("새로 고침"))
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let overlay = NSTextField(wrappingLabelWithString: "")
    /// Selected local paths → upload into the remote pane's folder.
    var onUpload: (([String]) -> Void)?
    /// Remote paths dropped here → download into `browser.path`.
    var onDownloadHere: (([String]) -> Void)?

    init(browser: LocalBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        pathField.placeholderString = L("로컬 경로")
        pathField.target = self
        pathField.action = #selector(goToTypedPath)
        for (b, sel) in [(upButton, #selector(goUp)), (homeButton, #selector(goHome)), (refreshButton, #selector(refresh))] {
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
            m.addItem(withTitle: L("숨김 파일 보기"), action: #selector(toggleHidden), keyEquivalent: "").target = self
            return m
        }()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        FileTable.layout(in: self, bar: [upButton, homeButton, pathField, refreshButton], scroll: scroll, overlay: overlay)
        browser.onChange = { [weak self] in self?.render() }
        browser.refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        pathField.stringValue = browser.path
        table.reloadData()
        switch browser.state {
        case .loaded:
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

    @objc private func openSelected() {
        let row = table.clickedRow
        guard row >= 0, row < browser.entries.count else { return }
        browser.enter(browser.entries[row])
    }

    @objc private func goUp() { browser.goUp() }
    @objc private func goHome() { browser.open(FileManager.default.homeDirectoryForCurrentUser.path) }
    @objc private func refresh() { browser.refresh() }
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
