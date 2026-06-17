# WhisprSoft

A Whisper-based dictation tool for macOS: a menu-bar agent that records
speech, transcribes it locally, optionally rewrites it, and injects the
result into the frontmost app.

A small personal macOS tool — favor pragmatism over polish and avoid premature
abstraction.

## Constraints

- Swift 5, Xcode 26.5, macOS 26.5 deployment target.
- **App Sandbox is OFF; Hardened Runtime is ON.** The Accessibility APIs
  and synthetic event injection (the paste keystroke) are unsupported
  under the App Sandbox, and this app requires both — so it cannot be
  sandboxed.
- **WhisperKit** (`argmaxinc/argmax-oss-swift`, **WhisperKit product
  only** — not SpeakerKit/TTSKit, pinned to 1.0.0+) is the project's first
  and only external dependency, used for on-device transcription. The repo
  was renamed from `argmaxinc/WhisperKit` to `argmaxinc/argmax-oss-swift`
  at v1.0.0. Added via the Xcode package UI; the SPM wiring lives in
  `project.pbxproj` (the package reference, product dependency, and
  Frameworks-phase link). Model download needs network on first run; the
  app is not sandboxed, so no entitlement is required.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, so
  declarations are MainActor-isolated unless marked otherwise.

## Module layout

    App/
      Coordinator.swift     // owns FlowState, drives the pipeline, owns the hotkey
      FlowState.swift       // pipeline state enum
    Capture/
      AudioRecording.swift  // RecordedAudio + AudioRecording + StubRecorder
      AudioRecorder.swift   // real AVAudioEngine capture
      HotkeyMonitor.swift   // configurable hold-to-talk CGEventTap (default ⌃⌥Space)
      DictationShortcut.swift  // the configurable chord (keyCode + modifiers)
    Transcription/
      Transcriber.swift     // Transcriber (+ prepare() default) + StubTranscriber
      WhisperKitTranscriber.swift  // real WhisperKit transcriber (small.en)
    Rewrite/
      Rewriter.swift        // RewriteMode + Rewriter + StubRewriter
      HTTPRewriter.swift    // RewriterConfig + real Anthropic Messages rewriter
      RewriteLadder.swift   // mode-aware (local/cloud) → raw ladder
    Correction/
      KeywordCorrector.swift  // deterministic whole-word find-replace (final step)
      CorrectionsStore.swift  // user-editable corrections list + persistence
    Injection/
      TextInjector.swift    // TextInjector + StubInjector + PasteboardInjector
    Permissions/
      PermissionsManager.swift  // mic + Accessibility status
    Security/
      Keychain.swift        // Claude API key store (generic password)
    UI/
      MenuBarContent.swift  // the menu-bar popover (incl. the permissions gate)

The Xcode project uses a `PBXFileSystemSynchronizedRootGroup`: files on
disk under `WhisprSoft/` are picked up automatically — no pbxproj edits
are needed to add or remove source files.

## Architecture

- **Coordinator** is `@MainActor` and `@Observable`. It owns
  `FlowState`, is the **only** type that mutates state, and is the
  **only** type that knows the pipeline shape (the order stages run and
  how their output chains).
- **Stages** are protocol-typed (`AudioRecording`, `Transcriber`,
  `Rewriter`, `TextInjector`) and independent: they take input and
  return output, never referencing each other or the UI. They are
  injected into the Coordinator at init (stub defaults for now).
- **UI** observes the Coordinator (and later, Settings) and nothing
  else.

### Concurrency

The Coordinator runs on the main actor. Heavy stage work (audio
capture, transcription) runs async/off-main inside the stage
implementations in their respective passes — not on the Coordinator.

## Permissions

Permissions modeled (both currently gating the pipeline):

- **Microphone** — for audio capture. Granted inline via the TCC dialog.
  Under Hardened Runtime, requires `com.apple.security.device.audio-input`
  (set via the `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT` build setting — this
  target is build-setting-driven, no `.entitlements` file) plus the
  `NSMicrophoneUsageDescription` usage string
  (`INFOPLIST_KEY_NSMicrophoneUsageDescription`).
