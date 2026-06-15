//
//  AudioRecording.swift
//  WhisprSoft
//
//  Capture stage contract + stub. Real capture (16 kHz mono PCM) lands
//  in a later pass.
//

import Foundation

/// A finished recording handed off to the transcription stage.
/// Audio convention: 16 kHz mono PCM (what Whisper expects).
struct RecordedAudio {
    let samples: [Float]   // 16 kHz mono PCM
    let sampleRate: Double // 16_000 by convention
}

/// Drives microphone capture. Stages take input and return output; they
/// never reference each other or the UI.
protocol AudioRecording {
    func start() throws
    func stop() async -> RecordedAudio
}

/// No-op recorder. `stop()` waits briefly so the state transition is
/// observable in the menu during a test run. `nonisolated` (like the real
/// `AudioRecorder`) so it's constructible in the Coordinator's default args.
nonisolated struct StubRecorder: AudioRecording {
    func start() {
        print("StubRecorder.start()")
    }

    func stop() async -> RecordedAudio {
        try? await Task.sleep(for: .milliseconds(300))
        // Non-empty (1s of silence) so a stub-driven pipeline clears the
        // Coordinator's zero-sample guard and still flows end-to-end.
        return RecordedAudio(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
    }
}
