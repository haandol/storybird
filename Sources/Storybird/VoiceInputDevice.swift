import Foundation

struct VoiceInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }

    /// Keeps output-only hardware out of the microphone picker so every
    /// displayed device can provide at least one input channel.
    static func isUsableInput(channelCount: Int) -> Bool {
        channelCount > 0
    }
}

struct VoiceInputDeviceOption: Identifiable, Equatable, Sendable {
    let uid: String?
    let title: String

    var id: String { uid ?? "__system_default__" }

    /// Builds picker rows so the nil follow-default state names the current
    /// physical device and an unavailable persisted pin remains visible.
    static func options(
        availableDevices: [VoiceInputDevice],
        defaultUID: String?,
        preferredUID: String?
    ) -> [VoiceInputDeviceOption] {
        let defaultName = availableDevices.first {
            $0.uid == defaultUID
        }?.name
        var options = [
            VoiceInputDeviceOption(
                uid: nil,
                title: defaultName.map {
                    "\($0) (System Default)"
                } ?? "System Default"
            ),
        ]
        if let preferredUID,
           !availableDevices.contains(where: { $0.uid == preferredUID }) {
            options.append(
                VoiceInputDeviceOption(
                    uid: preferredUID,
                    title: "Unavailable selected microphone"
                )
            )
        }
        options.append(
            contentsOf: availableDevices.compactMap { device in
                guard device.uid != defaultUID
                        || preferredUID == device.uid
                else {
                    return nil
                }
                return VoiceInputDeviceOption(
                    uid: device.uid,
                    title: device.name
                )
            }
        )
        return options
    }
}

struct VoiceInputDeviceSelection: Equatable, Sendable {
    let preferredUID: String?
    let activeUID: String?
    let fallbackUID: String?
    let isUsingFallback: Bool

    /// Resolves the persisted preference without deleting it when hardware is
    /// absent, allowing the system default to cover this recording temporarily.
    static func resolve(
        preferredUID: String?,
        availableDevices: [VoiceInputDevice],
        defaultUID: String?
    ) -> VoiceInputDeviceSelection {
        guard let preferredUID else {
            return VoiceInputDeviceSelection(
                preferredUID: nil,
                activeUID: defaultUID,
                fallbackUID: defaultUID,
                isUsingFallback: false
            )
        }
        if availableDevices.contains(where: { $0.uid == preferredUID }) {
            return VoiceInputDeviceSelection(
                preferredUID: preferredUID,
                activeUID: preferredUID,
                fallbackUID: defaultUID,
                isUsingFallback: false
            )
        }
        return VoiceInputDeviceSelection(
            preferredUID: preferredUID,
            activeUID: defaultUID,
            fallbackUID: defaultUID,
            isUsingFallback: true
        )
    }
}

enum VoiceInputCapturePlan {
    /// Produces explicit device UIDs for every attempt so the system default is
    /// also fixed and verified at recording start instead of remaining implicit.
    static func deviceUIDs(
        for selection: VoiceInputDeviceSelection
    ) -> [String] {
        if selection.isUsingFallback || selection.preferredUID == nil {
            return selection.activeUID.map { [$0] } ?? []
        }
        return [selection.activeUID, selection.fallbackUID]
            .compactMap { $0 }
            .reduce(into: []) { result, uid in
                if !result.contains(uid) {
                    result.append(uid)
                }
            }
    }
}

enum VoiceInputPreferences {
    private static let preferredDeviceUIDKey = "voiceInputDeviceUID"

    /// Loads the stable device UID selected for future guided recordings.
    /// A missing value means Storybird follows the macOS default input.
    static func preferredDeviceUID(
        from defaults: UserDefaults = .standard
    ) -> String? {
        guard let uid = defaults.string(forKey: preferredDeviceUIDKey),
              !uid.isEmpty
        else {
            return nil
        }
        return uid
    }

    /// Persists a device pin or removes it when the user returns to following
    /// the system default; transient device absence never calls this method.
    static func save(
        preferredDeviceUID uid: String?,
        to defaults: UserDefaults = .standard
    ) {
        if let uid, !uid.isEmpty {
            defaults.set(uid, forKey: preferredDeviceUIDKey)
        } else {
            defaults.removeObject(forKey: preferredDeviceUIDKey)
        }
    }
}