- **Accessibility** — required both to post the paste keystroke during
  injection **and** to run the active `CGEventTap` that observes the
  dictation hotkey (an active `.defaultTap` keystroke-observing tap is
  authorized by Accessibility, not Input Monitoring — only `.listenOnly`
  taps need the latter, so Input Monitoring is not modeled). Only grantable
  now that the App Sandbox is off (Apple does not support the Accessibility
  APIs in sandboxed apps — with the sandbox on, the app never appears in the
  System Settings list). Cannot be granted inline; the gate shows a single
  **Grant** button that calls `AXIsProcessTrustedWithOptions([prompt:
  true])` — the system prompt itself offers to open Settings (we do **not**
  separately open the pane). macOS exposes no "denied" state for it — only
  granted vs. not-yet-enabled.

Changing the entitlement set (as this pass does by dropping the sandbox)
invalidates prior TCC grants, so all permissions must be re-granted after
the change.

**Hard gate:** `PermissionsManager` (`@MainActor`, `@Observable`) is the
single source of truth for status; the UI observes it. While
`!allGranted`, the popover shows only `MenuBarContent`'s styled
`permissionsGate` (no tabs/gear/Local-AI) and the pipeline control is not
rendered, so a run is unreachable. There is **no** Permissions section in
Settings — the auto re-gating below handles revocation. The gate lives in
the UI only — the Coordinator stays free of permission concerns. The gate
re-evaluates **bidirectionally** on every popover open: the `.onAppear`
refresh lives on `MenuBarContent`, so a revocation re-gates and a fresh
grant un-gates. The same `MenuBarContent` arms/disarms the hotkey off the
gate (`.onChange(of: allGranted, initial: true)`), and the `AppDelegate`
arms it at launch when already granted — so dictation works on relaunch
without opening the menu.

## Stage contracts (current source of truth)

```swift
enum FlowState: Equatable {
    case idle, recording, transcribing, rewriting, injecting
    case error(String)
}

struct RecordedAudio {
    let samples: [Float]    // 16 kHz mono PCM
    let sampleRate: Double  // 16_000 by convention
}

protocol AudioRecording {
    func start() throws
    func stop() async -> RecordedAudio
}

protocol Transcriber {
    func transcribe(_ audio: RecordedAudio) async throws -> String
    func prepare() async   // default no-op; loading transcribers preload here
}

enum RewriteMode { case cloud, local, raw }

protocol Rewriter {
    func rewrite(_ text: String) async throws -> String
}

protocol TextInjector {
    func inject(_ text: String) throws
}
```

## Logging

Components log via the shared `Log` helper (`Support/Log.swift`, built on
`os.Logger`, subsystem = bundle id `com.whisprsoft`; categories
`capture`, `hotkey`, `pipeline`, `transcription`, `rewrite`, `correction`,
`injection`). Mark
diagnostic interpolations `privacy: .public` — unified logging redacts
dynamic values by default, and these numbers (formats, counts, peak) are
non-sensitive. `print()` is avoided: a GUI app's stdout isn't visible in
Console, and launching from a terminal breaks TCC identity. View the real
app's logs with Console.app or:

    log stream --predicate 'subsystem == "com.whisprsoft"'

## Audio convention

16 kHz mono PCM — what Whisper expects.

### Capture stage

The Coordinator's default recorder is `AudioRecorder` (`Capture/`): real
capture via **`AVCaptureSession` + `AVCaptureAudioDataOutput`**, resampled
with `AVAudioConverter` to 16 kHz mono Float32. It is `nonisolated` (a
nonisolated witness satisfies the MainActor-isolated `AudioRecording`
requirement) so the sample-buffer delegate can append to a lock-protected
buffer off the main actor; session/device setup is deferred entirely to
`start()` (no mic interaction at launch). `StubRecorder` is retained for
previews/tests; all stubs are `nonisolated` so they construct in the
Coordinator's default arguments. The `AudioRecording` protocol and
`RecordedAudio` output are **unchanged** by this implementation, as is the
Coordinator (begin/end, the empty-capture guard).

Capture pattern: `start()` pins the **built-in microphone** via
`AVCaptureDevice(uniqueID:)` using the Core Audio built-in UID
(`AudioDevices.builtInInputUID()` — matched by built-in transport type),
falling back to `AVCaptureDevice.default(for: .audio)` if none is found, and
logs the chosen device. The session delivers `CMSampleBuffer`s on a serial
queue; each is copied into an `AVAudioPCMBuffer`
(`CMSampleBufferCopyPCMDataIntoAudioBufferList`) and resampled by an
`AVAudioConverter` built **lazily from the first buffer's actual format** →
16 kHz mono. Accumulation is lock-guarded off the main actor; the
converter/format state is confined to the capture queue; diagnostics via
`Log.capture`.

