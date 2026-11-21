import SwiftUI
import LifeBoardCore

/// Missed plans can change independently of their deadlines.
struct CarryOverReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newDay = Date.now
    private var tasks: [TaskItem] { store.data.tasks.filter { TaskClassification($0).carryOver }.sorted { ($0.scheduledDay ?? .today) < ($1.scheduledDay ?? .today) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Review missed plans").font(.title.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Choose a new planned day, remove the plan or mark work complete. Deadlines stay as you set them.").foregroundStyle(.secondary)
            DatePicker("Move selected work to", selection: $newDay, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
            if tasks.isEmpty { ContentUnavailableView("No missed plans", systemImage: "checkmark.circle", description: Text("Unfinished work planned before today will appear here.")) }
            else { List(tasks) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.headline)
                    HStack { if let planned = task.scheduledDay { Text("Missed plan: \(planned.id)") }; if let due = task.dueDay { Text("Deadline: \(due.id)") } }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Do today") { store.schedule(task.id, day: .today) }.accessibilityLabel("Plan \(task.title) for today without a time")
                        Button("Use chosen day") { store.schedule(task.id, day: LocalDay(newDay)) }.accessibilityLabel("Plan \(task.title) for chosen day without a time")
                        Button("Remove plan") { store.moveToInbox(task.id) }.accessibilityLabel("Remove the missed plan for \(task.title), preserve deadline")
                        Button("Complete") { store.toggleTask(task.id) }.accessibilityLabel("Complete \(task.title)")
                    }
                }.padding(.vertical, 8)
            } }
        }.padding(24).frame(minWidth: 650, minHeight: 420)
    }
}

struct RevisionOverviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var subjects: [LifeBoardCore.Subject] { store.data.subjects.filter { !$0.archived && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) } }

    // Avoid conflating self-reported confidence with course completion or exam prediction.
    private func upcoming(for subject: LifeBoardCore.Subject) -> [YearMarker] {
        store.data.yearMarkers.filter { marker in marker.startDay >= .today && marker.subjectID == subject.id && ["test", "exam", "mock", "assessment"].contains { word in marker.category.localizedCaseInsensitiveContains(word) || marker.title.localizedCaseInsensitiveContains(word) } }.sorted { $0.startDay < $1.startDay }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Revision overview").font(.title.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Confidence is your self-assessment from 1 to 5. Course and topic progress are manually maintained. These are planning signals, not predicted grades.").font(.callout).foregroundStyle(.secondary)
            TextField("Find a subject", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a subject in revision overview")
            ScrollView { LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(subjects) { subject in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(subject.title).font(.title2.bold())
                        Text("Confidence \(Int(subject.confidence))/5 · manual course progress \(Int(subject.progress))%").foregroundStyle(.secondary)
                        let work = store.data.tasks.filter { !$0.isCompleted && !$0.isArchived && $0.subjectID == subject.id }
                        Text("\(work.count) remaining tasks · \(work.filter { $0.dueDay.map { $0 < .today } == true }.count) overdue deadlines")
                        ForEach(upcoming(for: subject)) { exam in Label("\(exam.title) · \(exam.startDay.id)", systemImage: "flag").foregroundStyle(.orange) }
                        if subject.topics.isEmpty { Text("Add topics to record confidence in each area.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(subject.topics.sorted { $0.confidence < $1.confidence }) { topic in
                            HStack { Text(topic.title); Spacer(); Text("Confidence \(Int(topic.confidence))/5 · manual progress \(Int(topic.progress))%").font(.caption).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                }
                let unlinked = store.data.yearMarkers.filter { marker in marker.subjectID == nil && marker.startDay >= .today && ["test", "exam", "mock", "assessment"].contains { word in marker.category.localizedCaseInsensitiveContains(word) || marker.title.localizedCaseInsensitiveContains(word) } }.sorted { $0.startDay < $1.startDay }
                if !unlinked.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("Upcoming tests without a subject").font(.headline); ForEach(unlinked) { marker in Text("\(marker.title) · \(marker.startDay.id)") } } }
                if subjects.isEmpty { ContentUnavailableView("No matching subjects", systemImage: "books.vertical") }
            } }
        }.padding(24).frame(minWidth: 670, minHeight: 500)
    }
}

