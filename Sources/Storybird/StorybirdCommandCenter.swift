import AppKit
import Foundation

@MainActor
final class StorybirdCommandCenter {
    struct Handler {
        let isEnabled: @MainActor () -> Bool
        let perform: @MainActor () -> Void
    }

    private var ownerID: UUID?
    private var handlers: [StorybirdCommandAction: Handler] = [:]

    /// Installs one window's complete action surface so keyboard and menu
    /// requests use the same enabled conditions as its visible controls.
    func install(
        ownerID: UUID,
        handlers: [StorybirdCommandAction: Handler]
    ) {
        self.ownerID = ownerID
        self.handlers = handlers
    }

    /// Removes handlers only for the window that installed them, preventing an
    /// older disappearing window from clearing a newer active window's actions.
    func uninstall(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        handlers = [:]
    }

    /// Performs an action only when its current UI-equivalent availability
    /// permits it; disabled shortcut requests leave application state unchanged.
    @discardableResult
    func perform(_ action: StorybirdCommandAction) -> Bool {
        guard let handler = handlers[action], handler.isEnabled() else {
            return false
        }
        handler.perform()
        return true
    }
}

@MainActor
final class StorybirdShortcutMonitor {
    private var monitor: Any?

    /// Installs one application-local event monitor; it never observes keys
    /// while another app is active and never requests global input permission.
    init(
        settings: StorybirdShortcutSettings,
        commandCenter: StorybirdCommandCenter
    ) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak settings, weak commandCenter] event in
            guard NSApp.isActive,
                  let action = settings?.action(matching: event),
                  commandCenter?.perform(action) == true
            else {
                return event
            }
            return nil
        }
    }

}
