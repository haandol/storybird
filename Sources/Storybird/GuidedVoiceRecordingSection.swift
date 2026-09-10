import AppKit
import SwiftUI

struct GuidedVoiceRecordingSection<Recorder: VoiceSampleRecording>: View {
    @ObservedObject var recorder: Recorder
    let prompt: String
    let isWorking: Bool
    let onRestart: () -> Void
    let onError: (Error) -> Void

    var body: some View {
        Section("Guided Voice Recording") {
            VStack(alignment: .leading, spacing: 16) {
                statusHeader
                promptCard
                VoiceInputWaveform(levels: recorder.levelSamples)
                ProgressView(
                    value: min(
                        recorder.elapsedTime
                            / VoiceRecordingRequirements.minimumDuration,
                        1
                    )
                )
                durationStatus
                recordingControls
                    .disabled(isWorking)
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
            Text("Target: 10–15 seconds")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if recorder.isRecording {
            HStack {
                Button("Pause") {
                    recorder.pause()
                }
                Button("Finish Recording") {
                    recorder.finish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.canFinish)
            }
        } else if recorder.isPaused {
            HStack {
                Button("Resume") {
                    do {
                        try recorder.resume()
                    } catch {
                        onError(error)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Finish Recording") {
                    recorder.finish()
                }
                .disabled(!recorder.canFinish)
                Button("Record Again", role: .destructive) {
                    onRestart()
                }
            }
        } else if let recordedURL = recorder.recordedURL {
            HStack {
                Button("Preview Recording") {
                    NSWorkspace.shared.open(recordedURL)
                }
                Button("Record Again") {
                    onRestart()
                }
            }
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

private struct VoiceInputWaveform: View {
    let levels: [Double]

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
                        height: max(6, 58 * level)
                    )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
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
