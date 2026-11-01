import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            do {
                let controller = try AppController()
                self.controller = controller
                NSApp.activate(ignoringOtherApps: true)
                controller.window.center()
                controller.window.makeKeyAndOrderFront(nil)
                controller.applyDevAutoConnect()
            } catch {
                NSAlert(error: error).runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
