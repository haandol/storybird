import StorybirdCore
import SwiftUI

/// The same speaker and instruction inputs serve creation and regeneration.
struct CustomVoiceControls: View {
    @Binding var speaker: CustomVoiceSpeaker
    @Binding var instruct: String

    var body: some View {
        Picker("Speaker", selection: $speaker) {
            ForEach(CustomVoiceSpeaker.allCases, id: \.self) { voice in
                Text(voice.displayName).tag(voice)
            }
        }
        TextField("Voice instructions (optional)", text: $instruct, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
        Text("Describe the speaking style, emotion or pacing, for example: “Warm, calm narration with short pauses.”")
            .font(.caption).foregroundStyle(.secondary)
    }
}