Why `AVCaptureSession` and not `AVAudioEngine`: the engine's input path was
fragile around device/format control — it gave the 0-callbacks pull bug, the
Bluetooth IO failure, and `-10875` (`kAudioUnitErr_FailedInitialization`)
when pinning the input device with `kAudioOutputUnitProperty_CurrentDevice`.
`AVCaptureSession` selects a specific device reliably and avoids those
failure modes.

Capture is driven by the hold-to-talk hotkey: `beginDictation()` (chord
down) calls `start()`, `endDictation()` (chord up) calls `stop()` and runs
the rest of the pipeline. (The earlier TEMP fixed 3s window is gone.)

### Transcription stage

The Coordinator's default transcriber is `WhisperKitTranscriber`
(`Transcription/`): real on-device transcription via **WhisperKit**, model
**`small.en`** (resolved by WhisperKit's glob match). It is `@MainActor`
(matching the project default and the protocol) — the heavy ML work runs
inside WhisperKit's own async methods, and `await` frees the main thread for
its duration, so it's never blocked synchronously. It transcribes
`RecordedAudio`'s raw 16 kHz mono `[Float]` directly via
`transcribe(audioArray:)` (which returns a non-optional
`[TranscriptionResult]`, joined and trimmed) — no file round-trip.
`StubTranscriber` is retained for previews/tests.

The model is **loaded once**: a cached `Task<Void, Error>` (`loadTask`)
dedupes concurrent loads — the launch preload and a first dictation share
one download rather than racing two. The loaded `WhisperKit` lands in a
stored `kit` property and is created/read only on the main actor, so this
non-Sendable type never crosses an isolation boundary (the Task carries
`Void`, not the model); a failed load clears `loadTask` so a later attempt
retries. The `Transcriber` protocol gained a default-no-op `prepare()` for
preloading; `WhisperKitTranscriber.prepare()` warms the load (swallowing
errors — a real dictation surfaces them by retrying). The Coordinator
exposes `preloadModel()` (sets the Observable `isModelLoading`, awaits
`prepare()`, clears it) and a `private(set) var isModelLoading`. The
pipeline shape is **unchanged** — `endDictation()` already awaits
`transcriber.transcribe(...)`; a dictation before the model is ready simply
awaits the in-flight load. Diagnostics via `Log.transcription`.

### Hotkey

`HotkeyMonitor` (`Capture/`) is an **active** `CGEventTap`
(`.cgSessionEventTap`, `.defaultTap`, head-inserted) on the **main** run
loop, implementing hold-to-talk for a **user-configurable chord** (default
⌃⌥Space). The chord is modeled by `DictationShortcut` (a `nonisolated struct`:
`keyCode` + masked `modifiers`, with `storageString`/`init?(storageString:)`
serialization, `active()`, `cgFlags`, `symbols`, `keyName(for:)` via
`UCKeyTranslate`, and an `init?(nsEvent:)` validating ≥1 modifier + a
non-modifier `.keyDown`). The model is **hold-to-talk only, ≥1 modifier + one
regular key** — no toggle/tap mode, no modifier-only bindings, one shortcut.
The monitor **caches** the chord in `shortcut` and reloads it via
`reloadShortcut()` (called at the top of `start()`, before the idempotency
guard, so arming picks up the current binding; and by
`Coordinator.updateHotkey()` on a live change). This is the **one** place the
read-fresh-per-call convention does **not** apply: the tap sees every keystroke
system-wide, so a per-event `UserDefaults` read/parse would burden the
latency-sensitive hot path (slow callbacks get disabled by timeout). The C
trampoline is a file-scope `nonisolated func` (a `@convention(c)` pointer can't
be formed from a MainActor-isolated function under the project's default
isolation); it bridges into the actor via `MainActor.assumeIsolated`, so
`handle(...)` and the `onChordDown`/`onChordUp` callbacks stay MainActor-isolated
and call the Coordinator directly. `handle(...)` matches the cached chord:
`isMainKey = keyCode == shortcut.keyCode`, `modifiersHeld =
flags.contains(shortcut.cgFlags)` (a **subset** test — all *required* modifiers
present, extras don't block). Main-key suppression is tracked by
`consumingMainKey`, separate from `chordEngaged`: once the gesture owns the main
key it **consumes** (returns nil) *every* event for that key — the engaging
keyDown, WindowServer auto-repeats, and the final keyUp — until it lifts, so no
character is ever typed, even if a modifier is released first. `onChordDown`
fires on the engaging transition; `onChordUp` fires on keyUp **or** a required
modifier released mid-hold (`flagsChanged`), whichever comes first, while the
trailing main-key events keep getting swallowed. It re-enables itself on
`.tapDisabledByTimeout`/`.tapDisabledByUserInput`.
`start()` is idempotent (no-op if the tap exists). The tap is **active**
(`.defaultTap`), so it's authorized by **Accessibility** — `start()` does
**not** preflight or request Input Monitoring (`CGPreflightListenEventAccess`
is gone); it calls `tapCreate` directly and bails on a nil return
(Accessibility not yet granted), and the permission gate brings it back once
granted. Diagnostics via `Log.hotkey`. The shortcut is recorded from Settings
(an interactive recorder in `MenuBarContent` — see Build / run); the Dictate
hero and Settings keycaps both render from `DictationShortcut.symbols`.

### Coordinator entry points

`runPipeline()` is replaced by two entry points the hotkey drives:
- `beginDictation()` — **synchronous**, runs from the chord-down handler;
  guards `state == .idle`, sets `.recording`, calls `recorder.start()`.
- `endDictation()` — **async**, dispatched from chord-up; guards
  `state == .recording` then claims `.transcribing` **synchronously before
  the first await**, then `stop()` → transcribe → rewrite → **correct** →
  inject, ending at `.idle` (or `.error` briefly on failure via
  `recoverFromError`). A
  **zero-sample** capture (the device-IO-failed signature) is surfaced as
  `.error` (`PipelineError.noAudioCaptured`) right after `stop()` rather than
  feeding an empty buffer into transcription; a non-empty-but-quiet capture
  is a normal case and passes through (no silence detection).

Synchronous begin / async end is deliberate: chord-down completes
`beginDictation()` before any chord-up fires, so state is reliably
`.recording` when `endDictation()` runs — no begin/end race. The
`state == .idle` / `state == .recording` guards are the authoritative
re-entrancy protection; endDictation transitioning off `.recording` before
its first suspension keeps that guard atomic, so two chord-up Tasks can't
both reach a concurrent `recorder.stop()`. Both failure paths funnel
through `recoverFromError` (surface `.error`, then back to `.idle`). The Coordinator owns the `HotkeyMonitor` and exposes
`startHotkey()` / `stopHotkey()` (callbacks wired with `[weak self]` to break
the owner↔closure cycle).

### App lifecycle

`AppDelegate` (`@NSApplicationDelegateAdaptor` in `WhisprSoftApp.swift`)
owns the `Coordinator` and `PermissionsManager` (both still `@Observable`,
so views track them through the delegate). `applicationDidFinishLaunching`
refreshes permissions and arms the hotkey if `allGranted`; the UI arms it on
first grant via the gate's `.onChange`. It then calls
`coordinator.preloadModel()` **unconditionally** — the model load needs no
permissions, so it warms even while the user is still in onboarding. The
menu shows a "Preparing transcription model…" line while `isModelLoading`
(first launch downloads ~480 MB), otherwise the "Hold <chord> to dictate"
hint (the chord rendered from the active `DictationShortcut`, default ⌃⌥Space).

### Correction stage

`KeywordCorrector` (`Correction/`) runs as the **final** pipeline step —
after the rewrite, before injection — so neither Whisper's mishearing nor the
LLM can leave a wrong spelling (e.g. "acme co" → "Acme Co", a misheard proper
name → its canonical spelling). It's a pure deterministic function (a `nonisolated enum`), **not**
a protocol-injected stage — there's no swappable backend, so no abstraction is
warranted. Corrections are now a **user-editable list** that **ships empty**,
stored as JSON in `UserDefaults` (`CorrectionsStore.storageKey`) and edited from
an always-visible section in the menu. `CorrectionsStore` (`@Observable`,
`@MainActor`, owned by `AppDelegate`) is the UI's source of truth;
`KeywordCorrector` reads the same key fresh per call (the same read-fresh
pattern as Local Mode), so edits apply on the next dictation without relaunch.
Matching is unchanged: keys match **case-insensitively** and **whole-word**
(`\b…\b`, so substrings like "acme" inside "acmecorp" are untouched, and
multi-word keys like "acme co" work), and each replacement is inserted with
**exactly** the casing the user typed in the `to` field. The `heard` (`from`)
field is **forced lowercase** as typed (matching is case-insensitive regardless,
so this just keeps the stored key tidy). Blank-`from` rows are skipped; blank-`to`
deletes the match. The menu's corrections list shows up to **five rows** then
scrolls. Keys/values are regex-escaped, so special characters can't
break matching. Logs only a count (`KeywordCorrector: applied N correction(s)`)
— never content. Diagnostics via `Log.correction`.

### Injection stage

The Coordinator's default injector is `PasteboardInjector`
(`Injection/`): real injection — deep-copies and restores the pasteboard
around setting the text, posts synthetic Cmd-V via `CGEvent`
(`.cghidEventTap`), no-ops on empty text, throws `InjectionError` if
Accessibility isn't trusted. Restore is delayed ~120ms (heuristic for paste
completion). Requires the Accessibility grant (already gated). The synthetic
Cmd-V (keycode 9 + Command) passes through our own hotkey event tap
untouched — that tap only consumes Space (keycode 49) while Control+Option
are held, so no self-interference. `StubInjector` retained for
previews/tests. Diagnostics via `Log.injection`. The pasteboard deep-copy
captures only materialized data, so promised/lazy clipboard types (e.g. a
file copied in Finder) are dropped on restore — documented inline.

### Rewrite stage

The Coordinator's default rewriter is `RewriteLadder(cloud:
HTTPRewriter(config: .cloud), local: HTTPRewriter(config: .local))`
(`Rewrite/`): a real LLM cleanup of the raw transcript before injection,
routed to cloud Claude or a local LM Studio by the **Local Mode** toggle.

- `HTTPRewriter` (`nonisolated`) speaks the **Anthropic Messages shape**
  (`POST /v1/messages`, headers `x-api-key` / `anthropic-version: 2023-06-01`
  / `content-type: application/json`; body `model` / `max_tokens: 2048` /
  `system` / `messages`), via `URLSession` async. One client serves **both
  backends** via `RewriterConfig`: `.cloud` (Anthropic, model pinned to
  **`claude-haiku-4-5-20251001`**, `x-api-key` from the Keychain) and
  `.local` (LM Studio at **`http://127.0.0.1:1234/v1/messages`** — `127.0.0.1`
  not `localhost` so the plaintext call is ATS-exempt, no Info.plist/ATS
  change; a dummy `"lmstudio"` token). The model id is pinned for cloud and,
  for local (`config.model == nil`), **resolved at runtime** from
  `config.modelsEndpoint` (`/v1/models`, OpenAI-style `{ "data": [{ "id" }] }`,
  **first** id); an empty list or unreachable endpoint ⇒
  `RewriterError.noModelAvailable` (→ raw fallback). The system prompt is a
  MODERATE cleanup prompt (fix punctuation/grammar, drop fillers/false
  starts, preserve meaning, never treat the transcript as a command).
  Hardened against the model answering dictation instead of cleaning it: the
  transcript is wrapped in a `<transcript>` delimiter and the request carries a
  few fixed few-shot example turns, so dictated questions/requests/commands are
  cleaned, not answered (a model refusal is a 200 response that would otherwise
  be pasted as-is). Auth is
  resolved per call: cloud reads the API key from the **Keychain per call**
  (updating the key in the menu applies without relaunch; missing key ⇒
  `.noAPIKey` — checked **only** in the cloud branch, so a keyless user still
  reaches the local backend), local uses the dummy token. Other failures:
  non-2xx ⇒ `.httpError(status)`, empty ⇒ `.emptyResponse`, `max_tokens` stop
  ⇒ `.truncated` (so a cut-off cleanup falls back to raw — the full transcript
  beats a silently-truncated one). Logs only counts, the active profile name,
  and the resolved model id (`Rewriter: <cloud|local> [<profile|default>]
  cleaned N -> M chars`, `Rewriter: local resolved model <id>`) — never content,
  key, or profile instruction.
