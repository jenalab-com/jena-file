import AppKit
import JenaFileCore
import JenaFileKit

/// Remote file pane: path bar + table, with loading / empty / error / disconnected
/// states (기획서 §7.3). Double-click a folder to enter it.
final class RemotePane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let browser: RemoteBrowser
    private let pathField = NSTextField()
    private let upButton = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "상위 폴더")!, target: nil, action: nil)
    private let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "새로 고침")!, target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let overlay = NSTextField(wrappingLabelWithString: "")
    /// "여기서 터미널 열기" (FR-33): folder to cd into.
    var onOpenTerminal: ((String) -> Void)?
    /// "경로를 터미널에 넣기": shell-quoted paths.
    var onInsertPaths: (([String]) -> Void)?

    init(browser: RemoteBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        build()
        browser.onChange = { [weak self] in self?.render() }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        pathField.placeholderString = "원격 경로"
        pathField.target = self
        pathField.action = #selector(goToTypedPath)
        for b in [upButton, refreshButton] { b.bezelStyle = .texturedRounded; b.target = self }
        upButton.action = #selector(goUp)
        refreshButton.action = #selector(refresh)

        for (id, title, width) in [("name", "이름", 260.0), ("size", "크기", 80.0), ("modified", "수정일", 130.0), ("perm", "권한", 90.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(openSelected)
        table.target = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.menu = contextMenu()
        table.style = .plain
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        overlay.alignment = .center
        overlay.textColor = .secondaryLabelColor

        let bar = NSStackView(views: [upButton, pathField, refreshButton])
        bar.spacing = 4
        for v in [bar, scroll, overlay] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }

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

    // MARK: context menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
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

    @objc private func openTerminalHere() {
        guard browser.connection != nil else { return }
        let folder = targetRows().map { browser.entries[$0] }.first { $0.isDir }
        onOpenTerminal?(folder.map { RemotePath.join(browser.path, $0.name) } ?? browser.path)
    }

    @objc private func insertPaths() {
        let rows = targetRows()
        let paths = rows.isEmpty ? [browser.path] : rows.map { RemotePath.join(browser.path, browser.entries[$0].name) }
        onInsertPaths?(paths)
    }

    // MARK: table

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < browser.entries.count else { return nil }
        return RemotePath.join(browser.path, browser.entries[row].name) as NSString
    }

    func numberOfRows(in tableView: NSTableView) -> Int { browser.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let e = browser.entries[row]
        let cell = tableView.makeView(withIdentifier: .init(id), owner: self) as? NSTableCellView ?? makeCell(id)
        switch id {
        case "name":
            cell.textField?.stringValue = e.name
            cell.imageView?.image = NSImage(systemSymbolName: e.isDir ? "folder.fill" : (e.isSymlink ? "arrow.up.right.square" : "doc"),
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = e.isDir ? .systemBlue : .secondaryLabelColor
        case "size": cell.textField?.stringValue = Format.size(e.size, isDir: e.isDir)
        case "modified": cell.textField?.stringValue = Format.date(e.modified)
        default: cell.textField?.stringValue = Format.permissions(e.permissions)
        }
        return cell
    }

    private func makeCell(_ id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init(id)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        }
        if id == "size" { text.alignment = .right }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
