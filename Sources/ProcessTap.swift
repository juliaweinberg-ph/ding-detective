import AudioToolbox
import CoreAudio
import Accelerate
import os

// MARK: - CoreAudio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    static func pid(_ id: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        uint32(id, kAudioProcessPropertyIsRunningOutput) != 0
    }

    static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}

// MARK: - Level meter (written on the audio thread, read on main)

final class LevelMeter: @unchecked Sendable {
    private let peak = OSAllocatedUnfairLock(initialState: Float(0))
    func push(_ value: Float) { peak.withLock { if value > $0 { $0 = value } } }
    func take() -> Float { peak.withLock { let v = $0; $0 = 0; return v } }
}

// MARK: - Process tap
//
// Taps the audio output of specific process objects (or all output) and reports the
// peak sample level. Requires the "System Audio Recording" permission; without it the
// tap delivers silence.

final class ProcessTap {
    let meter = LevelMeter()
    private let description: CATapDescription
    private(set) var isMuted: Bool
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private static let queue = DispatchQueue(label: "ding.tap.io", qos: .userInitiated)

    /// `excluding: true` taps everything *except* the given processes.
    /// `muted: true` silences the tapped processes' output while still metering it.
    init?(processes: [AudioObjectID], excluding: Bool = false, muted: Bool = false, outputUID: String) {
        let description = excluding
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = muted ? .muted : .unmuted
        self.description = description
        self.isMuted = muted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else { return nil }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ding Detective Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg) == noErr else {
            invalidate(); return nil
        }
        aggregateID = agg

        let meter = self.meter
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, Self.queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var peak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var bufferPeak: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
                peak = max(peak, bufferPeak)
            }
            meter.push(peak)
        }
        guard status == noErr, let procID else { invalidate(); return nil }
        ioProcID = procID
        guard AudioDeviceStart(aggregateID, procID) == noErr else { invalidate(); return nil }
    }

    /// Mutes or unmutes the tapped output in place (no need to rebuild the tap).
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard muted != isMuted, tapID != kAudioObjectUnknown else { return true }
        description.muteBehavior = muted ? .muted : .unmuted
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { isMuted = muted } else { debugLog("setMuted(\(muted)) failed: \(status)") }
        return status == noErr
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}