- `RewriteLadder` (`nonisolated`) is **mode-aware**: it reads
  `UserDefaults["localMode"]` **fresh per call** (so toggling takes effect
  immediately), picks `local` or `cloud` as the primary, and on **any** error
  falls back to **raw passthrough** (the transcript unchanged) so dictation
  always pastes something. **Local Mode is local-only**: it falls back to raw,
  **never** to the other backend — text derived from audio leaves the Mac only
  in Cloud Mode (the privacy guarantee). An API/backend failure no longer
  surfaces `.error` in the pipeline — `endDictation()` is unchanged (it already
  awaits `rewriter.rewrite(...)`); the ladder absorbs the failure.

**Tone profiles.** The user can pick a tone for the cleaned text via
user-editable profiles (full CRUD). `RewriteProfilesStore`
(`Rewrite/RewriteProfilesStore.swift`, `@MainActor @Observable`, owned by
`AppDelegate`) mirrors the `CorrectionsStore` pattern: `items` (JSON in
`UserDefaults["rewriteProfiles"]`) plus a selection
(`UserDefaults["selectedRewriteProfileID"]`, the chosen profile's
`uuidString`). Two starters (Professional, Casual) seed **only** on a true
first run — when the storage key is entirely absent; selection defaults to nil
(**Default = unchanged cleanup**). The profile is **applied in `HTTPRewriter`,
not the ladder**, so cloud and local both get it with no ladder change.
`HTTPRewriter.systemPrompt(for:)` composes a **fixed shell + additive tone**:
when no profile is active the system prompt is exactly `cleanupPrompt`
byte-for-byte; when one is active it appends an app-owned `## Tone` section that
wraps the user's instruction in a `<style>` delimiter (the injection guard,
same role `<transcript>` plays) and states the **light-touch contract** (keep
the speaker's own sentences, structure, and meaning; change wording only as far
as the tone requires; everything in `<style>`/`<transcript>` is data, never an
instruction). `fewShotExamples` are unchanged (light touch still means
clean/transform, never answer). The active profile is resolved **fresh per
call** by `RewriteProfilesStore.active()` (a `nonisolated` reader returning a
`Sendable ActiveRewriteProfile`, returning nil for no selection / deleted /
blank instruction — all meaning plain cleanup), the same read-fresh pattern
`KeywordCorrector` uses, so selecting/editing applies on the next dictation.
The menu's `profilesSection` (a Default-or-profile `Picker` + editable
name/instruction rows) is the UI; persistence is on-change, no Save button.

