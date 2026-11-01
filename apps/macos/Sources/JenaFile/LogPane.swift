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

    private var lines: [(time: Date, message: String, tone: Tone)] = []
    /// 보기 > 상태 로그에서 오류만 보기 (FR-50).
    var errorsOnly = false {
        didSet { redraw() }
    }

    func append(_ message: String, tone: Tone = .info) {
        let entry = (Date(), message, tone)
        lines.append(entry)
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
        if !errorsOnly || tone != .info {
            text.textStorage?.append(render(entry))
            text.scrollToEndOfDocument(nil)
        }
    }

    private func render(_ e: (time: Date, message: String, tone: Tone)) -> NSAttributedString {
        let color: NSColor = switch e.tone {
        case .info: .labelColor
        case .warn: .systemOrange
        case .error: .systemRed
        }
        return NSAttributedString(string: "\(timeFormat.string(from: e.time))  \(e.message)\n",
                                  attributes: [.font: text.font!, .foregroundColor: color])
    }

    private func redraw() {
        let all = NSMutableAttributedString()
        for e in lines where !errorsOnly || e.tone != .info { all.append(render(e)) }
        text.textStorage?.setAttributedString(all)
        text.scrollToEndOfDocument(nil)
    }
}
