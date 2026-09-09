import SwiftUI

@main
struct StorybirdApp: App {
    @StateObject private var store: AppStore
    @StateObject private var shortcutSettings: StorybirdShortcutSettings
    private let externalControlHost: StorybirdExternalControlHost
    private let commandCenter: StorybirdCommandCenter
    private let shortcutMonitor: StorybirdShortcutMonitor

    init() {
        let store = AppStore()
        let shortcutSettings = StorybirdShortcutSettings()
        let commandCenter = StorybirdCommandCenter()
        _store = StateObject(wrappedValue: store)
        _shortcutSettings = StateObject(wrappedValue: shortcutSettings)
        externalControlHost = StorybirdExternalControlHost(store: store)
        self.commandCenter = commandCenter
        shortcutMonitor = StorybirdShortcutMonitor(
            settings: shortcutSettings,
            commandCenter: commandCenter
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                commandCenter: commandCenter
            )
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    externalControlHost.start()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording Project") {
                    commandCenter.perform(.newProject)
                }
            }
        }

        Settings {
            StorybirdSettingsView(
                store: store,
                shortcutSettings: shortcutSettings
            )
        }
    }
}
