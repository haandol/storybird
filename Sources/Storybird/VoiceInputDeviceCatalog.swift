import CoreAudio
import Foundation

enum VoiceInputDeviceCatalog {
    /// Returns input-capable Core Audio devices sorted by their visible names.
    /// Stable UIDs are exposed because AudioObjectID values change across runs.
    static func devices() -> [VoiceInputDevice] {
        allDeviceIDs()
            .compactMap { deviceID -> VoiceInputDevice? in
                let channels = channelCount(
                    deviceID,
                    scope: kAudioObjectPropertyScopeInput
                )
                guard VoiceInputDevice.isUsableInput(
                    channelCount: channels
                ),
                let uid = stringProperty(
                    deviceID,
                    kAudioDevicePropertyDeviceUID
                ),
                let name = stringProperty(
                    deviceID,
                    kAudioObjectPropertyName
                )
                else {
                    return nil
                }
                return VoiceInputDevice(uid: uid, name: name)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    /// Resolves a stable UID to the current process-local device number.
    /// Core Audio may return success with device zero for an unknown UID.
    static func deviceID(forUID uid: String) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr else { return .zero }
        return deviceID
    }

    /// Returns the current macOS default input UID used when no device is
    /// pinned or when the pinned device is temporarily unavailable.
    static func defaultDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
        deviceID != .zero
        else {
            return nil
        }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Looks up a current display name for status text while keeping persisted
    /// settings independent from names that may change.
    static func name(forUID uid: String) -> String? {
        let deviceID = deviceID(forUID: uid)
        guard deviceID != .zero else { return nil }
        return stringProperty(deviceID, kAudioObjectPropertyName)
    }

    /// Enumerates current process-local Core Audio device numbers only for the
    /// duration of one catalog refresh.
    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0
        else {
            return []
        }
        var ids = [AudioObjectID](
            repeating: .zero,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr
        else {
            return []
        }
        return ids
    }

    /// Counts channels in the requested direction so output-only devices never
    /// enter the guided-recording microphone list.
    private static func channelCount(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0
        else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: 16
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            raw
        ) == noErr
        else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    /// Reads a retained Core Audio string property and transfers ownership
    /// safely into Swift.
    private static func stringProperty(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}
