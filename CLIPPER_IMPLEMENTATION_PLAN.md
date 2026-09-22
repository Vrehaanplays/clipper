# Clipper v2 — Implementation Plan

Personal, single-user, iPhone-only memory system. This document records the state of the
repository before the change, the architecture that was chosen, why each choice was made,
and the phases that were executed. It is a record of work done, not a proposal.

---

## 1. Repository inspection (before)

Commit `0be816f`, branch `master`, remote `github.com/Vrehaanplays/clipper`.

| Question | Finding |
|---|---|
| Targets / schemes | One: `Clipper` (application), one scheme `Clipper`. Defined by `project.yml` (XcodeGen); **no `.xcodeproj` is committed** and none can be authored on Windows. |
| Deployment target / SDK | iOS 18.0, `SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY minimal`, iPhone only (`TARGETED_DEVICE_FAMILY 1`). CI builds with the newest Xcode on the runner (26.6 at last run). |
| SwiftUI structure | `ClipperApp` → `ContentView` (single screen) + `ClipsView` / `SettingsView` sheets. Long-lived singletons injected as `@EnvironmentObject`. `GlassStyle.swift` wraps iOS 26 Liquid Glass behind `#if compiler(>=6.2)` + `if #available(iOS 26.0, *)` with `.ultraThinMaterial` fallbacks. |
| Entitlements / capabilities | **None, deliberately.** Background audio is the `UIBackgroundModes: [audio]` Info.plist key, not an entitlement. No entitlements file is what lets AltStore re-sign with a free Apple ID. |
| Audio implementation | `AudioRecorder` (490 lines): one continuous `AVAudioEngine` input tap; `SegmentWriter` counts frames and **splits the buffer that crosses the segment boundary**, so rotation is sample-exact and gapless with no timer anywhere. Session: `.playAndRecord`/`.default` with Bluetooth + speaker options, 100 ms IO buffer. Watchdog (15 s) is a recovery net only. |
| Persistence | Files only. `ClipStore` owns `Application Support/Clips`, rebuilds state from disk on launch, purges `.part` debris, trims to the newest N clips. No database. |
| Dependencies | Zero. Apple frameworks only. |
| What already works | The rotation mechanism, interruption/route-change/media-reset recovery, crash recovery, atomic `.part` → `.m4a` finalisation, honest state machine, unsigned-IPA CI on a macOS runner. |

### Preserved, extended, replaced

- **Preserved unchanged:** the frame-counted rotation core (`SegmentWriter`, buffer splitting,
  `.part` finalisation), the three-queue threading model, the "never claim Recording when the
  engine is stopped" rule, `GlassStyle`, `AudioPlayer`, the XcodeGen + unsigned-IPA route.
- **Extended:** `AudioSessionManager` (built-in mic pinning, `.mixWithOthers` so Spotify keeps
  playing, optional voice processing), `AudioRecorder` (VAD, utterance emission, pause/resume,
  session records), `RecorderState` (9 states instead of 7), `AppSettings`, `ClipsView`.
- **Replaced:** the single-screen UI (now a 5-tab app), `ClipStore`'s role (now only the
  temporary rolling buffer; durable data moved to SwiftData).
- **Added:** everything from §3 onward.

---

## 2. Framework decisions

