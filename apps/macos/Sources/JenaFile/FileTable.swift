import AppKit

/// Shared look for the local and remote file tables.
@MainActor
enum FileTable {
    /// Remote rows dragged within the app: JSON array of remote paths.
    static let remotePathsType = NSPasteboard.PasteboardType("com.jenalab.jenafile.remote-paths")

    static func addColumns(_ table: NSTableView, permissions: Bool) {
        var cols: [(String, String, CGFloat)] = [("name", "이름", 240), ("size", "크기", 80), ("modified", "수정일", 130)]
        if permissions { cols.append(("perm", "권한", 90)) }
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

    /// Path bar + table + centered message, pinned inside `view`.
    static func layout(in view: NSView, bar: [NSView], scroll: NSScrollView, overlay: NSTextField) {
        overlay.alignment = .center
        let row = NSStackView(views: bar)
        row.spacing = 4
        for v in [row, scroll, overlay] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }
}
