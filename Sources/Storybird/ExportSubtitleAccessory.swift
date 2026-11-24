import AppKit
import StorybirdCore

/// Save-panel control for the MP4's companion SRT. Rows and the default come
/// from the shared core rule so the native choice matches MCP `auto`.
@MainActor
final class ExportSubtitleAccessory {
    let view: NSView
    let popup: NSPopUpButton
    /// Popup item order; the trailing `nil` is "No SRT".
    private let scopes: [SRTCaptionScope?]

    init(project: DemoProject) {
        let options = SRTCaptions.companionOptions(for: project)
        scopes = options.map(\.scope) + [nil]
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.autoenablesItems = false
        popup.setAccessibilityIdentifier("export-subtitle-scope")
        for option in options {
            let item = NSMenuItem(title: Self.title(option), action: nil, keyEquivalent: "")
            item.isEnabled = option.isSelectable
            item.toolTip = option.unavailableReason
            popup.menu?.addItem(item)
        }
        popup.addItem(withTitle: "No SRT")
        let automatic = SRTCaptions.automaticCompanionScope(in: options)
        popup.selectItem(at: scopes.firstIndex(of: automatic) ?? scopes.count - 1)
        let label = NSTextField(labelWithString: "Subtitles (SRT):")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
    }

    var selectedScope: SRTCaptionScope? {
        scopes.indices.contains(popup.indexOfSelectedItem) ? scopes[popup.indexOfSelectedItem] : nil
    }

    private static func title(_ option: SRTCompanionOption) -> String {
        let name = switch option.scope {
        case .both: "All captions"
        case .independent: "Independent captions"
        case .cue: "Cue captions"
        }
        return option.unavailableReason == nil ? "\(name) (\(option.captionCount))"
            : "\(name) (\(option.captionCount), not SRT-compatible)"
    }
}
