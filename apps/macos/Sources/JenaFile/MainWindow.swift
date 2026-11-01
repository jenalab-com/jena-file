import AppKit

/// Layout from 기획서 §7.1: quick-connect bar, then
/// status log | transfers, local | remote, terminal.
struct MainWindowParts {
    let quickConnect: NSView
    let log: NSView
    let remote: NSView
    let terminal: NSView
    let status: NSTextField
}

enum MainWindow {
    @MainActor
    static func make(_ parts: MainWindowParts) -> NSWindow {
        let window = MainNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "jena-file"
        window.minSize = NSSize(width: 800, height: 560)
        window.setFrameAutosaveName("MainWindow")

        let quickConnect = parts.quickConnect
        let top = horizontalSplit(boxed(parts.log), placeholder("전송 상태 (M4)"))
        let middle = horizontalSplit(placeholder("로컬 (M4)"), boxed(parts.remote))
        let terminal = boxed(parts.terminal)

        let rows = NSSplitView()
        rows.isVertical = false
        rows.dividerStyle = .thin
        [top, middle, terminal].forEach(rows.addArrangedSubview)

        let status = parts.status
        status.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        status.textColor = .secondaryLabelColor

        // Pin explicitly: the split view has no intrinsic height, so a stack
        // view would collapse it to zero.
        let content = NSView()
        for view in [quickConnect, rows, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let inset: CGFloat = 6
        NSLayoutConstraint.activate([
            quickConnect.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            quickConnect.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            quickConnect.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),

            rows.topAnchor.constraint(equalTo: quickConnect.bottomAnchor, constant: inset),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),

            status.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset + 2),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        window.contentView = content

        // Lay out now at the window's real size, then restore (or default) ratios.
        content.layoutSubtreeIfNeeded()
        let keepers = [
            (rows, SplitRatios(key: "rows", defaults: [0.2, 0.7])),
            (top, SplitRatios(key: "top", defaults: [0.5])),
            (middle, SplitRatios(key: "files", defaults: [0.5])),
        ]
        for (split, keeper) in keepers { keeper.apply(to: split) }
        window.splitKeepers = keepers.map(\.1)
        return window
    }

    @MainActor
    private static func horizontalSplit(_ left: NSView, _ right: NSView) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        return split
    }

    @MainActor
    private static func boxed(_ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 4
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let c = box.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: c.topAnchor),
                content.bottomAnchor.constraint(equalTo: c.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            ])
        }
        return box
    }

    @MainActor
    private static func placeholder(_ title: String, height: CGFloat? = nil) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 4
        box.titlePosition = .noTitle
        let label = NSTextField(labelWithString: title)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(label)
        if let content = box.contentView {
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor).isActive = true
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor).isActive = true
        }
        if let height {
            box.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return box
    }
}
