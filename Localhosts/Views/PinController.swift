import AppKit
import Observation
import SwiftUI

/// The "pin to desktop" window: a small floating panel holding the same list as the menu.
@MainActor @Observable
final class PinController: NSObject, NSWindowDelegate {
    static let defaultsKey = "pinned"
    private static let frameName = "LocalhostsPinnedPanel"

    private(set) var isPinned = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var panel: NSPanel?
    /// The top edge stays put while the window grows and shrinks with the list.
    @ObservationIgnored private var anchoredTop: CGFloat?

    @ObservationIgnored private var terminating = false

    init(store: Store) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminating = true }
        }
    }

    func toggle() {
        isPinned ? hide() : show()
    }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        setPinned(true)
    }

    func hide() {
        panel?.orderOut(nil)
        setPinned(false)
    }

    #if DEBUG
    /// Shows the panel at a fixed spot without saving its position or the pin (see Demo).
    func showForDemo(topLeft: NSPoint) {
        if panel == nil { panel = makePanel(remembersFrame: false) }
        panel?.setFrameTopLeftPoint(topLeft)
        anchoredTop = topLeft.y
        panel?.orderFrontRegardless()
        isPinned = true
    }
    #endif

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { anchoredTop = panel?.frame.maxY }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let panel, let top = anchoredTop, abs(panel.frame.maxY - top) > 0.5 else { return }
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
    }

    /// Closing the window (⌘W) unpins it; quitting the app leaves the pin for next launch.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !terminating else { return }
            setPinned(false)
        }
    }

    private func setPinned(_ value: Bool) {
        isPinned = value
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
    }

    private func makePanel(remembersFrame: Bool = true) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Localhosts"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // The window takes the list's own size, so it grows and shrinks as servers come and go.
        let hosting = NSHostingView(rootView: ServerList(store: store, pin: self))
        hosting.sizingOptions = [.intrinsicContentSize]
        // The list draws under the (hidden) title bar instead of leaving room for it.
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        guard remembersFrame else { return panel }
        if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        panel.setFrameAutosaveName(Self.frameName)
        anchoredTop = panel.frame.maxY
        return panel
    }
}
