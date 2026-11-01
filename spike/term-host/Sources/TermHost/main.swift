import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "jena-file · SwiftTerm 한글 입력 시험"
        let term = LocalProcessTerminalView(frame: window.contentView!.bounds)
        term.autoresizingMask = [.width, .height]
        term.processDelegate = self
        window.contentView!.addSubview(term)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=ko_KR.UTF-8")
        term.startProcess(executable: "/bin/zsh", args: ["-l"], environment: env, execName: "-zsh")

        // Experiment for "first Korean input arrives as loose jamo":
        // activate the app and make the window key *before* focusing the
        // terminal, then focus on the next runloop turn so the text input
        // context is attached to an active, key window.
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            self.window.makeFirstResponder(term)
            term.inputContext?.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { window.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
