import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        if CLI.wanted(CommandLine.arguments) {
            exit(CLI.run(CommandLine.arguments))
        }
        LocalhostsApp.main()
    }
}

struct LocalhostsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ServerList(store: delegate.store, pin: delegate.pin)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var pin = PinController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if Demo.isOn { return Demo.start(store: store, pin: pin) }
        #endif
        store.start()
        Installer.run()
        setUpLoginItemOnce()
        if UserDefaults.standard.bool(forKey: PinController.defaultsKey) { pin.show() }
    }

    /// Opening the app again (from Applications, Spotlight or Launchpad) shows the window, as the
    /// menu bar icon can be out of sight when the menu bar is full.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pin.show()
        return false
    }

    /// Turns "Open at login" on the first time the installed copy runs.
    private func setUpLoginItemOnce() {
        let key = "configuredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }
}
