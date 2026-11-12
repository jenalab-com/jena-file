import AppKit
import JenaFileKit

/// 도움말 (⌘?): the user guide in a window of its own, no browser.
@MainActor
final class HelpWindow: NSWindowController {
    private let text = NSTextView()

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = L("%@ 도움말", "jena-file")
        window.minSize = NSSize(width: 420, height: 320)
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.setFrameAutosaveName("HelpWindow")
        super.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 20, height: 18)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        window.contentView = scroll
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilt on each show so the language follows the current setting.
    func show() {
        text.textStorage?.setAttributedString(Self.render(HelpContent.sections))
        text.scrollToBeginningOfDocument(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func render(_ sections: [HelpContent.Section]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 2
        let bullet = NSMutableParagraphStyle()
        bullet.paragraphSpacing = 4
        bullet.lineSpacing = 2
        bullet.headIndent = 16                                    // wrapped lines line up after "• "
        bullet.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = 14
        heading.paragraphSpacing = 6

        for (i, s) in sections.enumerated() {
            out.append(NSAttributedString(string: s.title + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: i == 0 ? 20 : 15),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: i == 0 ? paragraph : heading,
            ]))
            for line in s.lines {
                let isItem = line.hasPrefix("• ")
                let shown = isItem ? "•\t" + line.dropFirst(2) : line
                out.append(NSAttributedString(string: shown + "\n", attributes: [
                    .font: body,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: isItem ? bullet : paragraph,
                ]))
            }
        }
        return out
    }
}
