import AppKit
import JenaFileKit

/// 설정 (⌘,): file-transfer settings. Changes apply immediately, like macOS settings.
@MainActor
final class SettingsWindow: NSWindowController {
    private let settings: AppSettings
    private let onChange: () -> Void
    private let limit = NSStepper()
    private let limitLabel = NSTextField(labelWithString: "")
    private let conflict = NSPopUpButton()
    private let folder = NSTextField(labelWithString: "")
    private let hidden = NSButton(checkboxWithTitle: L("로컬 창에서 숨김 파일 보기"), target: nil, action: nil)

    init(settings: AppSettings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("설정")
        super.init(window: window)

        limit.minValue = 1
        limit.maxValue = 10
        limit.increment = 1
        limit.target = self
        limit.action = #selector(changed)
        conflict.addItems(withTitles: AppSettings.OnConflict.allCases.map(\.title))
        conflict.target = self
        conflict.action = #selector(changed)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.textColor = .secondaryLabelColor
        let choose = NSButton(title: L("선택…"), target: self, action: #selector(chooseFolder))
        let reset = NSButton(title: L("홈 폴더"), target: self, action: #selector(resetFolder))
        hidden.target = self
        hidden.action = #selector(changed)

        let note = NSTextField(wrappingLabelWithString: L("동시 전송 수는 서버 한 곳에 동시에 보내는 파일 수예요. 늘리면 작은 파일이 많을 때 빨라지지만, 서버 부담도 커져요."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let grid = NSGridView(views: [
            [label(L("동시 전송 수:")), NSStackView(views: [limitLabel, limit])],
            [NSGridCell.emptyContentView, note],
            [label(L("같은 이름의 파일이 있으면:")), conflict],
            [label(L("로컬 창 시작 폴더:")), NSStackView(views: [folder, choose, reset])],
            [NSGridCell.emptyContentView, hidden],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        note.widthAnchor.constraint(equalToConstant: 320).isActive = true
        folder.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let title = NSTextField(labelWithString: L("파일 전송"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [title, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.center()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func load() {
        limit.integerValue = settings.transferLimit
        limitLabel.stringValue = L("%@개", "\(settings.transferLimit)")
        conflict.selectItem(at: AppSettings.OnConflict.allCases.firstIndex(of: settings.onConflict) ?? 0)
        folder.stringValue = settings.localFolder ?? L("홈 폴더")
        hidden.state = settings.showLocalHidden ? .on : .off
    }

    /// The 보기 menu also toggles hidden files; keep the checkbox in sync.
    func reload() { load() }

    @objc private func changed() {
        settings.transferLimit = limit.integerValue
        settings.onConflict = AppSettings.OnConflict.allCases[max(conflict.indexOfSelectedItem, 0)]
        settings.showLocalHidden = hidden.state == .on
        load()
        onChange()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("선택")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.localFolder = url.path
        load()
        onChange()
    }

    @objc private func resetFolder() {
        settings.localFolder = nil
        load()
        onChange()
    }
}
