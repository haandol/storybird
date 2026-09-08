import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: AppStore
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "#F6F5FF"),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                StorybirdMark(size: 70)

                VStack(spacing: 8) {
                    Text("Record the screen. Explain every click.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Record a screen or import an existing video, then add timed click explanations and subtitles before exporting an MP4.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        actionButtons
                    }
                    VStack(spacing: 10) {
                        actionButtons
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 26) {
                        featureNotes
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        featureNotes
                    }
                }
                .padding(.top, 12)
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: onRecord) {
            Label("Record Video", systemImage: "record.circle")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)

        Button(action: onImport) {
            Label("Import Video", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

    }

    @ViewBuilder
    private var featureNotes: some View {
        FeatureNote(icon: "video", text: "Record or import video")
        FeatureNote(icon: "cursorarrow.click", text: "Timed click highlights")
        FeatureNote(icon: "captions.bubble", text: "Editable subtitles")
        FeatureNote(icon: "lock.shield", text: "Stored only on this Mac")
    }
}

private struct FeatureNote: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
