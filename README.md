# Clipper v2

A personal, iPhone-only memory system. Start Clipper, switch to Spotify or a game, and it
keeps listening through the iPhone's built-in microphone — detecting speech, transcribing
it on device, working out who said what, grouping it into conversations, summarising them,
and making all of it searchable with a chain back to the audio.

Single user. No account, no sync, no analytics, no cloud processing, and no network client
of any kind. Everything is Apple-native and stays on the phone.

---

## What it does

- **Listens while you use other apps.** `.playAndRecord` with `.mixWithOthers` and the
  `audio` background mode, pinned to the built-in mic. No AirPods, no Bluetooth.
- **Finds speech in the noise.** A rolling 5-minute buffer, a four-feature VAD over a
  learned noise floor, conservative spectral subtraction, and `SoundAnalysis` to down-rank
  music. Silence costs almost nothing.
- **Transcribes on device.** `SFSpeechRecognizer` with `requiresOnDeviceRecognition`. Audio
  never leaves the phone.
- **Tells voices apart, carefully.** Clustering on timbre, with naming, renaming and
  merging as your repair — and "Unknown voice" when it does not know.
- **Builds memories.** Decisions, tasks, facts, preferences, questions, events and more,
  deduplicated, reinforced when repeated, and **superseded — never overwritten** when you
  change your mind. A reversal records a contradiction you can resolve.
- **Answers questions with evidence.** Answer → memory → conversation → transcript line →
  timestamp → audio, labelled *directly stated*, *summarised*, *inferred*, *uncertain*,
  *contradictory* or *unsupported*. When there is nothing to go on, it says so.
- **Surfaces itself natively.** Home Screen widget, Dynamic Island Live Activity, Core
  Spotlight, App Intents and Shortcuts.

## Documentation

| Document | What it covers |
|---|---|
| [CLIPPER_IMPLEMENTATION_PLAN.md](CLIPPER_IMPLEMENTATION_PLAN.md) | The architecture and the phased plan this was built from |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Targets, the pipeline, the four memory layers, every model field |
| [docs/AUDIO.md](docs/AUDIO.md) | Audio session, background behaviour, interruptions, the rolling buffer, speech detection |
| [docs/SEARCH.md](docs/SEARCH.md) | The inverted index, ranking, question parsing, evidence chains, Spotlight, App Intents |
| [docs/WIDGETS.md](docs/WIDGETS.md) | The widget, the Live Activity, and the app-group reality |
| [docs/TESTING.md](docs/TESTING.md) | 191 tests, what they cover, and the defects they found |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Measured latencies, storage growth, signposts |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | What iOS does not allow, and what depends on device, SDK or permission |
| [BUILD-WINDOWS.md](BUILD-WINDOWS.md) | Building the IPA from Windows with no Mac, and sideloading with AltStore |

## Layout

```
Clipper/                    the app
├── ClipperApp.swift        @main; owns the singletons, runs recovery at launch
├── Models/                 Clip, RecorderState, AppSettings, ClipperConfig
├── Audio/                  session, engine, rolling buffer, VAD, enhancement,
│                           segmentation, downmix, sound classification
├── Pipeline/               the job queue and everything it runs: transcription,
│                           speakers, conversations, extraction, memories, summaries
├── Store/                  SwiftData models, the @ModelActor store, DTOs, migration
├── Search/                 tokeniser, index, ranking, question parsing, answers, Spotlight
├── Surfaces/               Live Activity, widget snapshot, Spotlight plumbing
├── Intents/                App Intents and Shortcuts
├── Storage/, Playback/     audio library and clip playback
├── Views/                  18 SwiftUI screens
└── Support/                logging and signposts

Shared/                     value types used by the app AND the widget extension
ClipperWidgets/             the WidgetKit extension (widget + Live Activity UI)
ClipperTests/               191 tests, including a deliberately messy synthetic corpus
project.yml                 XcodeGen project definition (three targets)
```

## Building

On Windows, with no Mac: push to any branch. The workflow in
`.github/workflows/build-ipa.yml` runs the whole suite on a macOS runner, builds an
unsigned Release IPA for `iphoneos`, checks the bundle, and uploads it as
**`Clipper-v2-unsigned-ipa`**. AltStore signs it locally with your own Apple ID.
[BUILD-WINDOWS.md](BUILD-WINDOWS.md) has the details.

On a Mac:

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open Clipper.xcodeproj
```

## The design decisions worth knowing

**One continuous audio tap, no timers.** Segmentation happens *inside* the stream:
`SegmentWriter` counts frames and splits the boundary buffer sample-exactly, so rotation is
gapless. A timer-driven stop/start recorder is the usual approach and it loses audio at
every boundary.

**Work is persisted before it is attempted.** Every pipeline step is a `JobRecord` with a
payload, a priority and an attempt count. Nothing is lost when iOS suspends or kills the
app, and jobs left running by a dead process are requeued at launch.

**Search is arithmetic, not a model.** An inverted index with BM25-style IDF, a bounded
candidate set, and a semantic rerank that only ever sees those candidates. No language
model runs over the database to answer a question — that is what keeps search instant after
years of data.

**History is append-only.** A changed decision inserts a new revision and marks the old one
superseded, with a contradiction recorded. `revisionChain(for:)` reads forwards. Nothing is
overwritten and nothing silently wins.

**Uncertainty is stored, not smoothed away.** Confidence, audio quality, SNR, speaker
confidence and an assertion label live on every row, and the UI shows them. A low-confidence
line is kept and marked; an unknown voice stays unknown; an answer with no evidence says so.

## Privacy

- The microphone is used only while you have started a session.
- Apple's orange microphone indicator is always shown. Clipper makes no attempt to hide it.
- Nothing is uploaded, because there is no upload path: no network client, no account, no
  analytics, no crash reporting.
- Audio, transcripts, memories and the index all live in the app's own container.
- Recording is something you start. There is no stealth mode.