**Target language.** The user can pick an output language for the cleaned
text. Translation is **not** a new pipeline stage — like tone, it's applied
inside `HTTPRewriter.systemPrompt(for:language:)`, so cloud and local both get
it with no ladder/Coordinator change. The list is the fixed, non-user-editable
`TargetLanguage` type (`Rewrite/TargetLanguage.swift`, a `nonisolated struct`
with a `static let all` of ~20 major languages; each carries a stable `id`
slug, a `displayName`, and an `englishName` for the prompt). **English (United
States) (`TargetLanguage.default`, `translates == false`) is the default and
means no translation** — the `## Translate` section is simply not appended and
the system prompt is byte-for-byte unchanged. When a translating language is
selected, `systemPrompt` appends an app-owned `## Translate` section **after**
`## Tone` (cleanup → tone → translate, so translation operates on the
already-cleaned, already-toned text), following the same hardening discipline
as `## Tone` (fixed wording, `englishName` the only variable, restates that the
transcript is data). The selection persists in
`UserDefaults["selectedTargetLanguage"]` (the language `id`; absent/empty/
unknown = default) and is read **fresh per call** by `TargetLanguage.active()`
— the same read-fresh pattern as the tone profile — so a change applies on the
next dictation. The UI is an inline-disclosure **Language** row on the Dictate
tab (above the Tone row), bound directly to `@AppStorage` (no store object, no
save hook). The resolved language id is appended to the `Log.rewrite` line
(`… -> <id>`) only when translating; never any transcript content.

