import SwiftUI
import Combine
import LifeBoardCore

@main
struct LifeBoardApp: App {
    @StateObject private var store = AppStore()
    @AppStorage("selectedSection") private var selectedRaw = AppSection.today.rawValue
    @State private var showQuickAdd = false
    @Environment(\.scenePhase) private var scenePhase
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some Scene {
        Window("LifeBoard", id: "main") {
            RootView(selected: Binding(get: { AppSection(rawValue: selectedRaw) ?? .today }, set: { selectedRaw = $0.rawValue }), showQuickAdd: $showQuickAdd)
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { store.handle(url: $0) }
                .onReceive(refreshTimer) { date in store.reloadIfChanged(); store.tickFocus(now: date); store.performICloudBackup(); store.syncTick(); store.refreshConnectedCalendarsIfNeeded(now: date) }
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshConnectedCalendarsIfNeeded(force: true) } }
                .sheet(isPresented: Binding(get: { !store.data.settings.hasCompletedOnboarding }, set: { _ in })) { WelcomeWalkthroughView().environmentObject(store) }
                .sheet(item: $store.pendingExternalImport) { preview in ExternalImportReviewView(preview: preview).environmentObject(store) }
                .sheet(isPresented: $showQuickAdd) { QuickAddView().environmentObject(store) }
                .alert(item: $store.message) { message in Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK"))) }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Capture…") { showQuickAdd = true }.keyboardShortcut("n") }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { selectedRaw = AppSection.settings.rawValue }.keyboardShortcut(",", modifiers: .command) }
            CommandMenu("Navigate") {
                ForEach(AppSection.primary) { section in Button(section.title) { selectedRaw = section.rawValue }.keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command) }
            }
            CommandGroup(after: .importExport) { Button("Export LifeBoard Data…") { _ = store.exportBackup() } }
        }

    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case today, calendar, inbox, focus, subjects, projects, year, completed, settings, help
    var id: String { rawValue }
    var title: String { switch self { case .inbox: "To Do"; case .year: "Important Dates"; default: rawValue.capitalized } }
    var icon: String { switch self { case .today: "sun.max"; case .calendar: "calendar"; case .inbox: "checklist"; case .focus: "timer"; case .subjects: "books.vertical"; case .projects: "folder"; case .year: "timeline.selection"; case .completed: "checkmark.circle"; case .settings: "gearshape"; case .help: "questionmark.circle" } }
    var shortcut: Character { switch self { case .today: "1"; case .inbox: "2"; case .calendar: "3"; case .focus: "4"; case .subjects: "5"; case .projects: "6"; case .year: "7"; case .completed: "8"; case .settings: "0"; case .help: "9" } }
    static let primary: [AppSection] = [.today, .inbox, .calendar, .focus, .subjects, .projects, .year]
}
