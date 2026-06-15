//
//  AudioRecorder.swift
//  WhisprSoft
//
//  Real microphone capture built on AVCaptureSession + AVCaptureAudioDataOutput.
//  Produces 16 kHz mono Float32 PCM (the Whisper convention) by resampling the
//  delivered CMSampleBuffers with AVAudioConverter.
//
//  Why AVCaptureSession (not AVAudioEngine): AVAudioEngine's input path proved
//  fragile around device/format control — it gave us the 0-callbacks pull bug,
//  the Bluetooth IO failure, and -10875 (kAudioUnitErr_FailedInitialization)
//  when we pinned the input device. AVCaptureSession selects a specific device
//  reliably (via AVCaptureDevice(uniqueID:)) and doesn't hit those failures.
//
//  Concurrency: the sample-buffer delegate runs on `captureQueue`, not the main
//  actor, so this type is `nonisolated` and the accumulation buffer is guarded
//  by a lock. A nonisolated witness satisfies the MainActor-isolated
//  `AudioRecording` requirement (the permissive direction), so the Coordinator
//  calls it exactly like the stub. `@unchecked Sendable` is honest: AVCapture*
//  isn't Sendable; safety rests on (1) start()/stop() never running concurrently
//  — the Coordinator's state-machine guards guarantee this (beginDictation only
//  starts from `.idle`; endDictation claims `.transcribing` synchronously before
//  awaiting stop(), so a second chord-up can't re-enter) — and (2) the delegate
//  touching only the lock-guarded `samples`/`callbackCount` and the
//  captureQueue-confined `converter`/`buildFailed`/`targetFormat` (all set in
//  start() before startRunning(), then read only on the serial captureQueue),
//  never the `session`.
//

import AVFoundation
import CoreMedia
import os

