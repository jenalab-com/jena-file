import AppKit
import JenaFileKit

/// Shared look for the local and remote file tables.
@MainActor
enum FileTable {
    /// Remote rows dragged within the app: JSON array of remote paths.
    static let remotePathsType = NSPasteboard.PasteboardType("com.jenalab.jenafile.remote-paths")

    static func addColumns(_ table: NSTableView, permissions: Bool) {
        var cols: [(String, String, CGFloat)] = [("name", L("이름"), 240), ("size", L("크기"), 80), ("modified", L("수정일"), 130)]
        if permissions { cols.append(("perm", L("권한"), 90)) }
        for (id, title, width) in cols {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.style = .plain
    }

    static func cell(_ table: NSTableView, _ id: String, owner: Any?) -> NSTableCellView {
        if let c = table.makeView(withIdentifier: .init(id), owner: owner) as? NSTableCellView { return c }
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

    static func setName(_ cell: NSTableCellView, _ name: String, isDir: Bool, isLink: Bool = false) {
        cell.textField?.stringValue = name
        cell.imageView?.image = NSImage(systemSymbolName: isDir ? "folder.fill" : (isLink ? "arrow.up.right.square" : "doc"),
                                        accessibilityDescription: nil)
        cell.imageView?.contentTintColor = isDir ? .systemBlue : .secondaryLabelColor
    }

    static func button(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.bezelStyle = .texturedRounded
        b.toolTip = label
        return b
    }

    /// Path bar, then the folder tree above the file list (FileZilla), with a
    /// centered message over the list. Returns the tree | list split.
    @discardableResult
    static func layout(in view: NSView, bar: [NSView], tree: NSView, scroll: NSScrollView, overlay: NSTextField) -> NSSplitView {
        overlay.alignment = .center
        let row = NSStackView(views: bar)
        row.spacing = 4
        row.setHuggingPriority(.defaultHigh, for: .vertical)   // the split, not the bar, takes the height
        let list = NSView()
        for v in [scroll, overlay] {
            v.translatesAutoresizingMaskIntoConstraints = false
            list.addSubview(v)
        }
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tree)
        split.addArrangedSubview(list)
        // Don't let the tree | list split pull the whole pane short in the window's rows.
        split.setContentHuggingPriority(.init(1), for: .vertical)
        split.setHoldingPriority(.init(200), forSubviewAt: 0)   // the list grows and shrinks, the tree keeps its height
        split.setHoldingPriority(.init(1), forSubviewAt: 1)
        for v in [row, split] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            split.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: list.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            overlay.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        return split
    }

    /// 이름 복사 · 상대 경로 복사 · 절대 경로 복사 · 이름 바꾸기… — same order in every menu.
    static func addPathItems(to menu: NSMenu, target: AnyObject, copy: Selector, rename: Selector) {
        for (title, kind) in [(L("이름 복사"), 0), (L("상대 경로 복사"), 1), (L("절대 경로 복사"), 2)] {
            let item = menu.addItem(withTitle: title, action: copy, keyEquivalent: "")
            item.target = target
            item.tag = kind
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("이름 바꾸기…"), action: rename, keyEquivalent: "").target = target
    }

    static func copyKind(_ tag: Int) -> PathText.Kind {
        switch tag {
        case 0: .name
        case 1: .relative
        default: .absolute
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func showError(_ message: String, in window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    /// Asks for a new name; a file's name is pre-selected without its extension (like Finder).
    static func askNewName(in window: NSWindow?, current: String, isDir: Bool, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("이름 바꾸기")
        alert.informativeText = L("\"%@\"의 새 이름", current)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("바꾸기"))
        alert.addButton(withTitle: L("취소"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            done(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
        DispatchQueue.main.async {
            let name = current as NSString
            let base = name.deletingPathExtension as NSString
            let length = isDir || base.length == 0 ? name.length : base.length
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        }
    }
}