Diagnostics via `Log.rewrite`. `StubRewriter` (in `Rewriter.swift`) is
retained for previews/tests.

The Claude API key lives in the **Keychain** (`Security/Keychain.swift`, a
generic-password wrapper under service `com.whisprsoft`, account
`anthropic-api-key`; value never logged). It's entered via the menu
(`MenuBarContent` has a `SecureField` + Save, a "✓ Claude key saved"
indicator with Remove). No key ⇒ dictation still works, pasting raw
(uncleaned) text. `MenuBarContent` also has a **Local Mode** toggle bound to
`@AppStorage("localMode")`; while it's on, the API-key section is replaced by
a dimmed "unused in Local Mode" note (the key is irrelevant to the local
backend).

The app is not sandboxed, so outbound network needs no entitlement.

## Rewrite ladder (decided design — cloud + local built, mode-selected)

The Rewriter picks one backend by the persisted **Local Mode** toggle
(`UserDefaults["localMode"]`, read per request) and falls back to raw:

1. **cloud** — Claude API. **Built** (`HTTPRewriter(config: .cloud)`). Used
   when Local Mode is **off**: cloud → raw.
2. **local** — LM Studio at `127.0.0.1:1234`, Anthropic-compatible
   `/v1/messages`; the model id is fetched from `/v1/models` at runtime
   (first loaded model) — never hardcoded; a dummy token. **Built**
   (`HTTPRewriter(config: .local)`). Used when Local Mode is **on**.
