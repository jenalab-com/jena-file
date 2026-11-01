import AppKit
import JenaFileCore
import JenaFileKit
import SwiftTerm

/// Bottom terminal area: tabs of shells, each on some connection's SSH session
/// (FR-30) — a bastion and the servers behind it can sit side by side.
/// Dropping a path (or a remote file row) types it, shell-quoted (FR-33).
@MainActor
final class TerminalPane: NSView {
    private let core: Core
    private let tabs = NSTabView()
    private let header = NSTextField(labelWithString: "")
    private let newTab = NSButton(title: "새 셸", target: nil, action: nil)
    private let openInternal = NSButton(title: "내부 서버 열기…", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "서버에 접속하면 여기서 셸을 쓸 수 있어요")
    /// Open connections and their tab titles. `active` gets new shells.
    private var titles: [UInt64: String] = [:]
    private(set) var active: UInt64?
    private var sessions: [(connection: UInt64, session: TerminalSession)] = []
    private var counters: [UInt64: Int] = [:]
    /// FR-21: open a server behind the connection of the visible tab.
    var onOpenInternal: ((UInt64) -> Void)?

    init(core: Core) {
        self.core = core
        super.init(frame: .zero)
        header.textColor = .secondaryLabelColor
        for (b, symbol) in [(newTab, "plus"), (openInternal, "arrow.turn.down.right")] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.bezelStyle = .texturedRounded
            b.target = self
        }
        newTab.action = #selector(openNewTab)
        openInternal.action = #selector(openInternalServer)
        openInternal.toolTip = "이 셸의 서버를 bastion으로 삼아 내부 서버에 접속해요 (bastion 재인증 없음)"
        empty.textColor = .tertiaryLabelColor
        tabs.tabViewType = .topTabsBezelBorder

        let bar = NSStackView(views: [header, NSView(), openInternal, newTab])
        for v in [bar, tabs, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            tabs.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tabs.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Start over (new quick connect): drop every tab.
    func reset() {
        sessions.forEach { $0.session.close() }
        sessions.removeAll()
        tabs.tabViewItems.forEach(tabs.removeTabViewItem)
        titles.removeAll()
        counters.removeAll()
        active = nil
        render()
    }

    /// Registers a connection. `makeActive` routes "새 셸" and the remote pane's
    /// "여기서 터미널 열기" to it. Opens a first shell unless `openShell` is false.
    func connected(_ id: UInt64, title: String, makeActive: Bool = true, openShell: Bool = true) {
        titles[id] = title
        if makeActive { active = id }
        if openShell { open(on: id, startDir: nil) }
        render()
    }

    /// Keeps tab contents visible but read-only (기획서 §7.3 "연결 끊김").
    func disconnected(_ id: UInt64) {
        titles[id] = nil
        if active == id { active = nil }
        sessions.filter { $0.connection == id }.forEach { $0.session.markEnded("연결이 끊겼어요") }
        render()
    }

    func open(startDir: String?) {
        guard let active else { return }
        open(on: active, startDir: startDir)
    }

    func open(on connection: UInt64, startDir: String?) {
        guard let title = titles[connection] else { return }
        let n = (counters[connection] ?? 0) + 1
        counters[connection] = n
        let session = TerminalSession(core: core)
        session.onEnded = { [weak self] in self?.render() }
        sessions.append((connection, session))
        let item = NSTabViewItem(identifier: session)
        item.label = n == 1 ? title : "\(title) #\(n)"
        item.view = session.host
        tabs.addTabViewItem(item)
        tabs.selectTabViewItem(item)
        render()
        session.start(connection: connection, startDir: startDir)
    }

    /// Types `text` into the visible shell (no Enter).
    func insert(_ text: String) {
        guard let s = tabs.selectedTabViewItem?.identifier as? TerminalSession else { return }
        s.type(text)
        s.focus()
    }

    /// Connection of the visible tab, if it is still open.
    private var visibleConnection: UInt64? {
        guard let s = tabs.selectedTabViewItem?.identifier as? TerminalSession,
              let c = sessions.first(where: { $0.session === s })?.connection,
              titles[c] != nil else { return active }
        return c
    }

    @objc private func openNewTab() {
        if let c = visibleConnection { open(on: c, startDir: nil) }
    }

    @objc private func openInternalServer() {
        if let c = visibleConnection { onOpenInternal?(c) }
    }

    private func render() {
        let names = Set(titles.values)
        header.stringValue = names.isEmpty ? "터미널" : "터미널 · " + names.sorted().joined(separator: ", ")
        newTab.isEnabled = !titles.isEmpty
        openInternal.isEnabled = !titles.isEmpty
        let hasTabs = !tabs.tabViewItems.isEmpty
        tabs.isHidden = !hasTabs
        empty.isHidden = hasTabs
    }
}

/// One shell: SwiftTerm view <-> core terminal channel.
@MainActor
final class TerminalSession: NSObject, TerminalViewDelegate {
    let host = TerminalDropHost()
    private let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    private let core: Core
    private let output = TerminalOutput()
    private var terminal: UInt64?
    private var ended = false
    var onEnded: (() -> Void)?

    init(core: Core) {
        self.core = core
        super.init()
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.onDropText = { [weak self] text in self?.type(text); self?.focus() }
        output.view = view
        output.onClosed = { [weak self] status in
            self?.markEnded(status.map { "셸이 종료됐어요 (exit \($0))" } ?? "셸이 종료됐어요")
        }
    }

    func start(connection: UInt64, startDir: String?) {
        host.layoutSubtreeIfNeeded()
        let size = view.terminalDimensions
        Task {
            do {
                terminal = try await core.openTerminal(connection: connection, cols: UInt32(size.cols),
                                                       rows: UInt32(size.rows), startDir: startDir,
                                                       lang: TerminalLocale.lang, sink: output)
                focus()
            } catch {
                markEnded(UserMessage.describe(error))
            }
        }
    }

    func type(_ text: String) {
        guard let terminal, !ended else { return }
        core.terminalWrite(terminal: terminal, data: Data(text.utf8))
    }

    /// Same order the Korean-input spike needed: window key first, then focus
    /// on the next turn with the input context activated.
    func focus() {
        DispatchQueue.main.async { [view] in
            view.window?.makeFirstResponder(view)
            view.inputContext?.activate()
        }
    }

    func markEnded(_ message: String) {
        guard !ended else { return }
        ended = true
        view.feed(text: "\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n")
        onEnded?()
    }

    func close() {
        if let terminal { core.closeTerminal(terminal: terminal) }
        ended = true
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard let terminal, !ended else { return }
            core.terminalWrite(terminal: terminal, data: Data(data))
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let terminal, !ended else { return }
            core.terminalResize(terminal: terminal, cols: UInt32(newCols), rows: UInt32(newRows))
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    nonisolated func bell(source: TerminalView) { NSSound.beep() }
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Receives shell output on tokio threads and feeds the view on the main thread.
final class TerminalOutput: TerminalSink, @unchecked Sendable {
    @MainActor weak var view: TerminalView?
    @MainActor var onClosed: ((UInt32?) -> Void)?

    func onOutput(data: Data) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.view?.feed(byteArray: ArraySlice(data)) }
        }
    }

    func onClosed(exitStatus: UInt32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onClosed?(exitStatus) }
        }
    }
}

/// SwiftTerm's view does not accept drops; its container does (FR-33).
final class TerminalDropHost: NSView {
    var onDropText: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DropPaths.read(sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onDropText?(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
        return true
    }
}
