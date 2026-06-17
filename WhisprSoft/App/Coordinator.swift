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
    private let log: DictationLogStore

    /// Snapshotted in beginDictation() from whether the popover is open; honored
    /// for the whole run even if the popover is closed before release.
    private var routingToNote = false

    /// When the current recording began (set in beginDictation). Used to report
    /// the hold duration in the dictation log; only meaningful on the success
    /// path that runs through endDictation().
    private var recordStart: Date?

    /// The global hold-to-talk hotkey. The Coordinator owns it and wires its
    /// callbacks to begin/end dictation; arm it with startHotkey().
    private let hotkey = HotkeyMonitor()

    init(
        recorder: AudioRecording = AudioRecorder(),
        transcriber: Transcriber = WhisperKitTranscriber(),
        rewriter: Rewriter = RewriteLadder(
            claude: HTTPRewriter(config: .cloud),
            openai: OpenAIRewriter(),
            local: HTTPRewriter(config: .local)
        ),
        injector: TextInjector = PasteboardInjector(),
        scratchpad: ScratchpadStore = ScratchpadStore(),
        log: DictationLogStore = DictationLogStore()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.rewriter = rewriter
        self.injector = injector
        self.scratchpad = scratchpad
        self.log = log
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

    /// Push a changed dictation shortcut to the live tap so a new binding takes
    /// effect without a relaunch. The monitor caches the chord (it can't read
    /// UserDefaults on the per-event hot path), so this explicit reload is how
    /// the UI propagates a change.
    func updateHotkey() { hotkey.reloadShortcut() }

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
        recordStart = Date()
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

        // Timing/diagnostic accumulators for the dictation log. `processingStart`
        // is the instant the user released (right before stop()); totalMs is
        // measured from here, so it excludes the hold itself (that's recordMs).
        // The per-stage spans and char counts are filled as the run progresses
        // so the catch/no-audio paths can still report whatever is known.
        let processingStart = Date()
        let recordMs = recordStart.map { Int(processingStart.timeIntervalSince($0) * 1000) } ?? 0
        let destinationLabel = routingToNote ? "Note" : "Pasted"
        var transcriptionMs = 0
        var rewriteMs = 0
        var inputChars = 0
        var outputChars = 0
        var result: RewriteResult?

        do {
            let audio = await recorder.stop()
            guard !audio.samples.isEmpty else {
                Log.pipeline.error("No audio captured")
                log.record(DictationLogEntry(
                    date: Date(), engine: "—", model: nil, usedRawFallback: false,
                    destination: "—", recordMs: recordMs, transcriptionMs: 0,
                    rewriteMs: 0, totalMs: Int(Date().timeIntervalSince(processingStart) * 1000),
                    inputChars: 0, outputChars: 0, status: "No audio"))
                recoverFromError(PipelineError.noAudioCaptured)
                return
            }

            let transcript = try await transcriber.transcribe(audio)
            transcriptionMs = Int(Date().timeIntervalSince(processingStart) * 1000)
            inputChars = transcript.count

            state = .rewriting
            let rewriteStart = Date()
            let rr = try await rewriter.rewrite(transcript)
            result = rr
            rewriteMs = Int(Date().timeIntervalSince(rewriteStart) * 1000)

            // Final deterministic pass: fix known mishearings/misspellings the
            // rewrite (or Whisper) may have left, before the text is injected.
            let corrected = KeywordCorrector.correct(rr.text)
            outputChars = corrected.count

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

            log.record(DictationLogEntry(
                date: Date(), engine: rr.engine, model: rr.model,
                usedRawFallback: rr.usedRawFallback,
                usedProviderFallback: rr.usedProviderFallback, destination: destinationLabel,
                recordMs: recordMs, transcriptionMs: transcriptionMs, rewriteMs: rewriteMs,
                totalMs: Int(Date().timeIntervalSince(processingStart) * 1000),
                inputChars: inputChars, outputChars: outputChars, status: "OK"))
        } catch {
            Log.pipeline.error("Pipeline error: \(error.localizedDescription, privacy: .public)")
            // The run failed before delivery, so report "—" for destination — the
            // intended target (Pasted/Note) would falsely imply the text landed.
            log.record(DictationLogEntry(
                date: Date(), engine: result?.engine ?? "—", model: result?.model,
                usedRawFallback: result?.usedRawFallback ?? false, destination: "—",
                recordMs: recordMs, transcriptionMs: transcriptionMs, rewriteMs: rewriteMs,
                totalMs: Int(Date().timeIntervalSince(processingStart) * 1000),
                inputChars: inputChars, outputChars: outputChars,
                status: "Error: \(error.localizedDescription)"))
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
