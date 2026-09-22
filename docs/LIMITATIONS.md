# Known limitations

Two kinds of thing are listed here: what iOS does not allow any app to do, and what
Clipper can only do when the device, the SDK or a permission cooperates. Nothing in this
file is a bug — it is the honest boundary of what has been built.

---

## 1. What iOS does not allow — for any app

- **The microphone privacy indicator cannot be hidden.** iOS shows it whenever the mic is
  live. Clipper makes no attempt to suppress, work around, or obscure it.
- **Widget placement is the user's and the system's.** No app can add a widget to the Home
  Screen or remove one. Clipper's setting controls whether it *prepares data* for the
  widget, nothing more.
- **Background execution is at the system's discretion.** The `audio` background mode with
  an active session is the supported path and it works, but iOS can still interrupt or
  suspend capture — for a phone call, for Siri, for another app taking the input, under
  memory pressure, or when the audio server restarts. Clipper reports every one of those
  states and never claims to be recording when it is not. It cannot promise they will not
  happen.
- **There is no public speaker-diarisation API on iOS.** See §3.
- **Other apps' internal audio is not accessible**, and Clipper does not try. It hears what
  reaches the microphone — which is the room, and unavoidably also the phone's own speaker.
- **`.mixWithOthers` is a request, not a guarantee.** Whether Spotify keeps playing while
  Clipper records is ultimately the system's decision, and a call or another app's
  exclusive session can still take the input away.
- **Hardware voice processing changes other apps' audio.** Turning on echo cancellation
  requires `.voiceChat`, which ducks or interrupts other playback. That is why it is a
  setting that is off by default, with the trade-off stated in the UI: you can have good
  echo cancellation or undisturbed music, not both.

## 2. Free-Apple-ID sideloading

This build is signed by AltStore with a personal Apple ID, which constrains what can be
provisioned:

| Feature | Free Apple ID | Paid developer account |
|---|---|---|
| Microphone capture, background audio | ✅ (Info.plist key, not an entitlement) | ✅ |
| On-device speech recognition | ✅ | ✅ |
| Live Activity / Dynamic Island | ✅ (ActivityKit needs no app group) | ✅ |
| Core Spotlight, App Intents, Shortcuts | ✅ | ✅ |
| **Home Screen widget** | ❌ — needs an app group | ✅ |
| 7-day signing validity | ❌ must be re-signed weekly | 1 year |

The Home Screen widget reads its snapshot from an app group container, and **a free Apple
ID cannot provision an app group**. Clipper detects this at runtime
(`AppGroupStore.isAvailable` is derived from the real `containerURL`, not a flag), the
widget renders an explicit "can't share data with this widget" state, Diagnostics says the
same, and a failed write returns `false` rather than pretending to have succeeded. The
entitlements are already declared, so adding the capability with a paid account makes it
work with no code change. See [WIDGETS.md](WIDGETS.md).

## 3. Speaker identification is the weakest part of the app

There is no public diarisation API on iOS, so Clipper does it itself: a 52-dimension
log-mel mean+standard-deviation feature vector per utterance, clustered by nearest centroid
with a cosine threshold.

What that means in practice:

- **One person can be split into two voices** — a different distance from the phone, a cold,
  a noisy room.
- **Two people can be merged into one** — similar voices, or too little audio to tell.
- **Overlapping speech is attributed to one voice**, not separated.
- Attribution is per *utterance*, not per word.

This is stated in the app, in the speaker screen's own footer, not only here. The repair is
the user's: naming, renaming and merging all apply retroactively to every line that voice
said, and `identityConfidence` grows with evidence but never reaches certainty. A voice
Clipper is unsure about stays **Unknown** rather than being guessed, and a new voice can be
answered with **Unknown**, **Skip** or **Ask later**.

## 4. Transcription

- **On-device only.** `requiresOnDeviceRecognition = true`, always. If the on-device model
  for the locale is not installed, recognition fails and the utterance is marked failed —
  it is **not** silently sent to Apple's servers.
- Accuracy on far-field, cross-room speech with music playing is materially worse than on
  dictation. Low-confidence lines are kept and labelled, never silently dropped and never
  presented as certain.
- Word timings come from `SFTranscriptionSegment`, which is word- or short-phrase-grained.
  Where the recogniser gives no per-segment confidence, the line's confidence stands alone.
- One language at a time, from the session's locale. Code-switching mid-sentence is not
  handled.

## 5. Speech versus speaker audio

**Clipper does not promise to separate your voice from the music coming out of your phone.**
The combination of noise-floor estimation, spectral subtraction, a four-feature VAD,
`SoundAnalysis` down-ranking and optional hardware voice processing rejects a great deal of
music and game audio — and sung vocals will still score as speech, because they are speech.

What Clipper guarantees instead is that it *tells you*: every segment stores `meanSNRDB`,
`noiseFloorDB`, `speechRatio`, `speechConfidence`, `musicConfidence` and the classifier's
label, low-confidence material is marked in the UI, and nothing is promoted to a memory on
weak evidence alone.

## 6. Feature-dependent behaviour

Each of these is detected at runtime with a stated fallback; none of them is required for
the app to work.

| Feature | If unavailable |
|---|---|
| **Foundation Models** (Apple Intelligence) | Summaries come from the extractive summariser, which selects sentences rather than writing them — plainer, but it **cannot hallucinate**. Every summary records which produced it (`generator`). |
| **`NLEmbedding`** word embeddings | Search is lexical only. The semantic pass contributes nothing rather than guessing, and a query that matches no term returns nothing. |
| **`NLTagger` `.lemma` / `.lexicalClass`** | Keyword extraction falls back to a frequency count over non-filler words. Schemes are feature-detected, because an unavailable scheme makes `NLTagger` silently return nothing at all. |
| **`SoundAnalysis` `version1` classifier** | Segments are stored with `.unavailable` and are not down-ranked; the VAD alone decides. |
| **Omnidirectional polar pattern** | Whatever the built-in mic's default data source is. |
| **Hardware voice processing** | Software enhancement only. |
| **Live Activities** (`ActivityKit`) | The setting is inert; the app is unaffected. |

## 7. Not built, on purpose

The spec asked for a single-user personal app, so none of the following exists: accounts,
sync, sharing, collaboration, multi-user data, cloud storage, analytics, crash reporting,
remote configuration, or any network client at all. There is no code in this repository
that opens a socket.

Cloud processing is not a default and not an option — there is no cloud path to enable.

## 8. Not verified on hardware

Everything in this repository compiles for `iphoneos` and the full suite passes on a
simulator, but **nothing here has run on an iPhone 17.** The following can only be
confirmed on the device, and are the first things to check after installing:

1. Recording continues while Spotify plays and while a game is in the foreground.
2. Recording continues with the screen locked.
3. A phone call interrupts and Clipper recovers afterwards.
4. The Dynamic Island presentation appears and its buttons work.
5. On-device speech recognition is available for the locale and produces sensible text
   across a room.
6. Foundation Models availability, and therefore which summariser actually runs.
7. Battery and thermal behaviour over a long session (see
   [PERFORMANCE.md](PERFORMANCE.md) §4 for how to measure it).

Simulator behaviour differs from device behaviour most in exactly these areas — audio
routing, interruptions, and model availability — so treat the green test suite as evidence
that the logic is right, not as evidence that the hardware path is.
