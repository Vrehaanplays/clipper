# Search, indexing, and answering with evidence

The rule that shapes all of this: **no language model runs over the database to answer a
search.** Search is arithmetic over an inverted index. A model is used at *write* time to
phrase a summary, and optionally to phrase one answer from already-retrieved excerpts.
That is what keeps search instant after years of accumulation.

---

## 1. The index

Two tables:

**`IndexedDocumentRecord`** — one row per searchable thing: a transcript segment, a
memory, a summary, a conversation, a speaker or a graph node. It carries `kind`, `refID`
(the row it stands for), `conversationID`, `title`, `text`, `timestamp`, `speakerIDs`,
`nodeIDs`, `importance`, `confidence`, `assertion`, `tokenCount`, and an optional
embedding in external storage. Indexed on `timestamp`, `kindRaw`, `refID`, `importance`.

**`TokenPostingRecord`** — one row per (term, document): `token`, `documentID`, `weight`,
`timestamp`. Indexed on `token` and `documentID`.

This is a hand-built inverted index rather than SQLite FTS5. SwiftData does not expose
FTS5, and reaching under it to the underlying store would mean owning two schemas and two
migration stories. The index is ~13 postings per transcript line in practice
(see [PERFORMANCE.md](PERFORMANCE.md)), which is small enough that owning it is cheaper
than working around the framework.

### Tokenisation

`Tokenizer` is the single source of truth for what a term is, because the query and the
index must agree exactly:

1. `NLTokenizer(unit: .word)` splits — not a `CharacterSet` split, so contractions,
   hyphenation and non-Latin scripts behave.
2. Diacritic- and case-folding.
3. Stopwords removed (a deliberately short list — over-pruning hurts phrase search — plus
   the fillers that dominate real speech: "um", "uh", "yeah", "okay", "gonna").
4. Conservative stemming: plural stripping first, then verb endings applied to the result.
   Chaining matters — applying them as alternatives made "meetings" stop at "meeting"
   while "meeting" became "meet", so a search for one would not find the other.
   Stemming stays conservative on purpose: aggressive stemming ruins proper nouns, and
   proper nouns are most of what this app searches for.

Term weights are computed per document by `weightedTokens(title:body:)`: title terms count
triple, and length is normalised by `sqrt(totalTokens)` so a long transcript does not
dominate on raw term frequency.

Re-indexing a document **deletes its old postings first**, by fetching and deleting them
rather than with a batch predicate delete — the batch form does not reliably account for
rows the same transaction is about to insert, which left a corrected transcript still
matching the word it no longer contained.

## 2. The hot path

`SearchService.search(_:)`:

1. Tokenise the query. **If there are no terms and no filters, return nothing** — a blank
   search box must not dump the database.
2. One indexed fetch per term against `TokenPostingRecord.token`, date-filtered in the
   predicate, capped at `perTokenLimit = 400` postings per term.
3. Accumulate a score per document: `weight × BM25-style IDF`, so a rare term dominates
   and a term in nearly every document contributes almost nothing.
4. Take the top `candidateLimit = 160` document ids and fetch **only those** documents in
   one query.
5. Score that bounded set on meaning, phrase, recency, importance and confidence.

No step reads the transcript tables. No step scans the store. The candidate cap is pinned
by a test (`testAVeryCommonTermStillReturnsABoundedResultSet`).

### Ranking

```
score = 0.48 · lexical          (normalised TF-IDF)
      + 0.22 · semantic         (cosine against the query embedding, positive only)
      + 0.12 · recency          (1 / (1 + ageDays/30))
      + 0.09 · importance
      + 0.09 · confidence
      + 0.25 if the typed phrase appears literally in the title or text
```

then multiplied down by assertion: `contradictory × 0.85`, `unsupported × 0.7`,
`uncertain × 0.92`. Weak material stays findable but does not get to lead.

### The semantic fallback, and its floor

When no term matched, candidates come from a bounded, date-filtered semantic pass instead.
In that path a hit must clear a cosine floor of **0.45** to count at all, and if no query
vector could be produced the search returns nothing.

Without that floor the fallback degenerates into "here are your most recent notes", which
is how a question about something never discussed comes back with confident, unrelated
evidence. Embeddings come from `NLEmbedding`; where they are unavailable, search is
lexical only and says nothing rather than guessing.

### Filters

