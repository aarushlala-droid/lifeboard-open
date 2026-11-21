import SwiftUI
import LifeBoardCore

struct FocusDashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var customMinutes = 35
    @State private var selectedTaskID: UUID?
    @State private var selectedSubjectID: UUID?
    @State private var selectedProjectID: UUID?

    private var todayStart: Date { Calendar.current.startOfDay(for: .now) }
    private var todayMinutes: Int { store.focusedSeconds(since: todayStart) / 60 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(eyebrow: "Do the work", title: "Focus", detail: "A calm timer. Link it to something only when useful.")
                if let active = store.data.activeFocus { activeSession(active) }
                else { startPanel }
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Today").font(.headline)
                    Spacer()
                    Text(focusDurationLabel(todayMinutes)).font(.title3.bold()).monospacedDigit()
                    Text("completed focus").foregroundStyle(.secondary)
                }
                .padding(16).background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 20)
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }.navigationTitle("Focus")
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start a session").font(.title2.bold())
            HStack(spacing: 12) {
                focusButton(25); focusButton(50)
                Button { start(customMinutes) } label: { VStack { Text("\(customMinutes)").font(.title.bold()).monospacedDigit(); Text("Custom").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 16) }.buttonStyle(.bordered)
            }
            Stepper("Custom duration: \(customMinutes) min", value: $customMinutes, in: 5...240, step: 5)
            Divider()
            Text("Optional link").font(.headline)
            Picker("Task", selection: $selectedTaskID) { Text("No task").tag(UUID?.none); ForEach(store.data.tasks.filter { !$0.isCompleted && !$0.isArchived }) { Text($0.title).tag(UUID?.some($0.id)) } }
            Picker("Subject", selection: $selectedSubjectID) { Text("No subject").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived }) { Text($0.title).tag(UUID?.some($0.id)) } }.disabled(selectedTaskID != nil)
            Picker("Project", selection: $selectedProjectID) { Text("No project").tag(UUID?.none); ForEach(store.data.projects.filter { $0.status != .archived }) { Text($0.title).tag(UUID?.some($0.id)) } }.disabled(selectedTaskID != nil)
            HStack { Button("Short Break", systemImage: "cup.and.heat.waves") { store.startBreak() }; Spacer(); Text("Nothing has to be linked.").font(.caption).foregroundStyle(.secondary) }
        }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func activeSession(_ active: ActiveFocusSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = active.elapsedSeconds(at: context.date)
            let total = Double(active.plannedMinutes * 60)
            let remaining = max(0, total - elapsed)
            VStack(spacing: 20) {
                Label(active.kind == .shortBreak ? "SHORT BREAK" : "FOCUS", systemImage: active.kind == .shortBreak ? "cup.and.heat.waves" : "timer").font(.caption.bold()).foregroundStyle(.secondary)
                Text(active.taskTitle).font(.title2.weight(.semibold)).lineLimit(2)
                Text(clockString(remaining)).font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                ProgressView(value: min(elapsed, total), total: max(1, total)).frame(maxWidth: 480)
                HStack {
                    if active.pausedAt == nil { Button("Pause", systemImage: "pause.fill") { store.pauseFocus() } }
                    else { Button("Resume", systemImage: "play.fill") { store.resumeFocus() }.buttonStyle(.borderedProminent) }
                    Button("Stop", systemImage: "stop.fill") { store.stopFocus() }
                    Button("Reset", systemImage: "arrow.counterclockwise") { store.resetFocus() }
                    if active.kind == .focus, let id = active.taskID { Button("Complete Task", systemImage: "checkmark") { if let task = store.data.tasks.first(where: { $0.id == id }), !task.isCompleted { store.toggleTask(id) }; store.stopFocus() } }
                }.buttonStyle(.bordered).controlSize(.large)
            }.padding(30).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func focusButton(_ minutes: Int) -> some View { Button { start(minutes) } label: { VStack { Text("\(minutes)").font(.title.bold()).monospacedDigit(); Text("minutes").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 16) }.buttonStyle(.borderedProminent) }
    private func start(_ minutes: Int) { store.startFocus(minutes: minutes, taskID: selectedTaskID, subjectID: selectedSubjectID, projectID: selectedProjectID) }
    private func clockString(_ interval: TimeInterval) -> String { let seconds = Int(interval.rounded(.up)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

private func focusDurationLabel(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60, remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

struct FocusStartView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var customMinutes = 35

    private var task: TaskItem? { store.data.tasks.first { $0.id == taskID } }
    private var recommended: Int { min(90, max(10, task?.estimatedMinutes ?? 25)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Focus", systemImage: "timer").font(.title2.bold()).foregroundStyle(.tint)
            Text(task?.title ?? "Task").font(.title3.weight(.semibold)).lineLimit(2)
            Text("Choose a useful block. You can pause or stop at any time.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                presetButton(recommended, label: "Suggested")
                presetButton(25, label: "25 min")
                presetButton(50, label: "50 min")
            }
            Divider()
            HStack {
                Stepper("Custom: \(customMinutes) min", value: $customMinutes, in: 5...180, step: 5)
                Spacer(); Button("Start") { start(customMinutes) }.buttonStyle(.borderedProminent)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 500)
    }

    private func presetButton(_ minutes: Int, label: String) -> some View {
        Button { start(minutes) } label: {
            VStack(spacing: 4) { Text("\(minutes)").font(.title2.bold()).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.bordered)
    }

    private func start(_ minutes: Int) { store.startFocus(taskID: taskID, minutes: minutes); dismiss() }
}

struct ActiveFocusBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let active = store.data.activeFocus {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = active.elapsedSeconds(at: context.date)
                let total = Double(active.plannedMinutes * 60)
                let remaining = max(0, total - elapsed)
                HStack(spacing: 14) {
                    Image(systemName: active.kind == .shortBreak ? "cup.and.heat.waves.fill" : "timer")
                        .font(.title3).foregroundStyle(.tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.kind == .shortBreak ? "Short break" : active.taskTitle).font(.headline).lineLimit(1)
                        ProgressView(value: min(total, elapsed), total: max(1, total)).frame(width: 220)
                    }
                    Text(clockString(remaining)).font(.title2.monospacedDigit().weight(.semibold)).frame(width: 78)
                    Spacer()
                    if active.pausedAt == nil { Button("Pause", systemImage: "pause.fill") { store.pauseFocus() } }
                    else { Button("Resume", systemImage: "play.fill") { store.resumeFocus() }.buttonStyle(.borderedProminent) }
                    Button("Stop", systemImage: "stop.fill") { store.stopFocus() }
                    if active.kind == .focus, let taskID = active.taskID {
                        Button("Complete Task", systemImage: "checkmark") { if let task = store.data.tasks.first(where: { $0.id == taskID }), !task.isCompleted { store.toggleTask(taskID) }; store.stopFocus() }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func clockString(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up)); return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct FocusCompletionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let completion: AppStore.FocusCompletion

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("Focus block complete").font(.title2.bold())
            Text(completion.taskTitle).font(.headline).multilineTextAlignment(.center)
            HStack {
                if let taskID = completion.taskID {
                    Button("Complete Task") { if let task = store.data.tasks.first(where: { $0.id == taskID }), !task.isCompleted { store.toggleTask(taskID) }; close() }.buttonStyle(.borderedProminent)
                }
                Button("Start Break") { store.startBreak(); dismiss() }
                if let taskID = completion.taskID { Button("Continue Working") { store.startFocus(taskID: taskID, minutes: completion.plannedMinutes); dismiss() } }
            }
            Button("Back to To Do") { close() }.keyboardShortcut(.cancelAction)
        }.padding(28).frame(width: 520)
    }

    private func close() { store.focusCompletion = nil; dismiss() }
}
