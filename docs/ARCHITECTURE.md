# Clipper v2 — architecture and data model

Clipper is a single-user, iPhone-only memory system. It listens through the built-in
microphone while you use other apps, transcribes the speech it hears on device, groups it
into conversations, builds memories out of it, and makes all of it searchable with a chain
back to the audio.

Everything here is Apple-native and on device. There is no account, no analytics, no cloud
processing, and no third-party dependency of any kind at runtime. The only external tool
is XcodeGen, which generates the Xcode project from `project.yml` at build time.

---

## 1. Targets

| Target | Kind | Sources |
|---|---|---|
| `Clipper` | iOS app | `Clipper/`, `Shared/` |
| `ClipperWidgets` | WidgetKit extension | `ClipperWidgets/`, `Shared/` |
| `ClipperTests` | Unit test bundle | `ClipperTests/` |

`Shared/` is compiled into both the app and the widget extension. It holds only value
types — the snapshot the widget renders, the phase enum, the deep-link vocabulary, the
Live Activity attributes — so the widget never links the store, the audio engine or
anything else that could make a timeline reload expensive.

Deployment target is **iOS 18.0**. Everything newer is feature-detected at runtime rather
than assumed; see [LIMITATIONS.md](LIMITATIONS.md).

## 2. The pipeline

```
built-in mic
  → AVAudioEngine input tap (continuous, frame-counted)
  → rolling buffer          (SegmentWriter: ~5 min of audio, ~30 min retention)
  → downmix to 16 kHz mono  (AudioDownmixer)
  → preprocessing           (SpeechEnhancer: noise estimate, spectral subtraction)
  → VAD                     (VoiceActivityDetector: SNR + spectral shape)
  → speech segmentation     (SpeechSegmenter: pre-roll, hangover, utterance files)
  → PendingUtterance ──────► persisted job queue (JobRecord)
        ↓
  → transcription           (SFSpeechRecognizer, on-device only)
  → sound classification    (SoundAnalysis: is this speech or is it music?)
  → speaker attribution     (SpeakerFeatures + nearest-centroid clustering)
  → conversation assignment (gap + topic-shift segmentation)
  → content extraction      (ContentExtractor: entities, keywords, extractions)
  → memory building         (MemoryBuilder: dedupe keys, supersession)
  → summarisation           (Foundation Models where available, extractive otherwise)
  → search indexing         (inverted index + optional embedding)
  → brain-map update        (nodes and edges, each with its evidence)
  → widget snapshot + Live Activity + Core Spotlight
```

Each arrow after `PendingUtterance` is a step inside a **job**, not a call chain: the work
is persisted before it is attempted, so nothing is lost when the app is suspended or
killed. `PipelineCoordinator` is the single actor that runs the queue; it applies
backpressure by quality (a low-SNR utterance is dropped before a good one is), retries up
to three times, and requeues jobs left `running` by a previous process on launch.

The main thread does none of this. The audio tap runs on its own real-time thread, the
pipeline is an actor, the store is a `@ModelActor`, and the UI observes a small
`@MainActor` status object (`PipelineStatus`).

## 3. The four memory layers

The spec's four layers are four groups of SwiftData models.

| Layer | Models | What it holds |
|---|---|---|
| **Raw** | `SessionRecord`, `AudioSegmentRecord` | When Clipper listened, and which audio files exist with what measured quality |
| **Transcript** | `TranscriptSegmentRecord`, `SpeakerRecord`, `ConversationRecord`, `ExtractionRecord` | What was said, by which voice, grouped into conversations, with the claims pulled out of it |
| **Curated memory** | `MemoryRecord`, `SummaryRecord`, `ContradictionRecord` | What it means, with revisions, supersession and disagreements kept |
| **Brain map** | `GraphNodeRecord`, `GraphEdgeRecord` | People, topics and projects, and the relationships between them |
| *(supporting)* | `IndexedDocumentRecord`, `TokenPostingRecord`, `JobRecord`, `StoreMetaRecord` | Search index, work queue, store bookkeeping |

**Every generated thing points back at what supports it.** A `MemoryRecord` carries
`sourceKind` + `sourceIDs`; a `SummaryRecord` does the same; a `GraphEdgeRecord` carries
`evidenceIDs` and reports `isExplainable` when it has none. `AnswerService` walks those
pointers to build an evidence chain — answer → memory or summary → conversation →
transcript segment → timestamp → audio file — and says so plainly when a link is missing
(the audio has expired, the edge has no evidence).

