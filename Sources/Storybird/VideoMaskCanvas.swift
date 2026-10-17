import StorybirdCore
import SwiftUI

/// Last content layer in the native preview. Editor handles are drawn after it
/// but are never stored in, or rendered from, the project's effect data.
struct VideoMaskCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch Result(catching: { try MaskGeometry.layers(in: project, at: time) }) {
            case let .success(layers):
                ForEach(layers) { layer in
                    let rect = layer.pixelRect
                    if !rect.isEmpty {
                        Rectangle().fill(Color(.sRGB, red: layer.red, green: layer.green, blue: layer.blue, opacity: 1),
                            style: FillStyle(antialiased: false))
                            .frame(width: rect.width / project.canvasSize.width * imageFrame.width,
                                   height: rect.height / project.canvasSize.height * imageFrame.height)
                            .position(x: imageFrame.minX + rect.midX / project.canvasSize.width * imageFrame.width,
                                      y: imageFrame.minY + rect.midY / project.canvasSize.height * imageFrame.height)
                    }
                }
            case .failure:
                Rectangle().fill(.black).frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                Text("Mask preview unavailable").foregroundStyle(.white).padding(12)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
            }
        }.allowsHitTesting(false)
    }
}
