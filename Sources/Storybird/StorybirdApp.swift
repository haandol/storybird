import SwiftUI

@main
struct StorybirdApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Demo") {
                    _ = store.createProject()
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
                    Text("Local-first interactive demos")
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

            Text("Captures and imported images remain on this Mac until you explicitly export a demo.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
