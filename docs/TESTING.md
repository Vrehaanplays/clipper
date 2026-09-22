# Test results

Run on the GitHub Actions `macos-latest` runner, Xcode 26.6, iPhone Air simulator on
iOS 26.5, Debug configuration.

```
Executed 191 tests, with 0 failures
Compiler warnings: 0
```

The suite and the Release device build both run on every push
(`.github/workflows/build-ipa.yml`). A failing test fails the build, so the IPA artifact
only ever comes from a green run.

---

## 1. What each suite covers

| Suite | Tests | Covers |
|---|---:|---|
| `AudioSessionPlanTests` | 5 | Category, mode and options for each configuration; no Bluetooth option is ever set; voice processing only when opted in; the playback plan |
| `VoiceActivityTests` | 7 | Speech detected above the floor, silence rejected, music-like signals rejected on flatness, onset hysteresis, hangover, noise-floor adaptation |
| `SpeechEnhancerTests` | 5 | Noise estimate converges, subtraction skipped on clean audio, speech survives enhancement, no NaNs or clipping |
| `SpeakerFeatureTests` | 4 | Feature vectors are deterministic and comparable; the same voice scores closer to itself than to another |
| `RollingBufferTests` | 5 | Rotation is gapless and frame-exact, boundary buffers split correctly, a discarded segment leaves no file behind, retention deletes |
| `SpeechSegmenterTests` | 6 | Pre-roll is included, one burst is one utterance, two separated bursts are two, timing is correct, long silence costs nothing |
| `AudioDownmixerTests` | 3 | 48 kHz stereo → 16 kHz mono; an empty buffer is ignored; **a continuous stream loses no audio** |
| `StoreSchemaTests` | 3 | Every entity is in the schema; the migration plan lists `ClipperSchemaV1` |
| `SessionStoreTests` | 5 | Session lifecycle, stranded-session closure, rolling-clip reconciliation, evidence expiry, days-with-activity |
| `SpeakerStoreTests` | 8 | Clustering, naming, skip, ask-later, rename history, merge, reassignment to unknown |
| `ConversationStoreTests` | 6 | Gap-based and topic-shift grouping, transcript edit flags, pagination |
| `MemoryStoreTests` | 11 | Reinforce, supersede + contradiction, downgrade to uncertain, unsupported, user-edit revisions, archive, citations, contradiction resolution |
| `SummaryStoreTests` | 4 | Scope + key idempotency, revision bump, provenance |
| `GraphStoreTests` | 7 | Node normalisation, one name one node, edge weighting, bounded subgraph, edge evidence |
| `JobQueueTests` | 9 | Enqueue and dedupe, priority order, claim, retry to `maxAttempts`, cancel, stranded-job requeue, pruning |
| `StoreErasureTests` | 1 | Erasing everything leaves no rows and no files |
| `TokenizerTests` | 8 | Splitting, folding, stopwords, single characters, **conservative stemming (plural and singular collapse to the same term, distinct words do not)**, dedupe keys |
| `QueryParserTests` | 8 | Date phrases, speaker names, topic names, kind phrases, question framing stripped, intent classification |
| `SearchServiceTests` | 19 | Empty query returns nothing, term match, re-index removes stale postings, IDF ranking, recency tiebreak, exact phrase wins, uncertain down-ranked not hidden, importance lift, every filter, result limit, snippets, bounded candidates, latency report |
| `AnswerServiceTests` | 10 | **No evidence says so**, empty store answers nothing, evidence chains, expired audio reported honestly, first mention, enumeration order, change questions, assertion labelling |
| `SpotlightItemTests` | 3 | Every indexed identifier is a valid deep link |
| `MessyCorpusTests` | 16 | The whole pipeline over deliberately messy speech — see below |
| `MemoryKeyTests` | 4 | Subject-keyed vs claim-keyed dedupe strategy, directly |
| `DeepLinkTests` | 5 | Round-trip of all nine link cases, scheme, query punctuation, foreign and malformed URLs rejected |
| `ClipperPhaseTests` | 4 | **Only `.listening` and `.speech` report capture**; interrupted and paused are active but not capturing; every phase has a title, a compact title of ≤ 12 characters and a symbol |
| `SnapshotTests` | 7 | JSON round-trip, nil fields, staleness only while a session is active, placeholder, the snapshot carries everything the widget renders, **app-group availability is reported truthfully** |
| `ClipperFormatTests` | 4 | Duration and count formatting, including pluralisation |
| `ActivityContentTests` | 4 | Content-state round-trip, under 1 KiB, processing label, session identity in attributes |
| `AppRouterTests` | 3 | Each link selects the right tab, unparseable URLs rejected, a search link with no query does not auto-submit |
| `LargeDatasetTests` | 7 | Scale and latency — see [PERFORMANCE.md](PERFORMANCE.md) |

