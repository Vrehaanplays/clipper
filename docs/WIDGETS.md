# Home Screen widget and Dynamic Island Live Activity

Two separate features, two separate settings, two very different platform requirements.

---

## 1. The snapshot

Neither surface talks to the store. Both render one small value type:

```swift
ClipperSnapshot {
    phase            // ClipperPhase: inactive / listening / speech / processing /
                     // paused / interrupted / recovering / permissionDenied
    sessionStartedAt // Date?
    speechSeconds    // Double
    pendingJobs      // Int
    isProcessing     // Bool
    lowConfidence    // Bool
    recentMemory     // String?
    recentSummary    // String?
    memoryCount      // Int
    updatedAt        // Date
}
```

The app prepares it and writes it; the widget reads it and lays it out. **No heavy
processing happens inside the extension** — no database, no audio, no embedding, no
network. A timeline reload is a file read and a layout pass. `SnapshotTests` asserts the
snapshot carries everything either surface renders, so nothing has to be computed there.

Writes are atomic: encode, write to a sibling temp file, then replace. A reload that lands
mid-write reads the previous complete snapshot, never a torn one. Dates are encoded as ISO
8601 with fractional seconds, because the widget decides whether a snapshot is stale by
comparing what it read against what the app wrote, and plain ISO 8601 truncates to the
second.

Staleness is only reported while `phase.isSessionActive`. A snapshot from a finished
session is not stale — it is simply the last thing that happened.

## 2. Home Screen widget

`ClipperStatusWidget`, a `StaticConfiguration` widget supporting:

| Family | What it shows |
|---|---|
| `.systemSmall` | Phase, elapsed speech time, memory count |
| `.systemMedium` | The above plus the most recent memory or summary line |
| `.accessoryRectangular` | Phase and elapsed time (Lock Screen) |
| `.accessoryCircular` | Phase glyph and a progress ring (Lock Screen) |

States it renders: not listening, listening, speech detected, processing *n* items, paused
by iOS, interrupted, permission denied, stale, no data yet, and app-group-unavailable.
There is no state in which it claims Clipper is recording when the snapshot says otherwise.

### The app group, honestly

The widget reads the snapshot from an **app group container**, which is the only supported
way for an extension to see the app's data. An app group is a provisioning capability.

**A free Apple ID cannot provision an app group.** With AltStore signing using a free
account, `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil`, writes have
nowhere to go, and the widget has nothing to read.

Clipper does not pretend otherwise:

- `AppGroupStore.isAvailable` is derived from `containerURL != nil` — the real thing, not a
  hardcoded flag.
- `write(_:)` returns `false` when it could not write, and
  `SnapshotTests.testAppGroupAvailabilityIsReportedTruthfully` asserts a failed write
  reports failure rather than claiming success.
- The widget renders an explicit "Clipper can't share data with this widget" state
  explaining that it needs an app group, instead of showing a blank or invented status.
- Diagnostics in the app shows the same fact.

With a paid Apple Developer account, add the `group.com.vrehaanplays.clipper` app group
capability to both targets and the widget works with no code change. The entitlements
files already declare it.

**iOS decides whether a widget is on the Home Screen.** No app can place or remove one,
and Clipper does not claim to. The setting below controls whether Clipper *prepares* data
for it.

## 3. Live Activity / Dynamic Island

`ClipperLiveActivityWidget`, an `ActivityConfiguration` over
`ClipperActivityAttributes`. Three presentations:

- **Compact** (the Dynamic Island pill) — a phase glyph and the elapsed time, under 12
  characters, which `ClipperPhaseTests` pins for every phase.
- **Expanded** — phase, elapsed speech time, pending-processing count, and Pause/Resume
  and Stop buttons wired to `PauseClippingIntent`, `ResumeClippingIntent` and
  `StopClippingIntent` (all `LiveActivityIntent`, which is why they live in `Shared/`).
- **Lock Screen / banner** — the same information in a wider layout.

`ActivityContentTests` asserts the content state round-trips, stays under 1 KiB (the
budget ActivityKit allows for an update), pluralises its processing label correctly, and
that the attributes carry the session identity so a stale activity can be matched to the
session that created it.

### What this needs, and what it does not

- **No app group.** ActivityKit passes the content state through the system, so the
  Dynamic Island works on a free-signed sideload. This is the reason the two features have
  separate settings: one works on a free account and one does not.
- `Info.plist` declares `NSSupportsLiveActivities` (verified by the CI bundle check).
- `LiveActivityController` ends activities left over from a killed process on launch, so
  the Island never claims Clipper is listening when it is not, and reattaches to an
  activity this process started but lost track of after a scene rebuild.
- **The microphone privacy indicator is the operating system's.** Clipper makes no attempt
  to hide, suppress or work around it. The Live Activity sits beside it.

## 4. The two settings

In Settings, independently:

- **Show Clipper Widget Data** — whether the app prepares and writes the snapshot.
- **Show Clipper Live Activity** — whether a Live Activity is started with a session.

Turning either off takes effect immediately: the snapshot is cleared, or the running
activity is ended. Neither setting affects the other, and neither affects recording.
