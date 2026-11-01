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
        guard ready, let split = notification.object as? NSSplitView else { return }
        let size = total(split)
        guard size > 100 else { return }
        let ratios = split.arrangedSubviews.dropLast().map { v in
            Double((split.isVertical ? v.frame.maxX : v.frame.maxY) / size)
        }
        UserDefaults.standard.set(ratios, forKey: key)
    }
}

/// Keeps the ratio keepers alive as long as the window.
final class MainNSWindow: NSWindow {
    var splitKeepers: [SplitRatios] = []
}
