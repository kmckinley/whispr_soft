//
//  Coordinator.swift
//  WhisprSoft
//
//  Owns FlowState and the pipeline shape. The ONLY type that mutates
//  state and the ONLY type that knows how the stages chain together.
//  Stages are held by protocol type and injected at init.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class Coordinator {
    /// The single source of truth for pipeline state. Only this type
    /// mutates it.
    private(set) var state: FlowState = .idle

    /// True while the transcription model is loading (first launch downloads
    /// it). The UI observes this to show a "preparing" hint.
    private(set) var isModelLoading = false

    private let recorder: AudioRecording
    private let transcriber: Transcriber
    private let rewriter: Rewriter
    private let injector: TextInjector
    private let scratchpad: ScratchpadStore

    /// Snapshotted in beginDictation() from whether the popover is open; honored
    /// for the whole run even if the popover is closed before release.
    private var routingToNote = false

    /// The global hold-to-talk hotkey. The Coordinator owns it and wires its
    /// callbacks to begin/end dictation; arm it with startHotkey().
    private let hotkey = HotkeyMonitor()

    init(
        recorder: AudioRecording = AudioRecorder(),
        transcriber: Transcriber = WhisperKitTranscriber(),
        rewriter: Rewriter = RewriteLadder(
            cloud: HTTPRewriter(config: .cloud),
            local: HTTPRewriter(config: .local)
        ),
        injector: TextInjector = PasteboardInjector(),
        scratchpad: ScratchpadStore = ScratchpadStore()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.rewriter = rewriter
        self.injector = injector
        self.scratchpad = scratchpad
    }

    // MARK: - Hotkey

    /// Wire the hold-to-talk callbacks and arm the monitor. beginDictation is
    /// synchronous (it runs directly from the chord-down handler); endDictation
    /// is async so it's dispatched on a Task. `[weak self]` breaks the retain
    /// cycle: the Coordinator owns the monitor, whose closures capture it.
    func startHotkey() {
        hotkey.onChordDown = { [weak self] in self?.beginDictation() }
        hotkey.onChordUp   = { [weak self] in
            Task { @MainActor in await self?.endDictation() }
        }
        hotkey.start()
    }

    func stopHotkey() { hotkey.stop() }

    // MARK: - Model preload

    /// Warm the transcription model so the first dictation isn't blocked on a
    /// cold load (the first launch downloads ~480 MB). The model load needs no
    /// permissions, so this is safe to call unconditionally at launch — it
    /// warms during onboarding. Idempotent: the transcriber caches its load.
    func preloadModel() {
        isModelLoading = true
        Task { @MainActor in
            await transcriber.prepare()
            isModelLoading = false
        }
    }

    // MARK: - Pipeline

    /// Chord-down entry point. Synchronous so it completes before any
    /// chord-up fires: engine start (~100ms) is well under the event-tap
    /// timeout, and finishing here means state is reliably `.recording` by
    /// the time endDictation() runs — no begin/end race.
    func beginDictation() {
        // Authoritative re-entrancy guard: refuse to start while a run is in
        // flight (a stuck modifier or repeated chord could re-enter).
        guard state == .idle else { return }

        // Snapshot the routing decision: if the popover is open at begin, the
        // cleaned text goes to the note instead of the frontmost app. Honored
        // for the whole run even if the popover is closed before release.
        routingToNote = scratchpad.isPopoverOpen

        state = .recording
        if routingToNote { scratchpad.beginCapture() }
        do {
            try recorder.start()
        } catch {
            Log.pipeline.error("beginDictation failed: \(error.localizedDescription, privacy: .public)")
            // Surface the error, then recover to .idle after a beat. The happy
            // path stays fully synchronous (no begin/end race); only this error
            // tail defers, mirroring endDictation's recovery. Setting .error
            // then .idle inline would never publish .error to the UI.
            recoverFromError(error)
        }
    }

    /// Chord-up entry point. Stops capture and runs the rest of the pipeline
    /// (transcribe → rewrite → inject), advancing `state` at each boundary and
    /// ending at `.idle` — or surfacing `.error` briefly on failure.
    func endDictation() async {
        guard state == .recording else { return }
        // Claim the transition synchronously, before the first await. Otherwise
        // two chord-up Tasks could both pass the `.recording` guard across the
        // `await recorder.stop()` suspension and call stop() concurrently —
        // breaking AudioRecorder's documented start()/stop()-never-overlap
        // invariant.
        state = .transcribing

        do {
            let audio = await recorder.stop()
            guard !audio.samples.isEmpty else {
                Log.pipeline.error("No audio captured")
                recoverFromError(PipelineError.noAudioCaptured)
                return
            }

            let transcript = try await transcriber.transcribe(audio)

            state = .rewriting
            let rewritten = try await rewriter.rewrite(transcript)

            // Final deterministic pass: fix known mishearings/misspellings the
            // rewrite (or Whisper) may have left, before the text is injected.
            let corrected = KeywordCorrector.correct(rewritten)

            if routingToNote {
                // Deliver to the in-popover note — never touch the pasteboard
                // or synthesize ⌘V in this path.
                scratchpad.append(corrected)
                scratchpad.endCapture()
                routingToNote = false
                state = .idle
            } else {
                state = .injecting
                try injector.inject(corrected)
                state = .idle
            }
        } catch {
            Log.pipeline.error("Pipeline error: \(error.localizedDescription, privacy: .public)")
            recoverFromError(error)
        }
    }

    /// Surface a failure as `.error`, then return to `.idle` after a beat so the
    /// pipeline is usable again. The recovery runs on a Task so the same helper
    /// serves the synchronous beginDictation path and the async endDictation
    /// path; the `if case .error` guard avoids clobbering a run that has since
    /// moved past `.error`.
    private func recoverFromError(_ error: Error) {
        // Reset note-capture state so a failed run never leaves the box stuck
        // "capturing" (the no-audio guard routes through here too).
        scratchpad.endCapture()
        routingToNote = false
        state = .error(error.localizedDescription)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if case .error = state { state = .idle }
        }
    }
}

/// Pipeline-level failures the Coordinator surfaces directly (distinct from a
/// stage's own errors).
enum PipelineError: LocalizedError {
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return "No audio was captured. Check your microphone."
        }
    }
}
