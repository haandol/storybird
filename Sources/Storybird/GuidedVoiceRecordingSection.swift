import SwiftUI

struct GuidedVoiceRecordingSection<Recorder: VoiceSampleRecording>: View {
    @ObservedObject var recorder: Recorder
    let prompt: String
    let targetDurationDescription: String

    var body: some View {
        Section("Guided Voice Recording") {
            VStack(alignment: .leading, spacing: 16) {
                statusHeader
                promptCard
                ProgressView(
                    value: min(
                        recorder.elapsedTime
                            / VoiceRecordingRequirements.minimumDuration,
                        1
                    )
                )
                durationStatus
            }
            .padding(.vertical, 4)
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(recordingStatusColor)
                .frame(width: 10, height: 10)
            Text(recordingStatusText)
                .font(.headline)
            Spacer()
            Text(
                "\(VoiceRecordingPresentation.formattedDuration(recorder.elapsedTime)) / 00:10.0"
            )
            .font(.system(.body, design: .monospaced))
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read this script naturally")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("In a quiet room, read every word below in the voice and pace you want for your narration. Pause briefly at punctuation and keep your delivery natural.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.title3)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var durationStatus: some View {
        HStack {
            if recorder.canFinish {
                Label(
                    "Minimum reached",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Text(
                    "\(VoiceRecordingPresentation.remainingDuration(elapsed: recorder.elapsedTime), format: .number.precision(.fractionLength(1))) seconds remaining"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Target: \(targetDurationDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingStatusText: String {
        if recorder.isRecording {
            return "Recording"
        }
        if recorder.isPaused {
            return "Paused — continue when ready"
        }
        return "Recording complete"
    }

    private var recordingStatusColor: Color {
        if recorder.isRecording {
            return .red
        }
        if recorder.isPaused {
            return .orange
        }
        return .green
    }
}

struct VoiceInputWaveform: View {
    let levels: [Double]
    var height: CGFloat = 64

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                let level = levels[index]
                Capsule()
                    .fill(
                        level > 0.12
                            ? Color.accentColor
                            : Color.secondary.opacity(0.28)
                    )
                    .frame(
                        width: 5,
                        height: max(6, (height - 6) * CGFloat(level))
                    )
            }
        }
        .frame(maxWidth: .infinity, minHeight: height)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.04))
        )
        .animation(
            .linear(duration: 0.08),
            value: levels
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live microphone input level")
        .accessibilityValue(
            levels.last.map {
                "\((100 * $0).rounded()) percent"
            } ?? "0 percent"
        )
    }
}