### 3.1 Why flat models with UUID foreign keys

None of these models declares a SwiftData relationship. Every link is a `UUID` (or a
`[String]` of UUIDs) resolved by an indexed fetch.

This is deliberate. Relationship faulting pulls object graphs into memory in ways that are
hard to bound, and the one thing this app must guarantee after years of data is that no
screen loads more than it shows. Flat models make every read an explicit, indexed,
paginated fetch, and they make the migration story simple. The cost is that the store
layer does joins by hand; that code is in `ClipperStore+*.swift` and is the only place
allowed to do it.

### 3.2 Why enums are stored as raw strings

Every enum-valued column is a `String` (`kindRaw`, `assertionRaw`, `stateRaw`, …) with a
computed accessor beside it. A stored enum whose cases change is a migration; a stored
string whose values change is not. Unknown values degrade to a documented default rather
than failing to load.

### 3.3 Actor isolation and DTOs

`ClipperStore` is a `@ModelActor`. `PersistentModel` instances are not `Sendable`, so
**nothing** returns a record. Every public method returns a value-type DTO (`MemoryDTO`,
`TranscriptLineDTO`, …) defined in `Store/DTOs.swift` and mapped in `Store/Mapping.swift`.
That is what lets SwiftUI hold results across suspension points without data races, and it
is why the whole app compiles with zero concurrency warnings.

### 3.4 Field reference

Types are Swift types; `raw` columns are shown as the enum they carry.

**`SessionRecord`** — `id`, `startedAt`, `endedAt?`, `speechSeconds`, `utteranceCount`,
`interruptionCount`, `inputName?`, `usedBuiltInMic`, `otherAudioPlaying`. Indexed on
`startedAt`. `isOpen` is `endedAt == nil`.

**`AudioSegmentRecord`** — `id`, `sessionID`, `kind` (`rollingClip` / `utterance`),
`filename`, `startedAt`, `endedAt`, `sampleRate`, `byteSize`, `meanSNRDB`, `peakLevelDB`,
`noiseFloorDB`, `speechRatio`, `speechConfidence`, `musicConfidence`, `classifierLabel?`,
`processingState`, `audioAvailable`. Indexed on `startedAt`, `sessionID`, `filename`.
`audioAvailable` is how an expired file is reported as gone instead of linked.

**`TranscriptSegmentRecord`** — `id`, `sessionID`, `conversationID?`, `audioSegmentID?`,
`speakerID?`, `startedAt`, `endedAt`, `index`, `text`, `confidence`, `audioQuality`,
`speakerConfidence`, `assertion`, `processingState`, `createdAt`, `revision`,
`languageCode?`, `isLowConfidence`, `originalText?`, `wordTimings`. Indexed on `startedAt`,
`sessionID`, `conversationID`, `processingStateRaw`. `originalText` preserves what the
recogniser said when you correct a line, so an edit never destroys the original.

**`SpeakerRecord`** — `id`, `displayName?`, `createdAt`, `updatedAt`, centroid embedding,
`sampleCount`, `totalSpeechSeconds`, `promptState` (`unasked` / `asked` / `skipped` /
`askLater` / `named`), `colorIndex`, `previousNames`. `label` falls back to
"Unknown voice"; `identityConfidence` grows with evidence and never reaches certainty.

**`ConversationRecord`** — `id`, `sessionID`, `startedAt`, `endedAt`, `title`,
`summaryID?`, `segmentCount`, `speechSeconds`, `confidence`, `importance`, `isOpen`,
`closedAt?`, `speakerIDs`, `nodeIDs`.

**`ExtractionRecord`** — `id`, `transcriptSegmentID`, `conversationID?`, `speakerID?`,
`kind` (a `MemoryKind`), `text`, `subject?`, `confidence`, `assertion`, `createdAt`,
`occurredAt`. This is the bridge from transcript to memory: one row per claim the extractor
found in one line.

**`MemoryRecord`** — `id`, `kind`, `title`, `detail`, `confidence`, `assertion`,
`importance`, `createdAt`, `updatedAt`, `firstSeenAt`, `lastSeenAt`, `occurrenceCount`,
`revision`, `supersedesID?`, `supersededByID?`, `isArchived`, `isUserEdited`, `sourceKind`,
`sourceIDs`, `nodeIDs`, `subjectSpeakerID?`, `dedupeKey`, `embedding?`. Indexed on
`createdAt`, `kindRaw`, `dedupeKey`, `isArchived`, `lastSeenAt`.

