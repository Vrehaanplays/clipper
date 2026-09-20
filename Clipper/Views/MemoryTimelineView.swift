import SwiftUI

/// One day at a time: what Clipper heard, grouped into conversations, with the day's
/// summary at the top and the raw session record at the bottom.
///
/// Named `MemoryTimelineView` rather than `TimelineView` because SwiftUI already owns that
/// name and the live screen uses the real one.
///
/// Paging is by day and the query is date-bounded, so this screen costs the same whether
/// the store holds a week or five years.
struct MemoryTimelineView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var conversations: [ConversationDTO] = []
    @State private var daySummary: SummaryDTO?
    @State private var sessions: [SessionDTO] = []
    @State private var activeDays: [Date] = []
    @State private var isLoading = true
    @State private var showingSessions = false
    @State private var openConversation: ConversationDTO?

    private let store = ClipperStore.shared

    var body: some View {
        NavigationStack {
            List {
                daySection
                summarySection
                conversationSection
                sessionSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSessions = true
                    } label: {
                        Label("Sessions", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showingSessions) { SessionsView() }
            .navigationDestination(item: $openConversation) { conversation in
                ConversationDetailView(conversationID: conversation.id)
            }
            .refreshable { await load() }
            .task(id: day) { await load() }
            .onChange(of: pipeline.revision) { _, _ in Task { await load() } }
            .onChange(of: router.pendingConversation) { _, pending in
                guard let pending else { return }
                Task { await open(conversationID: pending) }
            }
            .task {
                if let pending = router.pendingConversation {
                    await open(conversationID: pending)
                }
            }
        }
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Sections

    private var daySection: some View {
        Section {
            HStack {
                Button {
                    shiftDay(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)

                Spacer()

                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.subheadline.weight(.medium))
                    Text(day.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    shiftDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(Calendar.current.isDateInToday(day))
            }

            if !activeDays.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeDays, id: \.self) { candidate in
                            Button {
                                day = candidate
                            } label: {
                                Text(candidate.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(candidate == day ? Color.accentColor.opacity(0.18)
                                                                 : Color.primary.opacity(0.06),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } footer: {
            Text("Days with recorded conversations.")
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let daySummary {
            Section("Day summary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(daySummary.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        AssertionBadge(assertion: daySummary.assertion, confidence: daySummary.confidence)
                    }
                    Text(daySummary.text)
                        .font(.footnote)
                    if !daySummary.bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(daySummary.bullets, id: \.self) { bullet in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(bullet).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Generated by \(daySummary.generator == "foundationModels" ? "the on-device model" : "sentence selection") · revision \(daySummary.revision)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var conversationSection: some View {
        Section("Conversations") {
            if isLoading {
                LoadingPlaceholder()
            } else if conversations.isEmpty {
                Text("Nothing was transcribed on this day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conversations) { conversation in
                    NavigationLink {
                        ConversationDetailView(conversationID: conversation.id)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                }
            } header: {
                Text("Listening sessions")
            } footer: {
                Text("When the microphone was actually on. A session with no conversations means Clipper was listening and heard no speech it could recognise.")
            }
        }
    }

    // MARK: - Actions

    private func shiftDay(by offset: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: offset, to: day) else { return }
        let today = Calendar.current.startOfDay(for: Date())
        day = min(next, today)
    }

    private func load() async {
        let bounds = SummaryKey.dayBounds(day)
        let loadedConversations = await store.conversations(from: bounds.start, to: bounds.end, limit: 100)
        let loadedSummary = await store.summary(scope: .day, key: SummaryKey.day(day))
        let loadedSessions = await store.sessions(from: bounds.start, to: bounds.end, limit: 40)
        let days = await store.daysWithActivity(limit: 30)

        conversations = loadedConversations.sorted { $0.startedAt > $1.startedAt }
        daySummary = loadedSummary
        sessions = loadedSessions
        activeDays = days
        isLoading = false
    }

    private func open(conversationID: UUID) async {
        guard let conversation = await store.conversation(id: conversationID) else {
            router.pendingConversation = nil
            return
        }
        day = Calendar.current.startOfDay(for: conversation.startedAt)
        openConversation = conversation
        router.pendingConversation = nil
    }
}

// MARK: - Rows

struct ConversationRow: View {
    let conversation: ConversationDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(conversation.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if conversation.isOpen {
                    KindTag(symbolName: "dot.radiowaves.left.and.right", title: "Live", tint: .red)
                }
            }

            if let summary = conversation.summaryText, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(conversation.startedAt.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                Text("·")
                Text(ClipperFormat.compactDuration(conversation.speechSeconds))
                Text("·")
                Text("\(conversation.segmentCount) line\(conversation.segmentCount == 1 ? "" : "s")")
                if !conversation.speakerLabels.isEmpty {
                    Text("·")
                    Text(conversation.speakerLabels.prefix(2).joined(separator: ", "))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                ScoreBar(value: conversation.importance, tint: .accentColor, width: 34)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct SessionRow: View {
    let session: SessionDTO

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isOpen ? "dot.radiowaves.left.and.right" : "mic")
                .font(.footnote)
                .foregroundStyle(session.isOpen ? .red : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .omitted, time: .shortened)
                     + (session.endedAt.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? " – now"))
                    .font(.footnote)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text(ClipperFormat.compactDuration(session.duration) + " on")
                    Text("·")
                    Text(ClipperFormat.compactDuration(session.speechSeconds) + " speech")
                    if session.interruptionCount > 0 {
                        Text("·")
                        Text("\(session.interruptionCount) interruption\(session.interruptionCount == 1 ? "" : "s")")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if !session.usedBuiltInMic {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
