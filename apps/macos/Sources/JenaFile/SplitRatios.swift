import AppKit

/// Remembers divider positions as fractions and restores them after layout.
/// NSSplitView's own autosave restored frames while the view was still zero-sized
/// and then saved the collapsed result, so we do it ourselves.
@MainActor
final class SplitRatios: NSObject, NSSplitViewDelegate {
    private let key: String
    private let defaults: [CGFloat]
    private var ready = false

    init(key: String, defaults: [CGFloat]) {
        self.key = "SplitRatios.\(key)"
        self.defaults = defaults
    }

    private func total(_ split: NSSplitView) -> CGFloat {
        split.isVertical ? split.bounds.width : split.bounds.height
    }

    /// Call once the split view has its real size.
    func apply(to split: NSSplitView) {
        split.delegate = self
        let stored = UserDefaults.standard.array(forKey: key) as? [Double]
        let ratios = stored.map { $0.map { CGFloat($0) } }.flatMap { $0.count == defaults.count ? $0 : nil } ?? defaults
        let size = total(split)
        for (i, r) in ratios.enumerated() {
            split.setPosition(size * min(max(r, 0.05), 0.95), ofDividerAt: i)
        }
        ready = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard ready, let split = notification.object as? NSSplitView,
              !split.arrangedSubviews.contains(where: \.isHidden) else { return }   // a pane is turned off in 보기
        let size = total(split)
        guard size > 100 else { return }
        let ratios = split.arrangedSubviews.dropLast().map { v in
            Double((split.isVertical ? v.frame.maxX : v.frame.maxY) / size)
        }
        UserDefaults.standard.set(ratios, forKey: key)
    }
}

/// Keeps the layout (and its ratio keepers) alive as long as the window.
final class MainNSWindow: NSWindow {
    var layout: MainLayout?
}

/// Panes the 보기 menu can turn off (기획서 §7.1).
enum Pane {
    case log, transfers, terminal
}

/// Shows / hides panes. NSSplitView collapses hidden arranged subviews; the top
/// row disappears when both of its panes are off.
@MainActor
final class MainLayout {
    let rows: NSSplitView
    let top: NSSplitView
    let keepers: [(NSSplitView, SplitRatios)]
    private let log: NSView
    private let transfers: NSView
    private let terminal: NSView

    init(rows: NSSplitView, top: NSSplitView, keepers: [(NSSplitView, SplitRatios)]) {
        self.rows = rows
        self.top = top
        self.keepers = keepers
        log = top.arrangedSubviews[0]
        transfers = top.arrangedSubviews[1]
        terminal = rows.arrangedSubviews[2]
    }

    func isVisible(_ pane: Pane) -> Bool { !view(pane).isHidden }

    func setVisible(_ pane: Pane, _ visible: Bool) {
        view(pane).isHidden = !visible
        top.isHidden = log.isHidden && transfers.isHidden
        for split in [top, rows] { split.adjustSubviews() }
        // Re-apply saved ratios once everything in a split is visible again.
        for (split, keeper) in keepers where !split.arrangedSubviews.contains(where: \.isHidden) {
            split.layoutSubtreeIfNeeded()
            keeper.apply(to: split)
        }
    }

    private func view(_ pane: Pane) -> NSView {
        switch pane {
        case .log: log
        case .transfers: transfers
        case .terminal: terminal
        }
    }
}
