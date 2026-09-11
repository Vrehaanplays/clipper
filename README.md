# Clipper

A tiny native iOS background microphone recorder.

Tap **Start** → Clipper records continuously, writing a new 5-minute M4A clip every five
minutes and keeping only the newest six. That is a rolling 30 minutes of audio, forever,
in about 7 MB.

Nothing else. No accounts, no cloud, no transcription, no analytics.

---

## How it behaves

- **Start** asks for microphone permission, activates an `AVAudioSession`, and begins one
  continuous capture.
- Every 5 minutes the current clip is finalized and the next one begins **in the same
  audio stream** — no gap, no dropped samples.
- Once a seventh clip completes, the oldest is deleted. There are never more than six.
- Recording continues with the app backgrounded, another app open, and the screen off,
  using iOS's `audio` background mode. The orange microphone indicator stays visible — as
  it should.
- Files live in `Application Support/Clips/` inside the app sandbox. They are never
  uploaded, and never exposed to the Files app unless you share one yourself.

## Architecture

```
Clipper/
├── ClipperApp.swift            @main; owns the singletons, runs crash recovery at launch
├── Models/
│   ├── Clip.swift              a finalized recording: URL, start date, duration, size
│   ├── RecorderState.swift     idle · starting · recording · finalizing · interrupted ·
│   │                           stopping · error — what the UI renders, verbatim
│   └── AppSettings.swift       three knobs + a thread-safe RecordingConfig snapshot
├── Audio/
│   ├── AudioSessionManager.swift  sole owner of AVAudioSession; interruptions, routes
│   ├── SegmentWriter.swift        one segment: AAC/M4A, .part → .m4a, frame-exact
│   └── AudioRecorder.swift        the engine: capture, rotation, recovery, real state
├── Storage/
│   └── ClipStore.swift         the Clips directory, metadata, crash recovery, rolling delete
├── Playback/
│   └── AudioPlayer.swift       play / pause / scrub, one clip at a time
└── Views/
    ├── ContentView.swift       main screen
    ├── ClipsView.swift         the buffer: play, scrub, share, delete
    ├── SettingsView.swift      clip length, buffer, quality
    ├── RecordingIndicator.swift
    └── GlassStyle.swift        native glass on iOS 26, system materials below it
```

### The one design decision that matters

**There is no start/stop timer.** A foreground timer that stops one recorder and starts
another is the standard way to build this, and it is fragile: the timer fires late under
load, the restart can fail silently, and every boundary is a chance to lose audio.

Clipper instead runs a **single continuous `AVAudioEngine` input tap** for the whole
session. Segmentation happens *inside the audio stream*: `SegmentWriter` counts frames,
and the moment a buffer crosses the 5-minute mark the buffer is **split** — the head
closes one file, and the tail is handed straight to the next writer in the same turn of
the queue. Consequences:

- Segments are exact to the sample, not to whatever the run loop felt like doing.
- There is no silent window between clips, and no frame is ever dropped at a boundary.
- Wall-clock time is never the clock. The audio frames are the clock.
- Nothing to fire late, because nothing fires.

A 15-second watchdog exists, but it is *only* a recovery net — for the cases where iOS
never delivers an interruption-ended notification, or the engine dies quietly after a
route change. It plays no part in segmentation and does nothing when things are healthy.

### Threading

| Queue | Owns |
|---|---|
| `control` (serial) | session activation, engine start/stop, recovery. All engine mutation. |
| `writer` (serial) | all file I/O and `SegmentWriter` access |
| main | every `@Published` mutation, and nothing else |

Tap callbacks copy their buffer and hop to `writer` immediately, so no file I/O ever runs
on the audio thread. Nothing ever blocks `control` from `writer`, so the `writer.sync`
calls in teardown and interruption handling cannot deadlock.

### Why the UI cannot lie

`RecorderState` is published by the engine, never by the button. Tapping Start shows
`Starting`; the state only becomes `Recording` when a real audio buffer has been written
to a real file. If the engine is stopped, the UI says so. The countdown is derived from
the engine's actual `segmentStart + segmentLength`; `TimelineView` only decides when to
re-render it, and never supplies the value.

### Crash and restart recovery

A clip is only ever a `.m4a`. While being written, a segment lives at
`<timestamp>.m4a.part` — an MPEG-4 file with no index, unplayable by construction, so an
unfinished recording can never be mistaken for a clip. Finalizing releases the
`AVAudioFile` (which flushes the encoder and writes the index) and only then moves the
file to its final name.

At launch `ClipStore.bootstrap()` deletes `.part` debris, rebuilds the clip list from disk
rather than trusting the previous session, drops any individually dead file (zero bytes or
undecodable), and enforces the six-clip limit. Validity is judged per file, so cleaning up
a broken old recording can never cost a newer valid one. Start dates come from filesystem
metadata, with the filename only as a fallback.

### Interruptions

| Event | Behaviour |
|---|---|
| Phone call, Siri, another app takes the mic | current clip is finalized so the audio already captured survives as a real, playable file; state → `interrupted` |
| Interruption ends | session re-activated, engine restarted, new segment opened; state → `starting` → `recording` |
| Headphones / Bluetooth / USB mic in or out | `AVAudioEngineConfigurationChange` closes the clip and restarts the engine at the new format |
| Input format changes mid-stream | detected on the next buffer; a fresh container is opened rather than corrupting the current one |
| Media services reset | the `AVAudioEngine` itself is rebuilt |
| Disk full / write failure | clip discarded, capture torn down, honest error shown |
| Segment boundary lands on an interruption | both paths are serialized through the same two queues; worst case is one short clip, never corruption or a double-finalize |

## Privacy

The user starts recording deliberately, and iOS shows the microphone indicator the whole
time. Clipper makes no network requests of any kind — there is no networking code in the
project. Recordings stay in the app sandbox; the only way audio leaves is a share sheet
the user drives. `UIFileSharingEnabled` is `false`.

## Building

There is no `.xcodeproj` in the repo on purpose — `project.yml` is the project, and a
hand-edited `.pbxproj` is the one file that cannot be maintained safely without Xcode.
CI generates the project with XcodeGen on every build.

See **[BUILD-WINDOWS.md](BUILD-WINDOWS.md)** for the full Windows → IPA → AltStore route.