| Need | Chosen | Why not the alternative |
|---|---|---|
| Capture | `AVAudioEngine` input tap | Already proven here; gives raw PCM for VAD, which `AVAudioRecorder` does not. |
| Session | `AVAudioSession .playAndRecord` + `.mixWithOthers` + `.builtInMic` preferred input | `.mixWithOthers` is the only public way to let Spotify/a game keep playing while we record. Bluetooth options were **removed** — the spec requires the built-in mic. |
| Preprocessing / VAD | `Accelerate` (`vDSP` FFT, 512-pt) | iOS has **no public VAD API**. `SFSpeechRecognizer` has no streaming VAD we can gate on, and running it continuously is the battery cost we are avoiding. |
| Non-speech rejection | `SoundAnalysis` `SNClassifySoundRequest(.version1)` | Apple's built-in classifier knows `speech`, `music`, `typing`, … — exactly what is needed to down-rank game/Spotify bleed. Gated behind the cheap VAD so it only runs on candidate audio. |
| Transcription | `Speech` / `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` | See §7 for why `SpeechAnalyzer` (iOS 26) is behind a protocol but not adopted yet. |
| Entities / topics / embeddings | `NaturalLanguage` (`NLTagger`, `NLTokenizer`, `NLEmbedding.sentenceEmbedding`) | On-device, free, no model shipping. |
| Summaries | `FoundationModels` when available, deterministic extractive fallback otherwise | Availability-gated at runtime **and** compile time (`#if canImport`). Never the only path. |
| Database | **SwiftData** with flat models + UUID foreign keys | Core Data by hand buys nothing here; raw SQLite would mean hand-rolling migrations. Relationships were deliberately *not* used — see §4. |
| Full-text search | Own inverted index in SwiftData (`TokenPosting`) + BM25-style scoring | FTS5 needs `import SQLite3` C interop and a second schema to migrate. Measured cost of the posting-list approach is in `docs/PERFORMANCE.md`. |
| Semantic search | `NLEmbedding` vectors + `vDSP` cosine over a **bounded candidate set** | Never a full-table vector scan. |
| System search | `CoreSpotlight` | — |
| Voice / automation | `AppIntents` + `AppShortcutsProvider` | — |
| Widget | `WidgetKit` | — |
| Dynamic Island | `ActivityKit` | — |
| Observability | `OSLog` + `OSSignposter` | — |

No third-party dependencies were added. Nothing private is called.

---

## 3. Pipeline

```
Built-in microphone (AVAudioEngine tap, one continuous stream)
  │
  ├─► SegmentWriter ──► Rolling/  (temporary audio, newest 6 × 5 min = 30 min)
  │
  └─► SpectralAnalyzer (vDSP FFT: SNR, flatness, centroid, noise floor)
        └─► VoiceActivityDetector (hysteresis + hangover)
              └─► UtteranceAssembler (0.6 s pre-roll ring buffer, 0.8 s hangover,
              │     min 0.5 s, max 28 s, 16 kHz mono downmix)
              └─► SoundClassifier (speech vs music/noise confidence)
                    └─► Utterance job  ──► PipelineCoordinator (bounded queue, depth 24,
                                            drop-oldest backpressure, 2 retries, cancellable)
                          ├─ 1. SpeechEnhancer     (spectral gain, overlap-add)
                          ├─ 2. TranscriptionService (on-device SFSpeechRecognizer)
                          ├─ 3. SpeakerAttributor   (log-mel centroid clustering)
                          ├─ 4. ConversationSegmenter (gap + speaker-set + topic shift)
                          ├─ 5. ContentExtractor    (NL entities, topics, sentence kinds)
                          ├─ 6. Evidence/  (retained utterance audio, m4a)
                          └─ 7. SearchIndexer + SpotlightIndexer
                                └─ on conversation close ──►
                                      Summarizer → MemoryBuilder → GraphBuilder
                                      → SummaryRollups (day / week / topic / project)
```

Every stage is incremental and idempotent, keyed by the utterance UUID, so a retry or a
relaunch mid-pipeline cannot duplicate work. `ProcessingState` on each record is the
resume point.

---

## 4. Data model

Four layers, one SwiftData store, **flat models joined by `UUID`** rather than SwiftData
relationships. Relationships were rejected on purpose: they are the main source of
SwiftData faulting crashes and migration breakage, they make background-actor writes
unsafe to hand to the UI, and every join this app needs is a single indexed fetch.

| Layer | Models |
|---|---|
| Raw | `SessionRecord`, `AudioSegmentRecord` |
| Transcript / conversation | `TranscriptSegmentRecord`, `SpeakerRecord`, `ConversationRecord`, `ExtractionRecord` |
| Curated memory | `MemoryRecord`, `SummaryRecord`, `ContradictionRecord` |
| Brain map | `GraphNodeRecord`, `GraphEdgeRecord` |
| Infrastructure | `IndexedDocumentRecord`, `TokenPostingRecord`, `JobRecord`, `SchemaMetaRecord` |

Provenance is not optional: every derived record carries `sourceKind`, `sourceIDs`,
`confidence` and `assertion` (`stated` / `summarised` / `inferred` / `uncertain` /
`contradictory` / `unsupported`). Nothing is overwritten — `MemoryRecord.supersedesID` and
`ContradictionRecord` keep the history, and `revision` increments.

