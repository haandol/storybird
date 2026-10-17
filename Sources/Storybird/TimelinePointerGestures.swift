import AppKit
import SwiftUI

/// SwiftUI may deliver a gesture update after NSApp.currentEvent changes.
/// Recognizer modifiers preserve the actual Command/Option gesture contract.
@MainActor
enum TimelinePointerGestures {
    static func drag(minimumDistance: CGFloat = 4, updating state: GestureState<Bool>,
                     onChanged: @escaping (DragGesture.Value, NSEvent.ModifierFlags) -> Void,
                     onEnded: @escaping (DragGesture.Value, NSEvent.ModifierFlags) -> Void) -> some Gesture {
        func flags(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
            var flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if modifiers.contains(.command) { flags.insert(.command) }
            if modifiers.contains(.option) { flags.insert(.option) }
            return flags
        }
        func branch(_ modifiers: EventModifiers) -> some Gesture {
            DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named("timeline-layer-canvas"))
                .modifiers(modifiers)
                .updating(state) { _, active, _ in active = true }
                .onChanged { onChanged($0, flags(modifiers)) }
                .onEnded { onEnded($0, flags(modifiers)) }
        }
        return branch([.option, .command]).exclusively(before: branch(.option))
            .exclusively(before: branch(.command)).exclusively(before: branch([]))
    }

    static func commandTap(_ action: @escaping () -> Void) -> some Gesture {
        TapGesture().modifiers(.command).onEnded { _ in action() }
    }
}
