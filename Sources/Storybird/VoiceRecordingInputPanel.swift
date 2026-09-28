import StorybirdCore
import SwiftUI

struct VoiceRecordingInputPanel<Recorder: VoiceSampleRecording>: View {
    @ObservedObject var recorder: Recorder
    let isLocked: Bool
    let onError: (Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Microphone input level")
                Spacer()
                Text(VoiceRecordingPresentation.formattedDuration(recorder.elapsedTime))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            VoiceInputWaveform(levels: recorder.levelSamples, height: 36)
            HStack {
                Text("Recording volume")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { recorder.inputGain },
                        set: {
                            do { try recorder.setInputGain($0) }
                            catch { onError(error) }
                        }
                    ),
                    in: VoiceRecordingGain.range,
                    step: 0.1
                )
                .accessibilityLabel("Recording volume")
                .accessibilityValue("\(Int((recorder.inputGain * 100).rounded())) percent")
                .help("Adjusts new recording audio. Already recorded audio stays unchanged.")
                .disabled(isLocked || recorder.recordedURL != nil)
                Text("\(Int((recorder.inputGain * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            Text("Audio clipped. Record again with a lower volume.")
                .font(.caption)
                .foregroundStyle(.red)
                .opacity(recorder.hasClipped ? 1 : 0)
                .accessibilityHidden(!recorder.hasClipped)
        }
    }
}
