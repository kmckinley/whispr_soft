//
//  AudioDevices.swift
//  WhisprSoft
//
//  Core Audio helpers to locate the built-in microphone. AudioRecorder uses
//  `builtInInputUID()` to pin AVCaptureSession to the built-in mic via
//  AVCaptureDevice(uniqueID:), regardless of the system default input — a flaky
//  Bluetooth/HFP default (e.g. a Shokz headset) is unreliable for capture.
//

import CoreAudio

enum AudioDevices {
    /// The built-in microphone's device ID, or nil if none is found
    /// (e.g. a Mac with no built-in input).
    static func builtInInputDeviceID() -> AudioDeviceID? {
        for id in allDeviceIDs() where hasInputChannels(id) && isBuiltIn(id) {
            return id
        }
        return nil
    }

    /// The built-in input device's Core Audio UID (== AVCaptureDevice.uniqueID
    /// for audio devices), used to pin AVCaptureSession to the built-in mic.
    static func builtInInputUID() -> String? {
        guard let id = builtInInputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }

        let listPointer = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channels = listPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    private static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }
}