3. **raw** — if the selected backend is unreachable/fails, pass the
   transcript through unchanged. **Built** (the ladder's fallback).

**Cloud→cloud fallback (opt-in, Cloud Mode only).** When
`UserDefaults["cloudProviderFallback"]` is on (read **fresh per call**, mirroring
`localMode`), a failure of the active cloud provider makes the ladder try the
*other* cloud provider before raw: cloud → other cloud → raw. The other
provider's key is **defensively re-checked** in the ladder (`Keychain.apiKey()`
for Claude / `Keychain.openAIKey()` for ChatGPT, non-empty) because a key can be
removed after the toggle was enabled — if it's missing, the ladder skips straight
to raw. On a successful cross-provider save the `RewriteResult` carries
`usedProviderFallback = true` (logged, and surfaced in the dictation log as an
amber "fallback" tag); both-providers-failed stays `usedProviderFallback = false`
and uses raw (`usedRawFallback = true`), so the cross-provider success count isn't
polluted by the both-failed case (which the Console log line covers). The
**both-failed → raw** result keeps the active provider's `intendedEngine` label.
The toggle is gated in the UI on **both** cloud keys being present; the ladder's
defensive check makes a stored `true` inert if either key is later removed.

**Local Mode is local-only** (the privacy guarantee): on → local, falling
back to raw on failure, **never** to cloud (cloud→cloud fallback is the `else`
branch only — Local Mode never crosses to a cloud provider). Off → cloud → (other
cloud, if fallback on) → raw. Audio-derived text leaves the Mac only in Cloud
Mode; with cloud fallback on, a failure can route the text to the *other* cloud
vendor (Anthropic ↔ OpenAI) before raw.

## Build / run

Menu-bar agent via SwiftUI `MenuBarExtra` (`.window` style) with
`LSUIElement = YES` (set as `INFOPLIST_KEY_LSUIElement` on the app
target). No dock icon, no main window. The `MenuBarExtra` icon is the
`waveform` systemImage. Multi-line caption `Text` in the fixed-width popover
needs `.fixedSize(horizontal: false, vertical: true)` or it truncates instead
of wrapping.

The popover is a **360pt dark, violet-accented, tabbed** panel (the "Kemsoft
Voice Popover" design), all in `UI/MenuBarContent.swift`. A persistent header
(app-icon logo via `NSApplication.shared.applicationIconImage` + "WhisprSoft" +
a live **static** status dot/text from `coordinator.state` — the dot is a
plain colored circle, no pulse animation (the old pulse rendered a square
artifact mid-cycle) — gear → Settings) sits above either the tabbed body or
the Settings screen:

- **Dictate** — a hero *status display* (NOT a button) driven by
  `coordinator.state`: idle shows the app icon + the active chord's keycaps
  (from `DictationShortcut.symbols`), recording the
  animated waveform + pulse ring, processing/model-loading the spinner, error
  the message. Below it a grouped card: a **Tone profile** row whose inline
  picker is the **only** place the active tone is chosen (sets
  `profiles.selectedID`, nil = Default), and an **Engine** row (from
  `@AppStorage("localMode")`) → Settings.
- **Tone** — management only (no selection): `profiles.items` as collapsed
  cards (up/down arrow pair + name + "Active" badge + description) that expand
  to edit name/instruction with Delete/Done. Reorder is **per-click up/down
  arrows** in the card's leading slot (`profiles.moveUp/moveDown`, each a
  one-step `swapAt`), disabled+dimmed at the list ends; the arrow Buttons
  consume their own taps so the row's `.onTapGesture` (expand) only fires
  elsewhere. (Drag-reorder was tried and abandoned after three failed runtime
  iterations.) Rows render in the shared `measuredScroll` like the other tabs.
