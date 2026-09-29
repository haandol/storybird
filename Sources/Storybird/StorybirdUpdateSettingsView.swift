import SwiftUI

struct StorybirdUpdateSettingsView: View {
    @ObservedObject var checker: StorybirdUpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Version \(checker.status.currentVersion ?? "Unknown") (Build \(checker.status.buildNumber ?? "Unknown"))")
                    .textSelection(.enabled)
                Spacer()
                Button("Check for Updates") { checker.startCheck() }
                    .disabled(checker.status.state == .checking)
                    .accessibilityIdentifier("checkForUpdates")
            }
            Group {
                switch checker.status.state {
                case .idle:
                    Text("Checks GitHub only when requested.")
                        .foregroundStyle(.secondary)
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking for updates…")
                    }
                case .upToDate:
                    Label("Storybird is up to date.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .updateAvailable:
                    HStack {
                        Label("Version \(checker.status.latestVersion ?? "") is available.", systemImage: "arrow.down.circle")
                        if let value = checker.status.releaseURL, let url = URL(string: value) {
                            Link("View Release", destination: url)
                        }
                    }
                case .failed:
                    Label(checker.status.error ?? "Could not check for updates.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .accessibilityIdentifier("updateCheckStatus")
        }
        .padding(.vertical, 4)
    }
}
