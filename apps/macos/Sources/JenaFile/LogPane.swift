import AppKit

/// Status log (기획서 FR-50). Never shows secrets: the core never logs them.
final class LogPane: NSScrollView {
    private let text = NSTextView()
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        borderType = .noBorder
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.autoresizingMask = [.width]
        documentView = text
    }

    required init?(coder: NSCoder) { fatalError() }

    enum Tone { case info, warn, error }

    func append(_ message: String, tone: Tone = .info) {
        let color: NSColor = switch tone {
        case .info: .labelColor
        case .warn: .systemOrange
        case .error: .systemRed
        }
        let line = NSAttributedString(
            string: "\(timeFormat.string(from: Date()))  \(message)\n",
            attributes: [.font: text.font!, .foregroundColor: color])
        text.textStorage?.append(line)
        text.scrollToEndOfDocument(nil)
    }
}