nonisolated final class AudioRecorder: NSObject, AudioRecording,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Whisper expects 16 kHz mono.
    private let targetSampleRate = 16_000.0

    /// Serial queue the sample-buffer delegate is delivered on.
    private let captureQueue = DispatchQueue(label: "com.whisprsoft.capture")

    // Touched only in start()/stop(), which never overlap (Coordinator's
    // beginDictation/endDictation state guards).
    private var session: AVCaptureSession?

    // Shared with the capture queue — guarded by `lock`.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var callbackCount = 0

    // Touched only on captureQueue: reset in start() before startRunning(), then
    // read/written exclusively by the (serial) delegate. The converter is built
    // lazily on the first sample buffer, from that buffer's *actual* format — a
    // format read divorced from the delivered buffer can mismatch and fail.
    private var converter: AVAudioConverter?
    private var buildFailed = false
    private var targetFormat: AVAudioFormat?

    /// Trivial by design: no device/session access until start(), so the app
    /// touches no microphone hardware at launch when the Coordinator (and thus
    /// this recorder) is constructed.
    override init() { super.init() }

    func start() throws {
        // Fresh per-run state.
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            callbackCount = 0
        }
        converter = nil
        buildFailed = false

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.capture.notice("AudioRecorder: mic authorization = \(auth.rawValue, privacy: .public) (\(Self.authName(auth), privacy: .public))")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatUnavailable
        }
        self.targetFormat = targetFormat

        // Pin the built-in mic by its Core Audio UID; fall back to the system
        // default if no built-in is found. AVCaptureDevice(uniqueID:) selects a
        // specific device reliably — the whole reason for this pivot.
        let device: AVCaptureDevice
        if let uid = AudioDevices.builtInInputUID(),
           let builtIn = AVCaptureDevice(uniqueID: uid) {
            device = builtIn
            Log.capture.notice("AudioRecorder: using built-in input \"\(device.localizedName, privacy: .public)\" (uid \(uid, privacy: .public))")
        } else if let fallback = AVCaptureDevice.default(for: .audio) {
            device = fallback
            Log.capture.notice("AudioRecorder: no built-in input found; using default \"\(device.localizedName, privacy: .public)\"")
        } else {
            throw AudioRecorderError.noInputDevice
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioRecorderError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        self.session = session

        // Blocking call; runs synchronously here. beginDictation stays
        // synchronous (the Coordinator relies on that) and this is fast enough
        // for a hold-to-talk tool.
        session.startRunning()
        Log.capture.notice("AudioRecorder: capture session started ok")
    }

    func stop() async -> RecordedAudio {
        session?.stopRunning()
        session = nil

        // Drain any in-flight delegate block. stopRunning() stops new buffers but
        // doesn't guarantee an already-dispatched callback has finished; this
        // barrier ensures the captured samples are complete AND that no trailing
        // run-N callback survives to race run N+1's start() resetting the
        // captureQueue-confined converter/buildFailed/targetFormat.
        captureQueue.sync { }

        let (captured, callbacks) = lock.withLock { (samples, callbackCount) }

        let peak = captured.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        let duration = Double(captured.count) / targetSampleRate
        Log.capture.notice("AudioRecorder: \(callbacks, privacy: .public) callbacks, \(captured.count, privacy: .public) samples, \(duration, format: .fixed(precision: 2), privacy: .public)s @16kHz, peak \(peak, format: .fixed(precision: 2), privacy: .public)")

        return RecordedAudio(samples: captured, sampleRate: targetSampleRate)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (captureQueue)

    /// Runs on the serial `captureQueue`. Extracts the buffer's PCM into an
    /// AVAudioPCMBuffer of its own format, builds the converter lazily from that
    /// format, resamples to 16 kHz mono, and appends under the lock.
    @objc
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Count this callback; log details of the first one.
        let isFirst = lock.withLock { () -> Bool in
            let first = callbackCount == 0
            callbackCount += 1
            return first
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

        if isFirst {
            Log.capture.notice("AudioRecorder: first callback, format \(String(describing: inputFormat), privacy: .public), frames \(numSamples, privacy: .public)")
        }
        guard numSamples > 0 else { return }

        // Copy the CMSampleBuffer's PCM into an AVAudioPCMBuffer shaped by the
        // input format. mutableAudioBufferList has the right buffer count for
        // interleaved vs. non-interleaved, so this handles both.
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            if isFirst {
                Log.capture.notice("AudioRecorder: PCM copy failed (OSStatus \(copyStatus, privacy: .public))")
            }
            return
        }

        guard let targetFormat else { return }

        // Build the converter lazily from the actual input format, once.
        if converter == nil {
            if buildFailed { return }
            guard let built = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                buildFailed = true
                Log.capture.notice("AudioRecorder: could not build converter from \(String(describing: inputFormat), privacy: .public)")
                return
            }
            converter = built
            Log.capture.notice("AudioRecorder: converter built \(inputFormat.sampleRate, privacy: .public)Hz/\(inputFormat.channelCount, privacy: .public)ch -> 16kHz mono")
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(numSamples) * ratio) + 1
        guard capacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // Feed the single input buffer once, then report no more data. The flag
        // lives in a reference so the input block doesn't mutate a captured var
        // (which the converter may invoke as concurrent code).
        let feed = InputFeed()
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if feed.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error,
              let channelData = outputBuffer.floatChannelData else {
            return
        }

        let frames = Int(outputBuffer.frameLength)
        guard frames > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        lock.withLock { samples.append(contentsOf: chunk) }
    }

    private static func authName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown"
        }
    }
}

/// One-shot flag for the converter input block. A reference type so the block
/// reads/writes a shared instance rather than a captured `var`. Safe to mark
/// unchecked-Sendable: the input block is invoked only synchronously, within a
/// single `convert(...)` call on the capture queue, so `consumed` is never
/// touched concurrently.
private nonisolated final class InputFeed: @unchecked Sendable {
    var consumed = false
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case formatUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noInputDevice:     return "No audio input device is available."
        case .formatUnavailable: return "Could not create the 16 kHz mono audio format."
        case .cannotAddInput:    return "Could not add the microphone input to the capture session."
        case .cannotAddOutput:   return "Could not add the audio output to the capture session."
        }
    }
}
