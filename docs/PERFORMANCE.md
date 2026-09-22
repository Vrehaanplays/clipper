# Performance: what was measured

Every number here is measured, printed by the test suite as a `[perf]` line, and extracted
into the CI job summary on each run. Nothing below is an estimate unless it says so.

**Environment:** GitHub Actions `macos-latest`, Xcode 26.6, iPhone Air simulator on
iOS 26.5, Debug configuration. A Simulator on CI is slower than an iPhone 17 for
CPU-bound work and faster for I/O, so treat these as the shape of the cost, not as device
timings. The budgets in the tests are set where a genuine regression fails and
machine-to-machine variance does not.

---

## 1. Measured figures

From the green run (`LargeDatasetTests`, 120 conversations × 12 lines = 1 440 indexed
documents):

```
[perf] indexed 1440 documents, 18603 postings
[perf] 1440 documents, 18603 postings, 12.9 postings per line
[perf] search mean 33.9 ms, worst 43.5 ms over 6 samples
[perf] window fetch early 3.0 ms, late 2.6 ms
[perf] stats 0.9 ms
[perf] claim from 500-job queue 0.7 ms
```

| What | Measured | Budget asserted | Why it matters |
|---|---|---|---|
| Search over 1 440 documents | 33.9 ms mean, 43.5 ms worst | < 2 s worst | A search taking seconds would mean a scan crept into the hot path |
| Time-window transcript fetch, early vs late | 3.0 ms vs 2.6 ms | late < max(0.5 s, 20 × early) | Paging deep into history must not get slower |
| `stats()` (Diagnostics and the widget snapshot) | 0.9 ms | < 1 s | It is called often; a scan would show |
| Claiming a job from a 500-job queue | 0.7 ms | < 0.5 s | The queue is walked constantly; claiming must be one indexed row |
| Index size | 12.9 postings per transcript line | 1 < n < 40 | A runaway count would be a tokeniser bug |
| Candidate set for a term in every document | ≤ 400 | asserted | The cap is what makes search independent of corpus size |
| 200 repetitions of one claim | 1 memory, `occurrenceCount` 200, ≤ 64 citations | asserted | Repetition must not grow the store |

The later time window being *faster* than the earlier one is the point: both are indexed
range fetches, so neither pays for the data outside its window.

## 2. Storage growth

Derived from the measured index density and the audio settings, for a heavy day of
~4 hours of speech (about 2 000 transcript lines):

| What | Per line / per hour | Per heavy day | Per year at that rate |
|---|---|---|---|
| Transcript rows + postings | ~13 postings, ~700 B of index | ~1.4 MB | ~500 MB |
| Memories and summaries | deduplicated; grows with distinct subjects, not with talking | ~0.2 MB | ~70 MB |
| Retained utterance audio (AAC, 32 kbps mono) | ~14 MB per hour of *speech* | ~56 MB | ~20 GB |
| Rolling buffer | fixed: ~5 min live + ~30 min retention | ~80 MB steady state | ~80 MB |

The database is not the problem at any realistic scale; **retained audio is**. That is why
audio retention is a setting with the footprint stated in the UI
(`AudioQuality.footprintLabel`), why evidence audio expires on a schedule, and why an
expired clip is reported as gone rather than silently linked. Text, memories and the index
are cheap enough to keep indefinitely.

## 3. Why search stays fast as the store grows

The cost of a search is bounded by the query, not by the corpus:

1. One indexed fetch per term, capped at 400 postings per term.
2. Scoring those postings is arithmetic — no model, no text, no joins.
3. Only the top 160 documents are fetched in full.
4. The semantic pass runs over that bounded candidate set, never over the store.

So a 10× larger corpus changes step 1's `df` values and nothing else about the work done.
`testAVeryCommonTermStillReturnsABoundedResultSet` pins the cap so an "improvement" cannot
quietly remove it.

Everything else follows the same rule:

- Every list view is paginated (`limit`/`offset`) and every sort is on an indexed column.
- The brain map loads a **subgraph** — one focus node and its strongest neighbours, bounded
  by count and by edge weight. It never loads the graph.
- Summaries are incremental: a day rolls up its conversations, a week rolls up its days.
  Nothing re-reads the whole store.
- Jobs are claimed one at a time by `(state, priority, createdAt)`, all indexed.

## 4. Battery and thermals

Honest answer: **not measured on device.** Nothing in this repository has run on an
iPhone 17 — the whole project is built on a macOS runner from a Windows development
machine, and CI cannot measure battery drain.

What is known from the design, and what to expect:

- The continuous cost is the input tap plus one FFT per 20 ms frame in `vDSP`. That is the
  cheapest part of the pipeline and runs whether or not anyone is speaking.
- The expensive parts — transcription, sound classification, summarisation — run **only on
  detected speech**, which is what makes silence nearly free. A quiet hour costs one
  rolling clip and nothing else.
- `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` is the dominant CPU cost,
  roughly proportional to speech duration rather than to elapsed time.
- Backpressure is by quality: when the queue is deep, low-SNR utterances are dropped before
  good ones. Under sustained load the app degrades by processing less, not by falling
  further behind.

**How to measure it properly**, once the build is on a device: Instruments' Energy Log and
Thermal State templates over a 30-minute session with Spotify playing, then the same with
the screen locked. The signposts below make the regions legible in the trace.

## 5. Instruments and signposts

Every subsystem logs to its own `OSLog` category — `Log.audio`, `Log.pipeline`,
`Log.database`, `Log.search`, `Log.surfaces`, `Log.model` — so the Console can be filtered
to one concern.

`OSSignposter` intervals wrap the hot paths, which is what makes them show up as regions
in an Instruments trace rather than as a flat CPU graph:

| Interval | Where | What it bounds |
|---|---|---|
| `search` | `SearchService.search` | Tokenise → postings → candidates → score |
| `transcribe` | `TranscriptionService` | One `SFSpeechRecognizer` file recognition |
| `summarize.languageModel` | `SummarizerPool` | One Foundation Models attempt, timed and logged |
| job execution | `PipelineCoordinator` | One job, labelled by kind |

`SearchService.latencyReport()` keeps a rolling record of measured search latencies and is
shown in Diagnostics, so the number in the table above is visible in the app rather than
only in CI.

## 6. Bottlenecks found while building this

- **The inverted index was the right call.** A search over 1 440 documents costs tens of
  milliseconds with no scan anywhere; the alternative (an LLM or a vector sweep per query)
  would have been two orders of magnitude worse and would have grown with the corpus.
- **The semantic rerank has to be bounded.** Embedding the query is one call; embedding or
  scanning candidates is not. Restricting the vector pass to the lexical candidate set is
  what keeps the semantic half from dominating the cost.
- **Citation lists were unbounded** — a real leak found by the perf test, not by reading the
  code: a claim repeated for years grew its `sourceIDs` array forever. Now capped at 64.
- **`delete(model:where:)` is not a reliable way to replace child rows** inside the same
  transaction. Fetch-and-delete costs nothing at these sizes and is correct.