Full field list: `docs/ARCHITECTURE.md`.

---

## 5. Concurrency

- Audio thread: copies its buffer, computes nothing heavier than one 512-pt FFT, hands off.
- `control` serial queue: engine + session mutation only.
- `writer` serial queue: `SegmentWriter` and utterance file I/O only.
- `PipelineCoordinator`: an `actor` with a bounded queue and structured `Task` cancellation.
- `DatabaseWriter`: a `@ModelActor`. **All** mutation. Returns value-type DTOs, never models.
- Main actor: every `@Published` mutation and every view read.

No `ModelContext` is ever shared across actors; no `@Model` instance ever crosses one.

---

## 6. Phases executed

1. Project restructure: three targets (`Clipper`, `ClipperWidgets`, `ClipperTests`), app group, entitlements, plists, CI for tests + IPA.
2. Foundation: `Log`, settings, states, shared widget/activity types.
3. Audio: session rework, spectral analysis, VAD, enhancement, utterance assembly, classifier, recorder integration.
4. Store: SwiftData schema, database bootstrap + corruption recovery, `@ModelActor` writer, file store with the three audio lifecycles.
5. Pipeline: coordinator, transcription, speakers, conversations, extraction, summaries, memories, graph.
6. Search: tokenizer, inverted index, embeddings, hybrid ranking, filters, question answering with evidence chains, Spotlight.
7. Surfaces: Live Activity, widget, App Intents, Shortcuts.
8. UI: 5 tabs, 18 screens.
9. Tests: 12 suites incl. messy synthetic corpora and a large-dataset performance test.
10. Docs, CI green, IPA.

---

## 7. Deliberate non-adoptions (with reasons)

- **`SpeechAnalyzer` / `SpeechTranscriber` (iOS 26).** Better quality and word timings, but it
  cannot be verified from this machine and the deployment target is iOS 18, so it would need the
  `SFSpeechRecognizer` path anyway. `Transcribing` is a protocol with one conformance today;
  adding a second is the whole change. Documented in `docs/LIMITATIONS.md`.
- **Real speaker diarization.** There is no public Apple diarization API. What is implemented is
  log-mel centroid clustering, which is honest about being weak: every attribution carries a
  confidence and is shown as uncertain in the UI until the user names the speaker.
- **Echo cancellation by default.** `setVoiceProcessingEnabled(true)` genuinely helps with
  speaker bleed, but it ducks or interrupts other apps' audio, which breaks the primary use
  case. It is a setting, default off, with the trade-off stated in the UI.
- **Cloud anything.** No accounts, no uploads, no analytics, no network code at all.

---

## 8. Outcome

All ten phases are done. The final state, measured rather than asserted:

| | |
|---|---|
| Swift | ~22 000 lines across three targets |
| Tests | 191, all passing |
| Compiler warnings | 0 |
| SwiftData models | 15 across four memory layers |
| SwiftUI screens | 18 |
| Search latency over 1 440 documents | 33.9 ms mean, 43.5 ms worst |
| Runtime dependencies | none |
| IPA | ~2.0 MB unsigned, widget extension embedded |

CI runs the suite on a simulator and then builds the unsigned Release IPA on every push;
the artifact only ever comes from a green run.

### Defects the test suite found in the implementation

Writing the tests was not a formality — twelve real defects came out of it, including three
that made headline features silently inert: keyword extraction returned nothing wherever
`NLTagger` lacked a model (so there were no graph nodes and no subject keys at all), subject
keys never matched across conversations (so supersession never fired), and search answered
questions about subjects that had never been discussed. All are listed with their causes in
`docs/TESTING.md` §4.

### Documentation

`docs/ARCHITECTURE.md`, `docs/AUDIO.md`, `docs/SEARCH.md`, `docs/WIDGETS.md`,
`docs/TESTING.md`, `docs/PERFORMANCE.md`, `docs/LIMITATIONS.md`, plus `README.md` and
`BUILD-WINDOWS.md`.

### What remains device-dependent

Nothing here has run on an iPhone. The audio-session paths that a simulator cannot
verify — Spotify coexistence, a game in the foreground, screen lock, call interruption,
Dynamic Island presentation, on-device recogniser availability, Foundation Models
availability, battery and thermals — are listed as a checklist in
`docs/LIMITATIONS.md` §8.
