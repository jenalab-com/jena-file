import AppKit
import JenaFileKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            do {
                let controller = AppController(dataDir: try AppPaths.dataDirectory().path)
                self.controller = controller
                MainMenu.install(controller: controller)
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { controller?.savePending() }
    }
}
