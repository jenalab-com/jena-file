import AppKit
import JenaFileCore
import JenaFileKit

/// Transfer status (기획서 §7.1 top right): one row per file with progress, speed,
/// time left and state. Right-click to pause / resume / cancel; failed rows retry.
final class TransferPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let list: TransferList
    private let core: Core
    private let summary = NSTextField(labelWithString: "")
    private let clear = NSButton(title: "완료 지우기", target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "전송할 파일을 파일 창 사이로 끌어다 놓으세요")

    init(list: TransferList, core: Core) {
        self.list = list
        self.core = core
        super.init(frame: .zero)
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clear.bezelStyle = .texturedRounded
        clear.controlSize = .small
        clear.target = self
        clear.action = #selector(clearFinished)
        empty.textColor = .tertiaryLabelColor

        for (id, title, width) in [("name", "파일", 190.0), ("progress", "진행", 120.0), ("speed", "속도", 80.0),
                                   ("eta", "남은 시간", 70.0), ("state", "상태", 120.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.style = .plain
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(retryClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let bar = NSStackView(views: [summary, NSView(), clear])
        for v in [bar, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        list.onChange = { [weak self] in self?.render() }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        summary.stringValue = list.items.isEmpty ? "전송" : "전송 · " + list.summary
        empty.isHidden = !list.items.isEmpty
        clear.isEnabled = list.items.contains { $0.state == .done || $0.state == .skipped || $0.state == .cancelled }
        table.reloadData()
    }

    @objc private func clearFinished() {
        core.clearFinishedTransfers()
        list.clearFinished()
    }

    // MARK: menu

    private func targets() -> [TransferInfo] {
        let clicked = table.clickedRow
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? [clicked] : Array(table.selectedRowIndexes)
        return rows.filter { $0 < list.items.count }.map { list.items[$0] }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let t = targets()
        let running = t.filter { $0.state == .running || $0.state == .queued }
        let stopped = t.filter { if case .failed = $0.state { true } else { $0.state == .paused || $0.state == .cancelled } }
        if !running.isEmpty {
            menu.addItem(withTitle: "일시정지", action: #selector(pause), keyEquivalent: "").target = self
            menu.addItem(withTitle: "취소", action: #selector(cancel), keyEquivalent: "").target = self
        }
        if !stopped.isEmpty {
            menu.addItem(withTitle: "이어서 받기 / 다시 시도", action: #selector(resume), keyEquivalent: "").target = self
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "완료 지우기", action: #selector(clearFinished), keyEquivalent: "").target = self
        }
    }

    @objc private func pause() { targets().forEach { core.pauseTransfer(transfer: $0.id) } }
    @objc private func cancel() { targets().forEach { core.cancelTransfer(transfer: $0.id) } }
    @objc private func resume() { targets().forEach { core.resumeTransfer(transfer: $0.id) } }
    @objc private func retryClicked() {
        let row = table.clickedRow
        guard row >= 0, row < list.items.count else { return }
        core.resumeTransfer(transfer: list.items[row].id)   // ignored unless paused / failed / cancelled
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { list.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < list.items.count else { return nil }
        let t = list.items[row]
        if id == "progress" {
            let cell = tableView.makeView(withIdentifier: .init(id), owner: self) as? ProgressCell ?? ProgressCell()
            cell.identifier = .init(id)
            cell.set(done: t.transferred, of: t.size)
            return cell
        }
        let cell = FileTable.cell(tableView, id == "name" ? "name" : id, owner: self)
        switch id {
        case "name":
            let name = (t.direction == .upload ? t.remotePath : t.localPath).split(separator: "/").last.map(String.init) ?? ""
            cell.textField?.stringValue = name
            cell.toolTip = t.direction == .upload ? "\(t.localPath) → \(t.remotePath)" : "\(t.remotePath) → \(t.localPath)"
            cell.imageView?.image = NSImage(systemSymbolName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
                                            accessibilityDescription: t.direction == .upload ? "업로드" : "다운로드")
            cell.imageView?.contentTintColor = t.direction == .upload ? .systemOrange : .systemGreen
        case "speed":
            cell.textField?.stringValue = t.state == .running ? Format.speed(t.bytesPerSec) : ""
        case "eta":
            cell.textField?.stringValue = t.state == .running
                ? Format.eta(remaining: t.size &- min(t.transferred, t.size), bytesPerSec: t.bytesPerSec) : ""
        default:
            cell.textField?.stringValue = Format.state(t.state)
            if case .failed(let m) = t.state { cell.toolTip = m }
            cell.textField?.textColor = {
                if case .failed = t.state { return .systemRed }
                return t.state == .done ? .secondaryLabelColor : .labelColor
            }()
        }
        return cell
    }
}

/// Progress bar + percent.
final class ProgressCell: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .right
        for v in [bar, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.widthAnchor.constraint(equalToConstant: 38),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(done: UInt64, of total: UInt64) {
        let f = total == 0 ? 1 : min(1, Double(done) / Double(total))
        bar.doubleValue = f
        label.stringValue = "\(Int(f * 100))%"
    }
}
