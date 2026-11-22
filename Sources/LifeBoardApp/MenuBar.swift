import AppKit
import SwiftUI
import LifeBoardCore

/// The menu bar item: the count due or planned today in the bar; the panel shows Now/Next,
/// a quick New To Do field and every open To Do (overdue and today first), each with its
/// check and progress slider, plus ways into the main window and Capture.
struct MenuBarLabel: View {
    @ObservedObject var store: AppStore
    var body: some View {
        let count = store.index.todayCount() + store.index.overdueCount()
        if count > 0 { Label("\(count)", systemImage: "checklist").labelStyle(.titleAndIcon).accessibilityLabel("LifeBoard, \(count) To Dos for today") } else { Image(systemName: "checklist").accessibilityLabel("LifeBoard") }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Binding var showCapture: Bool
    @State private var focusEntry = 0
    private let limit = 12

    private var tasks: [TaskItem] {
        let groups = store.index.todayGroups(lingering: store.lingeringCompletions, search: "")
        // Like Today: every open To Do, overdue and today's first.
        return groups.filter { $0.id != "done" }.flatMap(\.tasks)
    }

    var body: some View {
        let list = tasks
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.headline)
                Text(store.index.today.date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            NowNextStrip()
            QuickEntryField(context: .today, focusRequest: $focusEntry)
            Divider()
            if list.isEmpty {
                Text("No open To Dos.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(list.prefix(limit)) { task in TaskRow(task: task, compact: true, showsDay: true) }
                    }
                }
                .frame(maxHeight: 360)
                if list.count > limit {
                    Text("\(list.count - limit) more in LifeBoard").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button("Open LifeBoard") { openMain() }
                Spacer()
                Button("Capture…") { openMain(); showCapture = true }
            }
        }
        .padding(14)
        .frame(width: 380)
        .tint(LB.accent)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        store.requestedSectionRaw = AppSection.today.rawValue
    }
}
