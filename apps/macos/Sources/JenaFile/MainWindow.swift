import AppKit
import JenaFileKit

/// Layout skeleton from 기획서 §7.1: quick-connect bar, then
/// status log | transfers, local | remote, terminal. Panes are placeholders until M1+.
enum MainWindow {
    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "jena-file"
        window.minSize = NSSize(width: 800, height: 560)
        window.setFrameAutosaveName("MainWindow")

        let quickConnect = placeholder("빠른 접속", height: 36)
        let top = horizontalSplit(placeholder("상태 로그"), placeholder("전송 상태"), autosave: "TopPanes")
        let middle = horizontalSplit(placeholder("로컬"), placeholder("원격"), autosave: "FilePanes")
        let terminal = placeholder("터미널")

        let rows = NSSplitView()
        rows.isVertical = false
        rows.dividerStyle = .thin
        rows.autosaveName = "MainRows"
        [top, middle, terminal].forEach(rows.addArrangedSubview)

        let status = NSTextField(labelWithString: "core \(CoreInfo.version)")
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

        // First launch only: rows 20/50/30, each pair split in half.
        // Later launches restore what the user dragged (autosaveName).
        DispatchQueue.main.async {
            if !hasSavedFrames(rows) {
                let h = rows.bounds.height
                rows.setPosition(h * 0.2, ofDividerAt: 0)
                rows.setPosition(h * 0.7, ofDividerAt: 1)
            }
            for pair in [top, middle] where !hasSavedFrames(pair) {
                pair.setPosition(pair.bounds.width * 0.5, ofDividerAt: 0)
            }
        }
        return window
    }

    @MainActor
    private static func hasSavedFrames(_ split: NSSplitView) -> Bool {
        guard let name = split.autosaveName else { return false }
        return UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil
    }

    @MainActor
    private static func horizontalSplit(_ left: NSView, _ right: NSView, autosave: String) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = autosave
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        return split
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
