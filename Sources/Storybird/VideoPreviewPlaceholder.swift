import AVFoundation
import SwiftUI

enum VideoPreviewPhase: Equatable {
    case loading
    case ready
    case empty
    case failed(String)

    static func resolve(
        isPreparing: Bool, itemStatus: AVPlayerItem.Status?,
        isReadyForDisplay: Bool, errorMessage: String?
    ) -> Self {
        if isPreparing { return .loading }
        if itemStatus == .failed { return .failed(errorMessage ?? "The video could not be loaded.") }
        if itemStatus == .readyToPlay && isReadyForDisplay { return .ready }
        if itemStatus == nil { return .empty }
        return .loading
    }
}

/// An opaque cover leaves the native player mounted so it can prepare its frame.
struct VideoPreviewPlaceholder: View {
    let phase: VideoPreviewPhase

    var body: some View {
        VStack(spacing: 10) {
            if phase == .empty {
                Image(systemName: "video").font(.title2)
                Text("No video clips to preview").font(.callout)
            } else if case let .failed(message) = phase {
                Image(systemName: "video.slash").font(.title2)
                Text("Preview unavailable").font(.callout)
                Text(message).font(.caption).lineLimit(3).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading preview…").font(.callout)
            }
        }
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("video-preview-placeholder")
        .allowsHitTesting(false)
    }
}
