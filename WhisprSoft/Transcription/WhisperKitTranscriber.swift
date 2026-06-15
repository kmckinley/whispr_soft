//
//  WhisperKitTranscriber.swift
//  WhisprSoft
//
//  Real transcription via WhisperKit (small.en). Consumes RecordedAudio's
//  16 kHz mono [Float] directly — no file round-trip. The model is loaded
//  once and preloaded at launch through prepare().
//

import Foundation
import WhisperKit
import os

/// Transcribes captured audio with WhisperKit's small English model.
///
/// MainActor-isolated (matching the project default and the protocol): the
/// heavy ML work happens inside WhisperKit's own async methods, and `await`
/// frees the main thread for its duration — we never block on it synchronously.
@MainActor
final class WhisperKitTranscriber: Transcriber {
    /// The loaded model. Created and read only on the main actor, so this
    /// non-Sendable type never crosses an isolation boundary.
    private var kit: WhisperKit?

    /// Caches the in-flight load so concurrent callers (the launch preload and
    /// a first dictation) share one download instead of racing two. It carries
    /// no payload — the loaded model lands in `kit` — so nothing non-Sendable
    /// escapes the Task. Cleared on failure so a later attempt can retry.
    private var loadTask: Task<Void, Error>?

    /// `nonisolated` so the Coordinator can construct it in a default argument
    /// (a nonisolated context), matching the stub transcribers. Construction is
    /// trivial — the model loads via `prepare()`/`ensureLoaded()`, not here.
    nonisolated init() {}

    /// Where WhisperKit caches the model and tokenizer. We pin this to
    /// Application Support so WhisperKit's Hugging Face Hub layer doesn't default
    /// the download to `~/Documents/huggingface`, which (since this app is not
    /// sandboxed) would trip the macOS "access files in your Documents folder"
    /// TCC prompt on first launch. Application Support is the right home for a
    /// large app-managed model — Caches can be purged by the system, forcing a
    /// silent re-download — and it isn't TCC-protected, so no prompt appears.
    ///
    /// Setting only `downloadBase` covers the tokenizer too: WhisperKit derives
    /// its tokenizer folder as `tokenizerFolder ?? downloadBase`.
    private func modelDownloadBase() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let base = appSupport.appendingPathComponent("WhisprSoft", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Loads the model once. A second caller arriving mid-load awaits the same
    /// Task rather than starting a second download.
    private func ensureLoaded() async throws -> WhisperKit {
        if let kit { return kit }

        let task = loadTask ?? {
            let task = Task { @MainActor in
                Log.transcription.notice("WhisperKit: loading model small.en")
                let base = try modelDownloadBase()
                kit = try await WhisperKit(WhisperKitConfig(model: "small.en", downloadBase: base))
                Log.transcription.notice("WhisperKit: model ready")
            }
            loadTask = task
            return task
        }()

        do {
            try await task.value
        } catch {
            // Don't cache a failed load — let a later attempt retry
            // (e.g. a transient network failure on first download).
            loadTask = nil
            throw error
        }

        guard let kit else {
            // Unreachable: a successful load always sets `kit`.
            throw TranscriptionError.modelUnavailable
        }
        return kit
    }

    func transcribe(_ audio: RecordedAudio) async throws -> String {
        let kit = try await ensureLoaded()
        let results = try await kit.transcribe(audioArray: audio.samples)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("WhisperKit: transcribed \(text.count, privacy: .public) chars")
        return text
    }

    /// Preload hook: kick off the model load so it's warm before the first
    /// dictation. Errors are swallowed here — a real dictation surfaces them by
    /// retrying the load.
    func prepare() async { _ = try? await ensureLoaded() }
}

/// Failures originating in the transcription stage.
enum TranscriptionError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The transcription model could not be loaded."
        }
    }
}