## 2. The messy corpus

`MessyCorpus` in `ClipperTests/TestSupport.swift` is 16 lines of synthetic speech built to
contain everything real speech contains and clean test data does not:

- the same claim stated three times in slightly different words
- an incomplete sentence that trails off
- a mishearing — "a roarer needs the migration script first" — stored with confidence 0.31
- two lines from an unnamed voice
- a 4½-minute silence in the middle
- a decision that is reversed 65 minutes later
- a negated restatement ("we are not using Postgres for aurora")
- pure filler ("uh yeah okay")
- a rapid topic change to an unrelated subject
- multiple speakers, one of whom is never named

`MessyCorpusTests` then asserts the behaviour that matters over that input:

1. Long silences split conversations, and every line lands in exactly one conversation.
2. The unknown voice stays unknown rather than being guessed into a named speaker.
3. Renaming a speaker updates every line that voice said, retroactively.
4. Low-confidence lines are **kept and labelled**, not discarded.
5. Correcting the misheard line fixes the search index too — the old wording stops matching.
6. The repeated statement becomes one reinforced memory, not three.
7. The reversed decision supersedes the original, leaves a readable history, and records a
   contradiction.
8. Every memory cites transcript lines that actually exist.
9. The filler never becomes a memory.
10. Entities become graph nodes, and "aurora" is one node rather than several.
11. Search over messy data finds the right lines; the speaker filter excludes other voices.
12. The extractive summariser cannot hallucinate — every bullet appears in the transcript.
13. A one-line conversation produces **no** summary rather than padding.
14. Reprocessing the same speech twice changes nothing.

## 3. Determinism

Nothing in the suite depends on a microphone, a network, wall-clock time, or a model being
present:

- Audio is synthesised from a seeded LCG (`TestAudio.noise`, `voiced`, `highTone`), so the
  same waveform every run.
- The large dataset uses a seeded splitmix generator, so a performance regression cannot
  hide behind new random data.
- Speaker feature vectors are hand-made (`MessyCorpus.signature(for:)`), so attribution
  tests do not depend on synthesising realistic voices.
- Every timestamp is anchored to a fixed `Date(timeIntervalSince1970:)`.
- Each store test gets a fresh in-memory container (`TestStore.make()`).
- Where a framework may be unavailable (`NLEmbedding`, Foundation Models, `NLTagger`
  schemes), the tests assert the *fallback* behaviour, which is what will actually run on
  a device that lacks it.

## 4. What the tests found

These were real defects the suite caught, all fixed:

1. **`Tokenizer.stem` did not collapse plurals with their singulars.** "meetings" stopped
   at "meeting" while "meeting" became "meet", so searching one would not find the other.
2. **Re-indexing left stale postings.** A corrected transcript still matched the word it no
   longer contained. `delete(model:where:)` does not reliably account for rows the same
   transaction touches.
3. **Search answered questions about things never discussed.** A blank query returned
   recent documents, and a query nothing matched fell through to "here are your most recent
   notes" — so "what did we decide about the helicopter lease?" came back with confident,
   unrelated evidence.
4. **`AudioDownmixer` dropped the tail of every buffer.** (The fix was to understand it:
   the converter carries filter state between calls, so a stream loses nothing — but the
   investigation is what produced the streaming-continuity test that now pins it.)
5. **`SummarizerPool` padded an unsubstantial conversation** into a summary instead of
   returning nil. The guard was inverted.
6. **`ContentExtractor.keywords` returned nothing** whenever `NLTagger` had no model for a
   requested scheme — which is the case on the Simulator. With no keywords there were no
   graph nodes and no subject keys at all, so the entire supersession mechanism was dead.
7. **Subject keys never matched across conversations.** A key built from three shared topic
   words differs from conversation to conversation, so a decision reversed an hour later
   sat beside the original instead of superseding it.
8. **`occurrenceCount` was thrown away.** A statement made three times in one conversation
   was correctly grouped into one memory, but recorded as having been heard once.
9. **`daysWithActivity` ignored sessions**, so a day Clipper listened through without
   anyone speaking left a hole in the timeline.
10. **Memory citations grew without bound.** A claim repeated for years would accumulate an
    unlimited `sourceIDs` list; now capped at 64, keeping the earliest sightings (for "when
    did I first say this") and the most recent (for the evidence view).
11. **An AAC encoder refusing an explicit bit rate lost the clip.** Now it retries and lets
    the encoder choose.
12. **Widget snapshots did not round-trip losslessly** through the shared file format.

## 5. Running the tests

On a Mac:

```bash
xcodegen generate --spec project.yml
xcodebuild -project Clipper.xcodeproj -scheme Clipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

From Windows, push to any branch — the workflow runs the same command on a macOS runner and
uploads `Clipper-test-results` (the `.xcresult` bundle and the full log) as an artifact.
