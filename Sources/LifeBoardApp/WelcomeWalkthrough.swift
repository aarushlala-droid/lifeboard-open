import SwiftUI
import LifeBoardCore

/// A short, local tour. Reopening it from Help never changes planner settings.
struct WelcomeWalkthroughView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var startMinutes = 17 * 60
    @State private var endMinutes = 22 * 60
    @State private var isReturning = false
    @State private var didLoadSettings = false
    @State private var saveFailed = false

    private let stepCount = 5
    private var validHours: Bool { endMinutes > startMinutes }
    private var stepTitle: String {
        switch step {
        case 0: "Capture, then check"
        case 1: "Give today a little shape"
        case 2: "Focus on the next thing"
        case 3: "Your planner, your choice"
        default: "Your usual planning hours"
        }
    }
    private var stepSymbol: String {
        switch step {
        case 0: "plus.circle"
        case 1: "calendar"
        case 2: "timer"
        case 3: "externaldrive"
        default: "clock"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isReturning ? "A quick tour of LifeBoard" : "Welcome to LifeBoard")
                    .font(.headline)
                Spacer(minLength: 12)
                Text("\(step + 1) of \(stepCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Step \(step + 1) of \(stepCount)")
            }
            .padding(.bottom, 12)
            ProgressView(value: Double(step + 1), total: Double(stepCount))
                .accessibilityHidden(true)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label(stepTitle, systemImage: stepSymbol)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)

            Divider().padding(.vertical, 14)
            HStack(spacing: 12) {
                if step > 0 {
                    Button("Back") { step -= 1; saveFailed = false }
                } else if isReturning {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Skip tour") { step = stepCount - 1 }
                        .accessibilityHint("Go straight to planning hours")
                }
                Spacer(minLength: 8)
                Button(step == stepCount - 1 ? (isReturning ? "Done" : "Open LifeBoard") : "Continue") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == stepCount - 1 && !isReturning && !validHours)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(minWidth: 350, idealWidth: 620, maxWidth: 620, minHeight: 400, idealHeight: 500, maxHeight: 560)
        .interactiveDismissDisabled(!isReturning)
        .onAppear {
            guard !didLoadSettings else { return }
            didLoadSettings = true
            isReturning = store.data.settings.hasCompletedOnboarding
            startMinutes = store.data.settings.eveningStartMinutes
            endMinutes = store.data.settings.eveningEndMinutes
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0:
            Text("One place for the things on your mind.").foregroundStyle(.secondary)
            feature("Capture", symbol: "plus", detail: "Press Command–N to type a task or paste a list. You can also add a screenshot for a draft to review.")
            feature("Review before adding", symbol: "checklist", detail: "Check the titles, dates and estimates in the preview. Adjust anything that needs it, then add the tasks.")
            feature("Leave room for later", symbol: "tray", detail: "A task can stay in To Do without a date. You do not have to plan everything at once.")
        case 1:
            feature("To Do is what; Calendar is when", symbol: "calendar", detail: "Keep something in Anytime, give it a day, or choose an exact time. A due date is separate from the time you plan to work.")
            feature("See your day", symbol: "sun.max", detail: "Today brings tasks and your schedule together. Review carry-over when yesterday’s plan changes.")
            feature("Plan around commitments", symbol: "clock", detail: "Plan can suggest time slots around calendar events. Review the suggestion before accepting it. Calendar connections are optional in Settings.")
        case 2:
            feature("One task at a time", symbol: "timer", detail: "Use a task’s timer button, or open Focus for a standalone session. Pause, resume or take a break as you need.")
            feature("Keep the bigger picture", symbol: "books.vertical", detail: "Subjects hold topics and confidence; Projects hold milestones, notes and progress. Important Dates keeps exams and other dates in view.")
            feature("Change your mind", symbol: "arrow.uturn.backward", detail: "Undo recent edits with Command–Z. Find finished work in Completed, and recover deleted items from Trash.")
        case 3:
            feature("Start on this Mac", symbol: "desktopcomputer", detail: "Your planner is saved locally. You can use LifeBoard without connecting a calendar or phone.")
            feature("Keep a backup", symbol: "externaldrive", detail: "Settings › Data lets you export a readable backup and preview one before restoring it. iCloud Drive backups are optional and separate from phone sync.")
            feature("Connect only when you want to", symbol: "iphone", detail: "If you have a private workspace invitation, add it in Settings › Integrations. Connect a phone with a one-use code. Synced records are stored in the configured cloud database and browser cache.")
        default:
            Text("These hours guide suggested plans. They do not restrict when you can add tasks or use Focus.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isReturning {
                Label("\(timeLabel(startMinutes))–\(timeLabel(endMinutes))", systemImage: "clock")
                    .font(.title3.monospacedDigit())
                Text("Change these any time in Settings › Planning. This tour leaves your current settings as they are.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Start", selection: $startMinutes) {
                        ForEach(timeOptions(includeMidnightEnd: false, preserving: startMinutes), id: \.self) { minute in
                            Text(timeLabel(minute)).tag(minute)
                        }
                    }
                    Picker("Finish by", selection: $endMinutes) {
                        ForEach(timeOptions(includeMidnightEnd: true, preserving: endMinutes), id: \.self) { minute in
                            Text(timeLabel(minute)).tag(minute)
                        }
                    }
                    if !validHours {
                        Label("Choose a finish time after the start time.", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if saveFailed {
                        Text("The setup could not be saved. Your planner has been kept as it was. Check the save message, then try again.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.large)
                Text("You can change these later in Settings › Planning, and reopen this tour from Help.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func timeOptions(includeMidnightEnd: Bool, preserving minute: Int) -> [Int] {
        let values = includeMidnightEnd ? Array(stride(from: 15, through: 1440, by: 15)) : Array(stride(from: 0, to: 1440, by: 15))
        return Array(Set(values + [minute])).sorted()
    }

    private func timeLabel(_ minute: Int) -> String {
        minute == 1440 ? "24:00 (midnight)" : String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func advance() {
        guard step == stepCount - 1 else { step += 1; return }
        guard !isReturning else { dismiss(); return }
        guard validHours else { return }
        var settings = store.data.settings
        settings.eveningStartMinutes = startMinutes
        settings.eveningEndMinutes = endMinutes
        settings.hasCompletedOnboarding = true
        store.updateSettings(settings)
        saveFailed = !store.data.settings.hasCompletedOnboarding
        if !saveFailed { dismiss() }
    }
}