**`SummaryRecord`** — `id`, `scope` (`conversation` / `day` / `week` / `topic` /
`project`), `key`, `title`, `text`, `bullets`, `createdAt`, `updatedAt`, `revision`,
`periodStart`, `periodEnd`, `confidence`, `assertion`, `sourceKind`, `sourceIDs`,
`generator` (`foundationModels` or `extractive`), `embedding?`. Idempotent on
`scope` + `key`: regenerating a day updates one row and bumps `revision`.

**`ContradictionRecord`** — `id`, `earlierMemoryID`, `laterMemoryID`, `explanation`,
`detectedAt`, `isResolved`, resolution fields.

**`GraphNodeRecord`** — `id`, `kind` (`person` / `topic` / `project` / …), `name`,
`normalizedName`, `createdAt`, `updatedAt`, `lastMentionedAt`, `mentionCount`,
`importance`, `refID?`, `refKind?`, `summaryID?`, `embedding?`. Unique per
`normalizedName` + `kind`, which is what keeps one subject from becoming five nodes.

**`GraphEdgeRecord`** — `id`, `sourceNodeID`, `targetNodeID`, `kind`, `weight`,
`confidence`, `createdAt`, `updatedAt`, `evidenceIDs`, `evidenceKind`.

**`IndexedDocumentRecord`** / **`TokenPostingRecord`** — see [SEARCH.md](SEARCH.md).

**`JobRecord`** — `id`, `kind`, `state`, `payload` (JSON), `createdAt`, `startedAt?`,
`finishedAt?`, `attempts`, `lastError?`, `priority`.

**`StoreMetaRecord`** — schema version, open count, last recovery. Used by the corruption
recovery path and shown in Diagnostics.

## 4. How a changed statement is recorded

This is the behaviour the rest of the design serves, so it is worth stating exactly.

Memories are deduplicated by a key. For most kinds the key is the **claim** — two different
facts are two memories. For `decision`, `preference`, `goal` and `project` the key is the
**subject** (`MemoryBuilder.subjectKeyedKinds`), built from the strongest topic word the
sentence shares with its conversation.

So when you decide one thing about Aurora and decide something else about Aurora an hour
later, the two collide on `decision|subject|aurora`. `ClipperStore.upsertMemory` then
compares substance by token overlap:

- **Same key, same substance** → reinforce. `occurrenceCount` grows, confidence approaches
  but never reaches 1, `sourceIDs` gains the new line (capped at 64 — earliest kept for
  "when did I first say this", most recent for the evidence view).
- **Same key, different substance, subject-keyed** → supersede. A new revision is inserted
  with `supersedesID` pointing back, the old row gets `supersededByID` and is marked
  `contradictory`, and a `ContradictionRecord` is written. Both revisions stay readable and
  `revisionChain(for:)` returns them oldest-first.
- **Same key, different substance, claim-keyed** → merge, and the assertion drops to
  `uncertain`, because the sources no longer agree.

Nothing is ever overwritten, and nothing silently wins.

## 5. Surfaces

- **App** — 18 SwiftUI screens (live clipping, timeline, conversations, transcript viewer,
  speakers, memory detail, search, evidence, people, topics, projects, brain map, unresolved
  items, settings, diagnostics). `AppRouter` maps a `ClipperDeepLink` onto a tab and a
  destination; every Spotlight result and every App Intent goes through it.
- **Widget** — reads one small JSON snapshot from the app group. See
  [WIDGETS.md](WIDGETS.md).
- **Live Activity** — Dynamic Island and Lock Screen, with pause and stop. Needs no app
  group, so it works on a free-Apple-ID sideload.
- **Core Spotlight** — memories, summaries and conversations, each with a
  `clipper://` deep link as its unique identifier.
- **App Intents** — start/stop/pause/resume clipping, search memories, memories about a
  person or topic, open today's timeline, open a memory, show the recent summary. These are
  what Shortcuts and Siri surface.

## 6. Observability

Every subsystem has an `OSLog` category (`Log.audio`, `Log.pipeline`, `Log.database`,
`Log.search`, `Log.surfaces`, `Log.model`), and the hot paths are wrapped in
`OSSignposter` intervals (`search`, `transcribe`, `summarize`, job execution) so they show
up as regions in Instruments. See [PERFORMANCE.md](PERFORMANCE.md) for what was measured.
