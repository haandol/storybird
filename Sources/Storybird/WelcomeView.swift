import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: AppStore
    let onRecord: () -> Void

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
                    Text("Record clicks. Get an interactive demo.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Storybird captures the starting screen, watches each click, and turns the result into the next playable step.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }

                HStack(spacing: 12) {
                    Button(action: onRecord) {
                        Label("Record a Flow", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Button {
                        store.createSampleProject()
                    } label: {
                        Label("Explore Sample", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                HStack(spacing: 26) {
                    FeatureNote(icon: "cursorarrow.click", text: "Automatic click hotspots")
                    FeatureNote(icon: "rectangle.stack", text: "Screen after every click")
                    FeatureNote(icon: "lock.shield", text: "Stored only on this Mac")
                }
                .padding(.top, 12)
            }
            .padding(50)
        }
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
