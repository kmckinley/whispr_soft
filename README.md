# WhisprSoft

A menu-bar dictation app for macOS. Hold the dictation shortcut (**⌃⌥Space** by
default, rebindable) to dictate; release, and your speech is transcribed and
pasted into whatever app is focused. Transcription runs **on-device** — your
audio never leaves the Mac.

## What it does

### Core dictation

- **Hold-to-talk dictation.** Hold the shortcut, speak, release — the app records
  while you hold the chord, then transcribes and types the result into the
  frontmost app.
- **Customizable shortcut.** Rebind the hold-to-talk chord in **Settings** — click
  **Change** and press a new combination of at least one modifier (⌃ ⌥ ⌘ ⇧) plus
  one regular key. It stays hold-to-talk; **Reset to default** restores ⌃⌥Space.
  The new binding takes effect immediately and persists across launches.
- **On-device transcription.** Speech is transcribed locally with
  [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift). The Whisper model
  downloads automatically on first use (a few hundred MB), then runs offline.
- **Menu-bar agent.** Runs as a menu-bar item with no dock icon and no main
  window. All settings (API keys, Local Mode, tone profiles, corrections) live in
  the menu.

### Cleanup, tone & language

- **Optional transcript cleanup.** The raw transcript can be lightly cleaned up
  (punctuation, grammar, filler removal) before it's pasted. Two modes:
  - **Cloud** — a hosted model via API. Choose the provider inline on the
    **Dictate** tab's **Engine** row: **Claude** (Anthropic, `claude-haiku-4-5`)
    or **ChatGPT** (OpenAI, `gpt-4.1-mini`). Each provider has its own API key,
    added in **Settings**; selecting a provider with no key yet sends you to
    Settings to add one. Switching providers takes effect on the next dictation.
    An optional **cloud fallback** (off by default, enabled in Settings, and only
    available once *both* cloud keys are set) makes a failure of the active
    provider automatically try the other one before falling back to the raw
    transcript.
  - **Local Mode** — a local [LM Studio](https://lmstudio.ai) instance at
    `127.0.0.1:1234`. No key, nothing leaves the Mac. Unchanged by the cloud
    provider choice — Local Mode is always on-device.
  - With no key and Local Mode off, the raw transcript is pasted as-is.
- **Tone profiles.** Pick a tone for the cleaned-up text from a user-editable list
  of profiles (full create/edit/delete/reorder). Each profile is a short
  instruction — e.g. "Professional" or "Casual" — that nudges the wording while
  the cleanup keeps your own sentences, structure, and meaning. Selecting
  **Default** leaves the cleanup unchanged. The active profile applies to both
  Cloud and Local cleanup, and changes take effect on the next dictation. Manage
  profiles on the **Tone** tab; choose the active one on the **Dictate** tab.
- **Tone shortcuts.** Assign up to **three** extra hold-to-talk chords that each
  dictate *once* in a specific tone — handy for switching to "Professional" for a
  single message without changing your active tone. Each is **⌃⌥ + a key** of your
  choosing, set in **Settings** (pick a tone, capture a key, or clear the slot);
  all three start empty. Holding one records exactly like the normal shortcut, but
  that one dictation uses the slot's tone and then everything reverts — your active
  tone is never touched. The recording indicator names the tone in use. If the
  bound tone is deleted, the slot quietly does nothing.
- **App tones.** Map specific apps to tones so the normal shortcut picks the tone
  automatically — e.g. Slack → "Client comms", Terminal → "Technical". When you
  dictate with the default shortcut, the tone follows the frontmost app if it's
  mapped; otherwise your selected tone applies. Set it up in **Settings** ▸ **App
  Tones**: pick a running app from **Add app…**, choose its tone, and you're done
  (one mapping per app, referencing any of your tone profiles). Tone shortcuts
  still override this — a held ⌃⌥ chord always wins over the app mapping. The
  recording indicator always names the tone in use, on every dictation. The
  feature ships empty; if a mapped tone is later deleted, that app falls back to
  your selected tone.
- **Target language.** Pick an output language from a fixed list of ~20 major
  languages, and the cleaned-up text is translated into it before it's pasted — so
  you can speak English and paste Spanish, French, Japanese, and so on. The
  default, **English (United States)**, means no translation (the text stays in
  the language you spoke). Translation rides on the same cleanup step, so it works
  in both Cloud and Local modes, and the choice takes effect on the next
  dictation. Pick the language on the **Dictate** tab. (Transcription itself is
  still English-tuned, so the reliable path is *speak English → paste another
  language*.)

### Accuracy

- **Keyword corrections.** A deterministic, user-editable find-and-replace list
  (e.g. fix a name Whisper consistently mishears) is applied *after* cleanup, so
  neither Whisper nor the cleanup model can reintroduce the wrong spelling. The
  same replacement terms double as a **transcription bias** — they're fed to
  Whisper as decoding hints, so your curated vocabulary (proper names, jargon) is
  more likely to be heard correctly in the first place.

### Capture & feedback

- **Quick-note scratchpad.** Dictate while the menu-bar popover is open — when
  there's no text field to paste into — and the cleaned-up result is appended to a
  note box that animates open on the Dictate tab instead of being pasted. Each
  burst adds a new line; the full pipeline (cleanup, tone, language, corrections)
  still runs. The note is hand-editable, has **Copy** and **Clear** actions, and
  is kept in memory for the session (it survives closing and reopening the
  popover, but is cleared on quit and never written to disk). Dictating with the
  popover closed pastes into the frontmost app exactly as before.
- **On-screen indicator.** An optional floating pill appears near the top of the
  screen while you dictate, showing the live recording/processing state and the
  tone in use — the one-shot tone of a held shortcut, an app-mapped tone, or your
  selected tone — handy when you're dictating into another app with the popover
  closed. Toggle it with **Show on-screen indicator** in Settings; it's on by
  default.
- **Activity graph.** Settings shows a bar chart of how much you've dictated over
  the last 90 days, with a **Day / Week / Month** view toggle. Only counts and
  dates are stored — never any transcript text — and the data persists across
  launches.

## Screenshots

The whole app lives in a single menu-bar popover with three tabs (Dictate, Tone,
Corrections) plus a Settings screen behind the gear.

### Dictate

<img src="https://raw.githubusercontent.com/kmckinley/whispr_soft/refs/heads/main/screenshots/dictate.png" alt="The Dictate tab" width="400">

The home screen and live status display. The hero shows the current pipeline
state — *Ready to dictate* at idle (with the hold-to-talk hint showing your
current shortcut, **⌃⌥Space** by default),
an animated waveform while recording, and a spinner while transcribing or
cleaning up. The card below is the quick-access control panel: **Language** picks
the output language — leave it on *English (United States)* for no translation,
or choose another to have the cleaned-up text translated before it's pasted;
**Tone profile** picks the active tone for cleanup (this is the only place the
active tone is chosen); and **Engine** picks the cleanup backend. In Cloud mode
it's an inline switcher between **Claude** and **ChatGPT** — selecting a provider
with a stored key switches instantly, while one without a key (shown with an
*Add key* hint) jumps to Settings so you can add it. In Local mode the row reads
*Local · LM Studio* and links to Settings.

If you dictate while this popover is open, the cleaned-up text is routed to a
**note box** that animates open just below the hero (instead of being pasted
into another app). Each burst appends a new line; the box is hand-editable and
has **Copy** and **Clear** actions. The note lives in memory for the session —
it survives closing and reopening the popover but is cleared on quit.

### Tone

<img src="https://raw.githubusercontent.com/kmckinley/whispr_soft/refs/heads/main/screenshots/tone.png" alt="The Tone tab" width="400">

Manage your rewrite tone profiles. Each profile is a short instruction that
nudges the wording of the cleaned-up text while preserving your own sentences,
structure, and meaning. Tap a card to expand and edit its name and instruction,
or delete it; use the up/down arrows to reorder. The profile marked **Active**
is the one currently selected on the Dictate tab. This tab is management only —
selecting the active tone happens back on Dictate.

### Corrections

<img src="https://raw.githubusercontent.com/kmckinley/whispr_soft/refs/heads/main/screenshots/corrections.png" alt="The Corrections tab" width="400">

A deterministic find-and-replace list applied *after* cleanup, just before the
text is pasted — so neither Whisper's mishearing nor the cleanup model can
reintroduce a wrong spelling. Useful for proper names Whisper consistently gets
wrong. Matching is
case-insensitive and whole-word; the replacement is inserted with exactly the
casing you type. Add and remove rows inline. The replacement terms are also fed
to Whisper as a decoding bias, so adding a correction helps that word get
recognized correctly during transcription, not just fixed afterward.

### Settings

<img src="https://raw.githubusercontent.com/kmckinley/whispr_soft/refs/heads/main/screenshots/settings.png" alt="The Settings screen" width="820">

Behind the gear, Settings is organized into four sub-tabs across the top —
**General**, **Shortcuts**, **App Tones**, and **Activity** (the same segmented
control as the body tabs). Opening the gear always lands on **General**.

**General** holds the main configuration card: the **Local mode** toggle (route
cleanup to a local LM Studio instance instead of the cloud), the **Claude API
key** and **ChatGPT API key** add/remove flows (each stored in the Keychain,
shown here as Connected), the **Cloud fallback** toggle (if your active cloud
provider fails, automatically try the other one before the raw transcript — only
enabled once *both* the Claude and ChatGPT keys are set; if you later remove a key
it disables again), the **Show on-screen indicator** toggle (the floating
dictation pill near the top of the screen — on by default), the **Show logs**
toggle (whose log list lives on the Activity sub-tab), and the **Dictation
shortcut** recorder (click **Change** to rebind the hold-to-talk chord — at least
one modifier plus a key — or **Reset to default** for ⌃⌥Space). Below the card are
**Quit** and the app version. Add whichever cloud provider's key you plan to use;
switch between them from the Dictate tab's Engine row.

**Shortcuts** holds the **Tone shortcuts** section: three slots, each pairing a
tone with a **⌃⌥ + key** chord (the recorder accepts only that combination) for a
one-shot tone dictation, and clearable back to unassigned. A chord that collides
with the dictation shortcut or another slot is rejected with an inline hint.

**App Tones** holds the **App tones** section — map an app to a tone so the normal
shortcut switches tone automatically based on the frontmost app (use **Add app…**
to pick a running app and its tone; tone shortcuts still override it).

**Activity** holds the activity graph plus — when **Show logs** (on General) is on
— a per-dictation diagnostic log. The graph is a bar chart of delivered
dictations over the last 90 days with a **Day / Week / Month** view toggle and a
running total; it stores only counts and dates (never any transcript text), and
both the data and the chosen view persist across launches. Each log entry reports
which engine and model ran, whether cleanup fell back to the raw transcript (a red
*raw fallback* tag) or switched to the other cloud provider (an amber *fallback*
tag), the per-stage timings (speech-to-text, cleanup, and total processing), the
input→output character counts, where the text went (pasted or sent to the note),
and the outcome (OK / no audio / error). Logs are **saved between sessions**
(stored on this Mac and restored at launch) and can be cleared at any time; the
toggle only controls whether they're shown. Entries never contain the transcript
text itself — only counts, timings, and engine metadata.

## Privacy

- **Audio is always transcribed locally and never leaves your Mac.**
- The **text** transcript is sent to a cloud provider (Anthropic for Claude, or
  OpenAI for ChatGPT) **only** when Cloud cleanup mode is active *and* the
  selected provider's API key is set. In every other configuration the transcript
  stays on the Mac.
- **With Cloud fallback enabled,** a failure of the active cloud provider can
  route the (text) transcript to the *other* cloud vendor — Anthropic ↔ OpenAI —
  before it falls back to the raw transcript. This means your dictated text may
  reach whichever of the two vendors succeeds. The toggle is off by default and
  only available once both keys are set; leave it off if you want the transcript
  to go to exactly one vendor.
- **Local Mode is local-only.** If the local model is unreachable or fails, it
  falls back to pasting the raw transcript — **never** to the cloud (the cloud
  fallback above applies to Cloud mode only). Audio-derived text leaves the Mac
  only in Cloud mode.
- The cloud API keys are stored in the login **Keychain** (entered through the
  menu), never in source or config files.

## Requirements

- macOS **14** or later.
- **Xcode 26.5** to build.

## Build & run

1. Clone the repo and open `WhisprSoft.xcodeproj` in Xcode.
2. **Forkers must set their own signing identity.** In the target's
   **Signing & Capabilities**, select your own **Development Team** and change
   the **bundle identifier** to one you own. The committed project carries the
   original author's team id, which won't sign on your machine. (The App Sandbox
   is intentionally off and Hardened Runtime is on — Accessibility and synthetic
   keystroke injection are unsupported under the sandbox.)
3. Build and run. On first launch, grant the two required permissions (below).

### Permissions

WhisprSoft can't run until both are granted. While either is missing, the
popover shows only a **permissions gate** (a card for each permission, with its
status and a Grant action) — the normal tabs and controls are hidden, so a
dictation is unreachable. The gate re-evaluates automatically every time you
open the popover: granting un-gates it, revoking re-gates it.

- **Microphone** — to record your voice. Granted inline via the standard prompt.
- **Accessibility** — to paste the transcribed text into the focused app
  (synthetic ⌘V). A single **Grant** button triggers the system trust prompt
  (which itself offers to open System Settings); the gate re-checks the next
  time you open the popover.

### Optional: transcript cleanup

- **Cloud** — add an API key in Settings for your chosen provider: an Anthropic
  key for **Claude** (`claude-haiku-4-5`) or an OpenAI key for **ChatGPT**
  (`gpt-4.1-mini`). Pick the provider on the Dictate tab's Engine row; the
  transcript is cleaned up by it and pasted.
- **Local** — run LM Studio at `127.0.0.1:1234` with a model loaded, then enable
  **Local Mode** in the menu. Cleanup runs entirely on your machine.

## License

Copyright 2026 The WhisprSoft Authors. Licensed under the Apache License, Version 2.0.

This project is released under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
See the [`LICENSE`](LICENSE) file for the full text.
