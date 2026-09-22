# Audio session, background behaviour, and what the microphone can actually do

This is the part of Clipper that decides whether the app works at all, so it is written
down in full — including the things iOS does not let any app guarantee.

---

## 1. The requirement

Start Clipper, switch to Spotify or a game, and Clipper keeps listening through the
iPhone's built-in microphone. It must not need AirPods or any Bluetooth device, and it does
not touch Spotify's internal audio stream — it hears whatever reaches the microphone,
which is the room, and unavoidably also whatever the phone's own speaker is playing.

## 2. The configuration

All of `AVAudioSession` is owned by `AudioSessionManager`; nothing else in the app
configures it. The policy half is `AudioSessionPlan`, which is a pure value type so it can
be unit-tested with no device (`AudioSessionPlanTests`).

```swift
category: .playAndRecord
mode:     .default            // .voiceChat only when echo cancellation is on
options:  [.defaultToSpeaker, .mixWithOthers]
preferredInput: the .builtInMic port
preferredDataSource: the omnidirectional pattern, where the hardware offers a choice
```

Why each part:

- **`.playAndRecord` for the whole capture lifetime.** Playing a clip back never needs a
  category switch, and a switch mid-capture tears the engine down.
- **`.mixWithOthers`** is the only public way to let another app keep playing while we
  record. Without it, activating the session interrupts Spotify.
- **`.defaultToSpeaker`** because `.playAndRecord` otherwise routes playback to the
  earpiece, which makes clip playback sound broken.
- **No Bluetooth options at all.** Not `.allowBluetoothHFP`, not `.allowBluetoothA2DP`.
  Clipper is specified to use the built-in microphone, and offering a Bluetooth input
  would silently change what it can hear — and route selection is not something the user
  would see happen.
- **`.voiceChat` mode and `setVoiceProcessingEnabled` only when the user opts in.** Voice
  processing gives real hardware echo cancellation, AGC and noise suppression, which is
  exactly what you want when the phone's own speaker is feeding the mic. The cost is that
  the mode ducks or interrupts other apps' audio, which defeats the purpose of the app for
  most people. It is therefore a setting, off by default, with the trade-off stated in the
  UI rather than hidden.
- **Omnidirectional data source** where the hardware exposes a polar-pattern choice, since
  the point is to pick up a room rather than only the person holding the phone.

## 3. Background execution

`Info.plist` declares:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

That is an Info.plist key, **not an entitlement**, which matters here: it needs no
provisioning profile capability, so a free Apple ID can sign the sideloaded build and the
app still records in the background.

With an active `.playAndRecord` session and a running `AVAudioEngine`, iOS keeps the
process alive while another app is in the foreground and while the screen is locked. This
is the documented, supported path — there is nothing clever or undocumented about it.

## 4. What iOS can take away, and what Clipper does about it

`AudioSessionManager` observes `interruptionNotification`, `routeChangeNotification` and
`mediaServicesWereResetNotification`, and reports each to the recorder through
`AudioSessionObserver`.

| Event | What happens | Clipper's response |
|---|---|---|
| Phone call, FaceTime | Interruption begins; the tap stops | Phase becomes **Interrupted**; the current segment is closed cleanly, not lost |
| Siri | Interruption begins and usually ends with `.shouldResume` | Phase **Interrupted** → **Recovering** → **Listening** |
| Another app takes the mic | Interruption, sometimes with no resume hint | Phase **Paused by iOS** until the system hands the input back |
| Camera / video recording | Route or interruption, device dependent | Same as above; never reported as recording |
| Screen lock | Nothing — capture continues | Phase unchanged |
| Route change (device plugged in, speaker change) | `routeChangeNotification` | The input is re-pinned to the built-in mic; the downmixer rebuilds if the format changed |
| `mediaServicesWereReset` | The whole audio server restarted | Engine and session are rebuilt from scratch |

Resumption is attempted only when it is safe: after an interruption that ended with
`.shouldResume`, or after the route settles. Attempts are bounded, and a failure to resume
leaves the UI saying so rather than retrying silently forever.

**The UI never claims to be recording when it is not.** `ClipperPhase` has exactly one
state that means audio is being captured, and `ClipperPhaseTests` pins it: `.listening`
and `.speech` report capture; `.interrupted`, `.paused`, `.recovering`,
`.permissionDenied` and `.processing` are visible, distinct states that do not. This is
the single most important honesty property in the app, and it is asserted rather than
asserted-in-prose.

Full phase list shown in the UI: **Recording, Listening, Speech detected, Processing,
Paused by iOS, Interrupted, Recovering, Permission denied**, and a per-segment
**Low confidence** marker.

## 5. The rolling buffer

`SegmentWriter` writes AAC-in-m4a clips from the tap, rotating on a **frame count** rather
than a timer, splitting the boundary buffer sample-exactly so rotation is gapless.

- ~5 minutes of short-term audio is kept at all times.
- ~30 minutes of temporary retention beyond that, then the clip is deleted.
- Retained *memory* audio — the utterance clips that produced transcripts — lives in a
  separate directory with its own lifecycle. Temporary buffer audio and retained evidence
  audio are never mixed, and the store records which files still exist
  (`AudioSegmentRecord.audioAvailable`), so an expired clip is reported as gone rather
  than offered as a play button that does nothing.
- Silence costs nothing beyond the rolling clip itself: no utterance file is written, no
  job is enqueued, no transcription runs.

If an AAC encoder refuses the requested bit rate — which some do at some sample rates,
including the Simulator's — the writer retries without an explicit bit rate and lets the
encoder choose. A refused preference is not a reason to lose a recording.

## 6. Speech detection, and the speaker-audio problem

Because the phone's speaker physically reaches its microphone, music and game audio are
*in* the signal. Clipper does not claim to separate them perfectly. What it does:

1. **Noise floor estimate** — minimum statistics over a sliding window, so a steady
   background (music, fan, traffic) is learned rather than treated as speech.
2. **Conservative spectral subtraction** (`SpeechEnhancer`), skipped entirely above 18 dB
   SNR because subtracting from clean speech does more harm than good.
3. **VAD** (`VoiceActivityDetector`) on four features, all of which have to agree:
   SNR over the estimated floor, spectral flatness below 0.42 (music is flatter than
   speech), voice-band energy ratio above 0.30, and spectral centroid within 80–4200 Hz.
   Onset needs 3 consecutive frames; release has a 0.8 s hangover so a pause mid-sentence
   does not split it.
4. **0.6 s pre-roll** ring buffer, so the utterance file starts before the first detected
   frame and the first word is not clipped.
5. **`SoundAnalysis`** on each finished utterance, using Apple's `version1` classifier, to
   down-rank anything the taxonomy calls music, singing or an instrument.
6. **Optional hardware voice processing**, as above.
7. **Quality metadata stored on every segment** — `meanSNRDB`, `peakLevelDB`,
   `noiseFloorDB`, `speechRatio`, `speechConfidence`, `musicConfidence`, and the
   classifier's label. Low-confidence material is kept and labelled, never silently
   discarded and never silently promoted.

Sung vocals will always score as speech. That is stated in the app, not just here.

## 7. Permissions

Two, both requested normally, both explained in `Info.plist`:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

Apple's orange microphone indicator is shown by iOS whenever Clipper is listening.
**Clipper makes no attempt to hide, suppress or work around it**, and no attempt to record
without the user starting a session. There is no upload path in the app at all: no network
client, no account, no analytics. Recordings and transcripts stay in the app's container.

If either permission is denied, the affected part of the app says so and offers the
Settings link; nothing pretends to work.
