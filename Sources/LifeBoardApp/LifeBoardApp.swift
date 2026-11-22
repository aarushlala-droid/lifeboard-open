import AppKit
import SwiftUI
import LifeBoardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save any debounced inspector edit before the process exits.
        store?.flushPendingDrafts()
        return .terminateNow
    }
}

@main
struct LifeBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @AppStorage("selectedSection") private var selectedRaw = AppSection.today.rawValue
    @AppStorage("showInspector") private var showInspector = true
    @State private var showCapture = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window(LifeBoardEnvironment.productName, id: "main") {
            RootView(selected: Binding(get: { section }, set: { selectedRaw = $0.rawValue }), showCapture: $showCapture)
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
                .tint(LB.accent)
                .onOpenURL { store.handle(url: $0) }
                .onAppear { delegate.store = store; store.startBackgroundWork() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    store.reloadIfChanged(); store.tickFocus(); store.refreshConnectedCalendarsIfNeeded(force: true)
                }
                .sheet(isPresented: Binding(get: { !store.data.settings.hasCompletedOnboarding }, set: { _ in })) { WelcomeWalkthroughView().environmentObject(store) }
                .sheet(item: $store.pendingExternalImport) { preview in ExternalImportReviewView(preview: preview).environmentObject(store) }
                .sheet(isPresented: $showCapture) { QuickAddView().environmentObject(store).tint(LB.accent) }
                .alert(item: $store.message) { message in Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK"))) }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { LifeBoardCommands(store: store, selectedRaw: $selectedRaw, showCapture: $showCapture, showInspector: $showInspector) }

        Settings {
            SettingsView().environmentObject(store).tint(LB.accent).frame(width: 660, height: 560)
        }

        Window("\(LifeBoardEnvironment.productName) Help", id: "help") {
            HelpView().environmentObject(store).tint(LB.accent).frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 720, height: 700)
    }

    /// Settings and Help used to be sidebar sections; old saved values map home.
    private var section: AppSection {
        let value = AppSection(rawValue: selectedRaw) ?? .today
        return value == .settings || value == .help ? .today : value
    }
}

struct LifeBoardCommands: Commands {
    @ObservedObject var store: AppStore
    @Binding var selectedRaw: String
    @Binding var showCapture: Bool
    @Binding var showInspector: Bool
    @Environment(\.openWindow) private var openWindow

    private var selectedTask: TaskItem? { store.selectedTaskID.flatMap { store.index.tasksByID[$0] } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New To Do") {
                if ![AppSection.today.rawValue, AppSection.inbox.rawValue].contains(selectedRaw) { selectedRaw = AppSection.today.rawValue }
                DispatchQueue.main.async { store.newTaskFocusRequest += 1 }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Capture…") { showCapture = true }.keyboardShortcut("n")
        }
        CommandMenu("Task") {
            let task = selectedTask
            Button(task?.isCompleted == true ? "Mark as Not Done" : "Mark as Done") { if let task { store.toggleCompletion(task.id) } }
                .keyboardShortcut("k").disabled(task == nil)
            Divider()
            Button("Do Today") { if let task { store.setWhen(task.id, day: .today) } }.keyboardShortcut("t").disabled(task == nil)
            Button("Do Tomorrow") { if let task { store.setWhen(task.id, day: .today.adding(days: 1)) } }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(task == nil)
            Button("Do This Weekend") { if let task { store.setWhen(task.id, day: store.weekendDay()) } }.disabled(task == nil)
            Button("Anytime (No Date)") { if let task { store.setWhen(task.id, day: nil) } }.keyboardShortcut("r").disabled(task == nil)
            Button("Choose Date…") { store.rescheduleRequest = task?.id }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(task == nil)
            Divider()
            Button("Start Focus…") { if let task { store.requestFocus(task.id) } }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(task == nil)
            Button("Duplicate") { if let task { store.duplicateTask(task.id) } }.keyboardShortcut("d").disabled(task == nil)
            // No Command-Delete: in a text field it deletes to the line start,
            // and a menu shortcut would win and trash the task instead.
            Button("Move to Trash") { if let task { store.deleteTask(task.id) } }.disabled(task == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(showInspector ? "Hide Inspector" : "Show Inspector") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            ForEach(AppSection.navigable) { section in
                if let key = section.shortcut { Button(section.title) { selectedRaw = section.rawValue }.keyboardShortcut(KeyEquivalent(key), modifiers: .command) }
            }
            Divider()
            Button("Calendar: Today") { calendar("today") }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Calendar: Previous") { calendar("previous") }.keyboardShortcut("[", modifiers: .command)
            Button("Calendar: Next") { calendar("next") }.keyboardShortcut("]", modifiers: .command)
            Button("Calendar: Day") { calendar("day") }.keyboardShortcut("1", modifiers: [.command, .control])
            Button("Calendar: Week") { calendar("week") }.keyboardShortcut("2", modifiers: [.command, .control])
            Button("Calendar: Month") { calendar("month") }.keyboardShortcut("3", modifiers: [.command, .control])
        }
        CommandGroup(after: .importExport) {
            Button("Export \(LifeBoardEnvironment.productName) Data…") { _ = store.exportBackup() }
            if LifeBoardEnvironment.isPreview {
                Button("Load Sample Student Week…") { store.offerSampleWeek() }
                Button("Clear Preview Planner…") { store.offerEmptyPlanner() }
            }
        }
        CommandGroup(replacing: .help) {
            Button("\(LifeBoardEnvironment.productName) Help") { openWindow(id: "help") }.keyboardShortcut("?", modifiers: .command)
        }
    }

    private func calendar(_ command: String) {
        let switching = selectedRaw != AppSection.calendar.rawValue
        selectedRaw = AppSection.calendar.rawValue
        DispatchQueue.main.asyncAfter(deadline: .now() + (switching ? 0.15 : 0)) {
            NotificationCenter.default.post(name: .lifeBoardCalendarCommand, object: command)
        }
    }
}