- **Corrections** — `corrections.items` as inline-editable rows (+ add/delete).
- **Settings** (gear) — custom Local-mode toggle (`localMode`), the real
  Keychain key add/remove flow, an interactive **dictation-shortcut recorder**
  (`shortcutSettingRow`: shows the active chord's keycaps + a "Change" affordance;
  while recording it **disarms the global tap** (`coordinator.stopHotkey()`) so
  the session-level tap — which sees keystrokes before the local monitor — can't
  engage a phantom dictation on an overlapping chord, then a local `NSEvent`
  monitor captures the next chord via `DictationShortcut(nsEvent:)` — bare Escape
  cancels, a modifier-less press shows a hint and keeps recording; on save/cancel
  it re-arms via `coordinator.startHotkey()` (which reloads the new binding).
  "Reset to default" restores ⌃⌥Space and pushes it to the live tap via
  `coordinator.updateHotkey()`. The binding persists in
  `@AppStorage(DictationShortcut.storageKey)`), a **Cloud fallback** toggle
  (`providerFallbackSettingRow`, `@AppStorage("cloudProviderFallback")`, between
  the ChatGPT-key row and the shortcut recorder) **enabled only when both cloud
  keys are present** (reuses `hasStoredKey`/`hasOpenAIKey`; disabled + dimmed with
  a "add both keys" hint otherwise), Quit, and the bundle
  `CFBundleShortVersionString`. A **Show logs** toggle (`@AppStorage("showLogs")`)
  reveals the per-dictation diagnostic log (`logsSection`/`logEntryRow`), with a
  red "raw fallback" tag and an amber "fallback" tag
  (`entry.usedProviderFallback`, mutually exclusive with raw on success).

The **dictation log** (`DictationLogStore`, `@MainActor @Observable`, owned by
`AppDelegate`) **persists** to `UserDefaults["dictationLog"]` as JSON (mirroring
`CorrectionsStore`): loaded at launch via a nonisolated `loadEntries()` default
initializer (so the `nonisolated init()` works as a Coordinator default argument),
`save()` on every `record`/`clear`, capped at 100 (ring buffer, newest first).
Persistence is privacy-safe because `DictationLogEntry` holds **only**
counts/timings/engine metadata — never transcript content, so no dictated text
reaches disk (`id` is omitted from `CodingKeys`; it's only SwiftUI list identity).
The "Show logs" toggle controls visibility only; collection and persistence always
happen. Cleared on demand.

Persistence `.onChange` hooks (`corrections.items`, `profiles.items`,
`profiles.selectedID`) and the permission/hotkey hooks live on the
always-mounted container, not a tab. Tabs scroll within a content-measured
height capped at ~444pt (a `.window` MenuBarExtra sizes to content, so the
scroll area needs a determinate height — see the `HeightKey` preference).
`AccentColor.colorset` is set to the violet `#9A8BFF` so system controls tint
to match. The permission hard-gate is a redesigned in-popover `permissionsGate`
(in `MenuBarContent`, styled to match the panel, reusing `PermissionsManager`):
a header, an accent-tinted blocking notice, two permission cards (Microphone +
Accessibility; status glyph + why + Grant/Open-Settings actions — Accessibility
is a single **Grant** button), and a Re-check/Quit footer. Shown until
`allGranted`; the panel chrome (`.frame(width: 360)`, `popoverBackground`,
`.preferredColorScheme(.dark)`) is hoisted to the outer container so the gate
and granted body share it. There is **no** Permissions section in Settings —
the `.onAppear { permissions.refresh() }` auto re-gating handles revocation.
`OnboardingView` was removed.

The product file name, target name, and `PRODUCT_NAME` are all `WhisprSoft`,
producing `WhisprSoft.app`; the bundle id is `com.whisprsoft`.

The app icon is generated reproducibly by `Tools/make_appicon.swift` (kept at
repo root, outside the synchronized source group so it isn't compiled into the
app); re-run it (`swift Tools/make_appicon.swift`) to regenerate after a design
change.

Signing: local dev uses **Apple Development / automatic** signing (set your
own team), which is sufficient for Accessibility now that the sandbox
is off. Developer ID + notarization is the eventual distribution path and
is deferred — not required for local testing.

To verify entitlements (e.g. the mic entitlement) use a normally
dev-signed build and `codesign -d --entitlements :- <app>`. Do **not**
pass `CODE_SIGNING_ALLOWED=NO` — it produces a linker-signed binary with
no embedded entitlements, a false negative. The usage string, by
contrast, is an Info.plist key: `plutil -extract … Info.plist`. When
checking for concurrency warnings, grep the full build log (warnings
don't fail the build and `tail` hides them) and `clean build` so changed
files actually recompile.
