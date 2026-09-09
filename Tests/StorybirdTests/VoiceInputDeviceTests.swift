import AppKit
import AudioToolbox
import AVFoundation
@testable import Storybird
import XCTest

@MainActor
final class VoiceInputDeviceTests: XCTestCase {
    private let domain = "storybird.voice-input-device.tests"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func test_preference_roundTripsStableUIDAndSystemDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))

        VoiceInputPreferences.save(
            preferredDeviceUID: "microphone-uid",
            to: defaults
        )
        XCTAssertEqual(
            VoiceInputPreferences.preferredDeviceUID(from: defaults),
            "microphone-uid"
        )

        VoiceInputPreferences.save(
            preferredDeviceUID: nil,
            to: defaults
        )
        XCTAssertNil(
            VoiceInputPreferences.preferredDeviceUID(from: defaults)
        )
    }

    func test_selection_availablePreferenceUsesPinnedDevice() {
        let selection = VoiceInputDeviceSelection.resolve(
            preferredUID: "usb",
            availableDevices: [
                VoiceInputDevice(uid: "builtin", name: "Built-in"),
                VoiceInputDevice(uid: "usb", name: "USB"),
            ],
            defaultUID: "builtin"
        )

        XCTAssertEqual(selection.preferredUID, "usb")
        XCTAssertEqual(selection.activeUID, "usb")
        XCTAssertFalse(selection.isUsingFallback)
    }

    func test_selection_missingPreferenceKeepsPinAndUsesDefault() {
        let selection = VoiceInputDeviceSelection.resolve(
            preferredUID: "unplugged",
            availableDevices: [
                VoiceInputDevice(uid: "builtin", name: "Built-in"),
            ],
            defaultUID: "builtin"
        )

        XCTAssertEqual(selection.preferredUID, "unplugged")
        XCTAssertEqual(selection.activeUID, "builtin")
        XCTAssertTrue(selection.isUsingFallback)
    }

    func test_selection_withoutPreferenceFollowsSystemDefault() {
        let selection = VoiceInputDeviceSelection.resolve(
            preferredUID: nil,
            availableDevices: [],
            defaultUID: "default"
        )

        XCTAssertNil(selection.preferredUID)
        XCTAssertEqual(selection.activeUID, "default")
        XCTAssertFalse(selection.isUsingFallback)
    }

    func test_inputCapability_rejectsOutputOnlyDevice() {
        XCTAssertFalse(
            VoiceInputDevice.isUsableInput(channelCount: 0)
        )
        XCTAssertTrue(
            VoiceInputDevice.isUsableInput(channelCount: 1)
        )
    }

    func test_pickerOptions_defaultSelectionNamesSystemDevice() {
        let options = VoiceInputDeviceOption.options(
            availableDevices: [
                VoiceInputDevice(
                    uid: "builtin",
                    name: "MacBook Pro Microphone"
                ),
                VoiceInputDevice(uid: "usb", name: "USB Microphone"),
            ],
            defaultUID: "builtin",
            preferredUID: nil
        )

        XCTAssertEqual(
            options.first,
            VoiceInputDeviceOption(
                uid: nil,
                title: "MacBook Pro Microphone (System Default)"
            )
        )
        XCTAssertFalse(options.contains { $0.title == "Follow System Default" })
        XCTAssertFalse(options.contains { $0.uid == "builtin" })
    }

    func test_pickerOptions_missingPreferenceRemainsVisible() {
        let options = VoiceInputDeviceOption.options(
            availableDevices: [
                VoiceInputDevice(
                    uid: "builtin",
                    name: "MacBook Pro Microphone"
                ),
            ],
            defaultUID: "builtin",
            preferredUID: "unplugged"
        )

        XCTAssertTrue(
            options.contains {
                $0.uid == "unplugged"
                    && $0.title == "Unavailable selected microphone"
            }
        )
    }

    func test_capturePlan_availablePinRetriesSystemDefault() {
        let selection = VoiceInputDeviceSelection(
            preferredUID: "usb",
            activeUID: "usb",
            fallbackUID: "builtin",
            isUsingFallback: false
        )
        let attempts = VoiceInputCapturePlan.deviceUIDs(for: selection)

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], "usb")
        XCTAssertEqual(attempts[1], "builtin")
    }

    func test_capturePlan_missingPinStartsWithSystemDefaultOnly() {
        let selection = VoiceInputDeviceSelection(
            preferredUID: "unplugged",
            activeUID: "builtin",
            fallbackUID: "builtin",
            isUsingFallback: true
        )
        let attempts = VoiceInputCapturePlan.deviceUIDs(for: selection)

        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0], "builtin")
    }

    func test_capturePlan_withoutDefaultDeviceHasNoImplicitAttempt() {
        let selection = VoiceInputDeviceSelection(
            preferredUID: nil,
            activeUID: nil,
            fallbackUID: nil,
            isUsingFallback: false
        )

        XCTAssertTrue(
            VoiceInputCapturePlan.deviceUIDs(for: selection).isEmpty
        )
    }

    func test_finalization_rejectsCaptureCleanedUpByMeterFailure() {
        let url = URL(fileURLWithPath: "/tmp/storybird-failed.wav")

        XCTAssertFalse(
            VoiceRecordingFinalization.canPublish(
                candidateURL: url,
                activeURL: nil,
                meteringSucceeded: false,
                hasSink: false
            )
        )
        XCTAssertTrue(
            VoiceRecordingFinalization.canPublish(
                candidateURL: url,
                activeURL: url,
                meteringSucceeded: true,
                hasSink: true
            )
        )
    }

    func test_unknownUID_resolvesToZeroDespiteCoreAudioSuccessStatus() {
        XCTAssertEqual(
            VoiceInputDeviceCatalog.deviceID(
                forUID: "NoSuchDevice-storybird-test"
            ),
            .zero
        )
    }

    func test_captureSink_deviceFormatsSaveFixed24KMonoWAV() throws {
        let formats: [(Double, AVAudioChannelCount, Bool)] = [
            (24_000, 2, true),
            (44_100, 1, false),
            (48_000, 2, false),
            (96_000, 2, false),
        ]

        for (sampleRate, channels, interleaved) in formats {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "storybird-voice-format-\(UUID().uuidString).wav"
                )
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: channels,
                    interleaved: interleaved
                )
            )
            var writer: AVAudioFile? = try VoiceCaptureSink.makeFile(
                at: url
            )
            let sink = try XCTUnwrap(
                VoiceCaptureSink(
                    file: try XCTUnwrap(writer),
                    sourceFormat: format
                )
            )
            writer = nil
            let source = try audioBuffer(
                format: format,
                duration: 0.1,
                amplitude: 0.5
            )

            for _ in 0..<5 {
                sink.consume(source)
            }
            let snapshot = sink.snapshot()
            sink.finish()

            XCTAssertNil(snapshot.failure, "\(sampleRate) Hz conversion")
            XCTAssertGreaterThan(snapshot.duration, 0)
            XCTAssertGreaterThan(snapshot.decibels, -10)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(
                file.fileFormat.streamDescription.pointee.mFormatID,
                kAudioFormatLinearPCM
            )
            XCTAssertGreaterThan(file.length, 0)
        }
    }

    func test_captureSink_rebuildsConverterWhenCallbackFormatChanges()
        throws
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "storybird-voice-format-change-\(UUID().uuidString).wav"
            )
        defer { try? FileManager.default.removeItem(at: url) }
        let formats = try [
            (48_000.0, AVAudioChannelCount(2), false),
            (44_100.0, AVAudioChannelCount(1), false),
            (96_000.0, AVAudioChannelCount(2), true),
        ].map {
            try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: $0.0,
                    channels: $0.1,
                    interleaved: $0.2
                )
            )
        }
        var writer: AVAudioFile? = try VoiceCaptureSink.makeFile(at: url)
        let sink = try XCTUnwrap(
            VoiceCaptureSink(
                file: try XCTUnwrap(writer),
                sourceFormat: formats[0]
            )
        )
        writer = nil

        for format in formats {
            sink.consume(
                try audioBuffer(
                    format: format,
                    duration: 0.1,
                    amplitude: 0.4
                )
            )
        }
        let snapshot = sink.snapshot()
        sink.finish()

        XCTAssertNil(snapshot.failure)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    /// Builds float PCM in either memory layout so conversion and metering
    /// tests reproduce the device formats that previously exposed Scribird bugs.
    private func audioBuffer(
        format: AVAudioFormat,
        duration: Double,
        amplitude: Float
    ) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frames
            )
        )
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let data = try XCTUnwrap(buffer.floatChannelData)
        if format.isInterleaved {
            for frame in 0..<Int(frames) {
                for channel in 0..<channels {
                    data[0][frame * channels + channel] = amplitude
                }
            }
        } else {
            for channel in 0..<channels {
                for frame in 0..<Int(frames) {
                    data[channel][frame] = amplitude
                }
            }
        }
        return buffer
    }
}
