import AppKit
import JenaFileKit

/// The standard macOS menu bar plus jena-file's own items. App-specific items
/// target `controller`; standard ones (copy, minimize, quit…) go up the responder
/// chain like in any Mac app, so text fields and the terminal just work.
@MainActor
enum MainMenu {
    static func install(controller: AppController) {
        let main = NSMenu()
        let appName = "jena-file"

        // jena-file
        let app = submenu(main, appName)
        app.addItem(withTitle: L("%@ 정보", "\(appName)"), action: #selector(AppController.showAbout(_:)), keyEquivalent: "").target = controller
        app.addItem(.separator())
        app.addItem(withTitle: L("설정…"), action: #selector(AppController.showSettings(_:)), keyEquivalent: ",").target = controller
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: L("서비스"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: L("%@ 가리기", "\(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("기타 가리기"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("모두 보기"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("%@ 종료", "\(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 파일
        let file = submenu(main, L("파일"))
        file.addItem(withTitle: L("서버 관리…"), action: #selector(AppController.showServerManager(_:)), keyEquivalent: "k").target = controller
        file.addItem(withTitle: L("새 셸"), action: #selector(AppController.newShell(_:)), keyEquivalent: "t").target = controller
        file.addItem(withTitle: L("연결 끊기"), action: #selector(AppController.disconnectAll(_:)), keyEquivalent: "d")
            .apply { $0.target = controller; $0.keyEquivalentModifierMask = [.command, .shift] }
        file.addItem(.separator())
        file.addItem(withTitle: L("창 닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 편집
        let edit = submenu(main, L("편집"))
        edit.addItem(withTitle: L("실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("실행 복귀"), action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("복사하기"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 보기
        let view = submenu(main, L("보기"))
        view.addItem(withTitle: L("상태 로그 보기"), action: #selector(AppController.toggleLog(_:)), keyEquivalent: "1")
            .apply { $0.target = controller; $0.keyEquivalentModifierMask = [.command, .option] }
        view.addItem(withTitle: L("전송 로그 보기"), action: #selector(AppController.toggleTransfers(_:)), keyEquivalent: "2")
            .apply { $0.target = controller; $0.keyEquivalentModifierMask = [.command, .option] }
        view.addItem(withTitle: L("터미널 보기"), action: #selector(AppController.toggleTerminal(_:)), keyEquivalent: "3")
            .apply { $0.target = controller; $0.keyEquivalentModifierMask = [.command, .option] }
        view.addItem(.separator())
        view.addItem(withTitle: L("상태 로그에서 오류만 보기"), action: #selector(AppController.toggleErrorsOnly(_:)), keyEquivalent: "").target = controller
        view.addItem(withTitle: L("로컬 숨김 파일 보기"), action: #selector(AppController.toggleLocalHidden(_:)), keyEquivalent: ".")
            .apply { $0.target = controller; $0.keyEquivalentModifierMask = [.command, .shift] }
        view.addItem(.separator())
        view.addItem(withTitle: L("도구 막대 보기"), action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: L("전체 화면 시작"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // 윈도우
        let window = submenu(main, L("윈도우"))
        window.addItem(withTitle: L("최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("확대/축소"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("모두 앞으로 가져오기"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        // 도움말
        let help = submenu(main, L("도움말"))
        help.addItem(withTitle: L("%@ 도움말", "\(appName)"), action: #selector(AppController.openHelp(_:)), keyEquivalent: "?").target = controller
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}

extension NSMenuItem {
    @discardableResult
    func apply(_ f: (NSMenuItem) -> Void) -> NSMenuItem {
        f(self)
        return self
    }
}