`kinds`, `speakerIDs`, `nodeIDs`, `assertions`, `from`/`to`, `conversationID`,
`minimumConfidence`, `minimumImportance`, `limit`. Filters alone are a valid query — that
is how the timeline, the people screens and the topic screens browse.

## 3. Parsing a question

`QueryParser` turns typed text into a `SearchQuery`: date phrases ("yesterday", "last
week") become `from`/`to`, known speaker names become `speakerIDs`, known topic names
become `nodeIDs` (and stay in the text, since a topic name is also a strong lexical
signal), and kind phrases ("decisions", "questions") become `kinds`.

It then strips the question's **framing** — both whole phrases ("what did I say about")
and leftover individual words: interrogatives, pronouns, and the verbs people use to ask
about remembering (`decide`, `said`, `discussed`, `mentioned`, `remember`, …). This is not
cosmetic. "What did we decide about the helicopter lease?" contains "decide" because that
is how questions are phrased, and leaving it in made the query match every decision ever
recorded — a confident answer about something never discussed.

`QuestionIntent` classifies the shape of the question: `lookup`, `question`, `summary`,
`enumerate`, `firstMention`, `evidence`, `change`.

## 4. Answering

`AnswerService` retrieves first and phrases second. Every answer carries an
`AssertionKind`, and the mapping is fixed rather than judged case by case:

| Where the answer came from | Label |
|---|---|
| Quoted from a transcript segment marked `stated` | `Directly stated` |
| Drawn from a generated summary | `Summarised` |
| Phrased by the language model from retrieved excerpts | `Inferred` |
| Best evidence was low-confidence or an unknown speaker | `Uncertain` |
| Supporting memories disagree | `Contradictory` |
| Nothing matched | `Unsupported`, with `insufficientEvidence` set |

The last row is the one that matters. With no hits, the answer is:

> "Nothing in Clipper's memory answers that. Either it was not said while Clipper was
> listening, or it was not recognised."

— and `chains` is empty. `testAQuestionWithNoEvidenceSaysSoRatherThanGuessing` asserts all
four properties of that outcome, including that the text is not empty, because saying
nothing is not the same as saying "I don't know".

### The evidence chain

Every answer carries `EvidenceChainDTO`s, each one a full path:

```
answer → memory or summary → conversation → transcript segment → timestamp → audio file
```

`resolveLeaf(from:sourceKind:)` follows `sourceIDs` down through whatever layer they point
at (a summary of summaries resolves recursively) until it reaches a transcript segment.
If the audio has passed its retention window, the chain reports `audioExpired` rather than
offering playback that would fail.

### The eight example queries

| Question | Intent | Where it is handled |
|---|---|---|
| "What did I say about the budget?" | `lookup` | lexical + phrase |
| "What did Sam decide about Aurora?" | `question` | speaker filter + subject terms |
| "Find every time I mentioned the migration." | `enumerate` | `allMentions`, chronological |
| "When did I first discuss sailing?" | `firstMention` | earliest by timestamp, evidence listed in time order |
| "Summarise everything I said about the project." | `summary` | topic summary, or extractive over retrieved lines |
| "What evidence do I have for the Friday deadline?" | `evidence` | chains only, no phrasing |
| "What changed between my earlier and later statements about the database?" | `change` | revision chain + contradictions |
| "Show all conversations related to Aurora." | `lookup` + node filter | `nodeIDs` filter |

## 5. Core Spotlight

`SpotlightIndexer` indexes memories, summaries and conversations into the
`com.vrehaanplays.clipper.memory` domain. **The `uniqueIdentifier` of every item *is* its
`clipper://` deep link**, so handling a Spotlight result is the same code path as handling
a URL — there is no second routing table to keep in sync. `SpotlightItemTests` asserts
that every indexed identifier parses back into a valid deep link.

## 6. App Intents

In the app: `SearchMemoriesIntent`, `MemoriesAboutIntent`, `OpenTodayTimelineIntent`,
`ShowRecentSummaryIntent`, `OpenMemoryIntent`.

In `Shared/` so the Live Activity's buttons can use them too:
`StartClippingIntent`, `StopClippingIntent`, `PauseClippingIntent`,
`ResumeClippingIntent` — all `LiveActivityIntent`.

These are what Shortcuts and the supported Siri surfaces pick up. Public APIs only; no
private entitlements and no claims about Siri behaviour that Apple does not document.
