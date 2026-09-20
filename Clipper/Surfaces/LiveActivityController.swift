import ActivityKit
import Foundation

/// Owns Clipper's Live Activity: the Dynamic Island and Lock Screen presentation of a
/// listening session.
///
/// ## What is and is not under the app's control
/// - Whether an activity is *started* is Clipper's decision, gated on the independent
///   "Show Clipper Live Activity" setting.
/// - Whether it is *displayed*, and where, is iOS's decision. `areActivitiesEnabled` is the
///   system switch and the user can revoke it at any time; the app reads it and never
///   pretends otherwise.
/// - The microphone privacy indicator is the operating system's, always shown while
///   recording, and nothing here touches it.
///
/// ## Staleness
/// Every content push carries a `staleDate`. If the app is killed mid-session the system
/// will grey the activity out rather than leave a "Listening" badge on the Lock Screen
/// forever — which would be a lie about whether the microphone is live. On the next launch
/// `endStrandedActivities()` clears anything left behind.
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// How long a content update stays trustworthy. Comfortably longer than the update
    /// cadence, short enough that a dead app stops claiming to listen.
    private static let staleAfter: TimeInterval = 5 * 60

    private var activity: Activity<ClipperActivityAttributes>?
    private var activeSessionID: UUID?
    private let lock = NSLock()

    private init() {}

    /// The system switch, not ours.
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return activity != nil
    }

    // MARK: - Lifecycle

    /// Start an activity for a session, unless one is already running for it.
    func start(sessionID: UUID, startedAt: Date, state: ClipperActivityAttributes.ContentState) {
        guard areActivitiesEnabled else {
            Log.surfaces.notice("Live Activities are disabled in system settings")
            return
        }

        lock.lock()
        let alreadyRunning = activity != nil && activeSessionID == sessionID
        lock.unlock()
        if alreadyRunning {
            update(state)
            return
        }

        // A session change means the previous activity is finished, whatever it thought.
        end(finalState: nil)

        let attributes = ClipperActivityAttributes(sessionID: sessionID, startedAt: startedAt)
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))

        do {
            let requested = try Activity.request(attributes: attributes,
                                                 content: content,
                                                 pushType: nil)
            lock.lock()
            activity = requested
            activeSessionID = sessionID
            lock.unlock()
            Log.surfaces.notice("Live Activity started")
        } catch {
            // Common and not an error worth surfacing: the user has activities off for
            // Clipper, or the system is at its activity limit.
            Log.surfaces.notice("Could not start Live Activity: \(error.localizedDescription)")
        }
    }

    func update(_ state: ClipperActivityAttributes.ContentState) {
        lock.lock()
        let current = activity
        lock.unlock()
        guard let current else { return }

        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task {
            await current.update(content)
        }
    }

    /// End the activity. `finalState` is shown briefly before dismissal so the user sees
    /// how the session finished rather than having it vanish mid-sentence.
    func end(finalState: ClipperActivityAttributes.ContentState?) {
        lock.lock()
        let current = activity
        activity = nil
        activeSessionID = nil
        lock.unlock()
        guard let current else { return }

        Task {
            if let finalState {
                let content = ActivityContent(state: finalState, staleDate: nil)
                await current.end(content, dismissalPolicy: .after(Date().addingTimeInterval(8)))
            } else {
                await current.end(nil, dismissalPolicy: .immediate)
            }
            Log.surfaces.notice("Live Activity ended")
        }
    }

    /// The user turned the setting off while a session was running, or asked to hide it.
    func hide() {
        end(finalState: nil)
    }

    /// Called at launch: an activity left over from a killed process is claiming Clipper is
    /// listening when it is not.
    func endStrandedActivities() {
        Task {
            for stranded in Activity<ClipperActivityAttributes>.activities {
                await stranded.end(nil, dismissalPolicy: .immediate)
                Log.surfaces.notice("Ended a stranded Live Activity from a previous run")
            }
            lock.lock()
            activity = nil
            activeSessionID = nil
            lock.unlock()
        }
    }

    /// Reattach to an activity this process started but lost track of (a scene rebuild).
    func reattachIfNeeded() {
        lock.lock()
        let hasActivity = activity != nil
        lock.unlock()
        guard !hasActivity else { return }

        if let existing = Activity<ClipperActivityAttributes>.activities.first {
            lock.lock()
            activity = existing
            activeSessionID = existing.attributes.sessionID
            lock.unlock()
        }
    }
}