struct TopicImportPreviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let subjectID: UUID
    @State private var source = ""
    @State private var drafts: [TopicImportDraft] = []
    @State private var error: String?
    @State private var interpretedSource = ""
    @State private var extractionTask: Task<Void, Never>?
    @State private var isExtracting = false
    @State private var progressText = ""
    private var subject: LifeBoardCore.Subject? { store.data.subjects.first { $0.id == subjectID && !$0.archived } }
    private var accepted: [TopicImportDraft] { TopicImportParser.accepted(drafts, existing: subject?.topics.map(\.title) ?? []) }
    private var sourceChanged: Bool { source != interpretedSource }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Import topics into \(subject?.title ?? "subject")").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Paste a topic list or specification. Use on-device AI to extract source-grounded topics, or build a complete numbered or bulleted preview locally. Review and edit every title before adding. Existing topics are preserved and duplicates are skipped; original lines are saved in topic notes.").foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) { Text("Original text").font(.headline); TextEditor(text: $source).disabled(isExtracting).font(.body).accessibilityLabel("Original topic specification text"); Button("Build editable preview") { buildPreview() }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subject == nil || isExtracting)
                    Button("Extract with on-device AI") { extractWithAI() }.disabled(!TopicImportIntelligence.isAvailable || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subject == nil || isExtracting)
                    Text(TopicImportIntelligence.availabilityDescription).font(.caption).foregroundStyle(.secondary)
                    if isExtracting { HStack { ProgressView().controlSize(.small); Text(progressText).font(.caption); Button("Cancel extraction") { extractionTask?.cancel() } } }
                }.frame(minWidth: 280)
                VStack(alignment: .leading) {
                    HStack { Text("\(accepted.count) new topics selected").font(.headline); Spacer(); Button("Deselect all") { for index in drafts.indices { drafts[index].isIncluded = false } }.disabled(drafts.isEmpty) }
                    List($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $draft.isIncluded) { TextField("Topic title", text: $draft.title) }.accessibilityLabel("Include topic \(draft.title)")
                            if draft.isDuplicate { Text("Duplicate detected. Edit the title to add a distinct topic.").font(.caption).foregroundStyle(.secondary) }
                            if let reason = draft.reviewReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                            DisclosureGroup("Original line") { Text(draft.originalLine).font(.caption).textSelection(.enabled) }
                        }.padding(.vertical, 4)
                    }
                }.frame(minWidth: 330)
            }
            if sourceChanged && !drafts.isEmpty { Text("Original text changed. Build the preview again before adding.").foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.orange).accessibilityLabel("Import error: \(error)") }
            HStack { Text("One undoable addition; existing progress and confidence are retained.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Add \(accepted.count) topics") { if store.importTopics(accepted, subjectID: subjectID) { dismiss() } }.buttonStyle(.borderedProminent).disabled(accepted.isEmpty || sourceChanged || subject == nil || isExtracting) }
        }.padding(24).frame(minWidth: 820, minHeight: 540).onDisappear { extractionTask?.cancel() }
    }
    private func extractWithAI() {
        extractionTask?.cancel(); drafts = []; error = nil; isExtracting = true; progressText = "Preparing complete source…"
        let original = source, existing = subject?.topics.map(\.title) ?? []
        extractionTask = Task {
            defer { isExtracting = false }
            do {
                let proposals = try await TopicImportIntelligence.extract(original, existing: existing) { completed, total in progressText = "Source segment \(completed) of \(total)" }
                try Task.checkCancellation()
                drafts = proposals; interpretedSource = original; error = nil
            } catch is CancellationError { error = "Local extraction cancelled. Original text is unchanged; choose the complete local preview or retry." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func buildPreview() {
        do { drafts = try TopicImportParser.parse(source, existing: subject?.topics.map(\.title) ?? []); interpretedSource = source; error = drafts.isEmpty ? "No topic lines found. Put each topic on its own line." : nil }
        catch { self.error = error.localizedDescription; drafts = [] }
    }
}
