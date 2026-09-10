import StorybirdCore
import SwiftUI

struct LayerTimingPicker: View {
    @Binding var anchor: LayerSceneAnchor?
    let time: Double
    let project: DemoProject
    let onError: (Error) -> Void

    var body: some View {
        Picker("Timing", selection: Binding(
            get: { anchor == nil ? LayerTimingMode.project : .scene },
            set: { mode in
                do {
                    anchor = mode == .scene ? try SceneTiming.anchor(at: time, in: project) : nil
                } catch { onError(error) }
            }
        )) {
            Text("Follow scene").tag(LayerTimingMode.scene)
            Text("Fixed project time").tag(LayerTimingMode.project)
        }
        .padding()
    }
}
