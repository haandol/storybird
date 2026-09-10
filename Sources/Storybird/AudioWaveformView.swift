import SwiftUI

struct AudioWaveformView: View {
    let url: URL
    var sourceStart: Double = 0
    var duration: Double?
    var sourceDuration: Double?
    @State private var levels: [Double] = []

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let total = sourceDuration ?? duration ?? 1
            let start = min(levels.count - 1, max(0, Int(sourceStart / max(total, 0.001) * Double(levels.count))))
            let end = max(start + 1, min(levels.count, Int((sourceStart + (duration ?? total)) / max(total, 0.001) * Double(levels.count))))
            let values = Array(levels[start..<end])
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) / CGFloat(max(1, values.count - 1)) * size.width
                let amplitude = max(1, min(1, value) * size.height / 2)
                path.move(to: CGPoint(x: x, y: size.height / 2 - amplitude))
                path.addLine(to: CGPoint(x: x, y: size.height / 2 + amplitude))
            }
            context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
        }
        .task(id: url) {
            levels = (try? await AudioWaveformCache.shared.summary(for: url).waveform) ?? []
        }
        .accessibilityLabel("Audio waveform")
    }
}
