import SwiftUI

@main
struct StorybirdApp: App {
    @StateObject private var store: AppStore
    private let externalControlHost: StorybirdExternalControlHost

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        externalControlHost = StorybirdExternalControlHost(store: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
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
                    _ = store.createProject(name: "Untitled recording")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 460, height: 250)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StorybirdMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storybird")
                        .font(.title2.weight(.semibold))
                    Text("Local-first screen videos")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("Project storage") {
                Text(store.repository.rootURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text("Original recordings and timeline layers remain on this Mac until you explicitly export a video.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
