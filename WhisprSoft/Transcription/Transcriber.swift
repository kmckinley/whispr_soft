//
//  Transcriber.swift
//  WhisprSoft
//
//  Transcription stage contract + stub. A real Whisper model lands in a
//  later pass.
//

import Foundation

/// Turns captured audio into text.
protocol Transcriber {
    func transcribe(_ audio: RecordedAudio) async throws -> String

    /// Optional preload hook so a transcriber backed by a heavy model can warm
    /// up before the first dictation. Defaults to a no-op for stubs and any
    /// transcriber with nothing to load.
    func prepare() async
}

extension Transcriber {
    func prepare() async {}   // default: nothing to preload
}

/// Returns a canned line after a short, observable delay.
nonisolated struct StubTranscriber: Transcriber {
    func transcribe(_ audio: RecordedAudio) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        return "this is a stub transcription"
    }
}
