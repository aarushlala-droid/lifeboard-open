import SwiftUI
import WidgetKit
import LifeBoardCore

private struct AgendaEntry: TimelineEntry {
    let date: Date
    let snapshot: LifeBoardWidgetSnapshot
    let hasLiveData: Bool
}

private struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry { AgendaEntry(date: .now, snapshot: placeholderSnapshot, hasLiveData: true) }
    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) { completion(liveEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        completion(Timeline(entries: [liveEntry()], policy: .after(Date.now.addingTimeInterval(15 * 60))))
    }

    private func liveEntry() -> AgendaEntry {
        let snapshot = LifeBoardSharedStore.readSnapshot()
        return AgendaEntry(date: .now, snapshot: snapshot ?? LifeBoardWidgetSnapshot(data: LifeBoardData()), hasLiveData: snapshot != nil)
    }

    private var placeholderSnapshot: LifeBoardWidgetSnapshot {
        var data = LifeBoardData()
        var task = TaskItem(title: "Your next task")
        task.scheduledDay = .today
        task.scheduledStartMinutes = 17 * 60 + 30
        task.estimatedMinutes = 45
        data.tasks = [task, TaskItem(title: "Another To Do")]
        return LifeBoardWidgetSnapshot(data: data, now: LocalDay.today.date().addingTimeInterval(12 * 60 * 60))
    }
}

private struct LifeBoardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry
    private var items: [WidgetAgendaItem] { Array(entry.snapshot.agenda.prefix(family == .systemSmall ? 1 : 3)) }
    private var toDos: [WidgetToDoItem] { Array(entry.snapshot.toDos.prefix(family == .systemSmall ? 1 : 3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 9) {
            HStack {
                Label(entry.snapshot.activeFocusTitle == nil ? "NEXT" : "FOCUS", systemImage: entry.snapshot.activeFocusTitle == nil ? "arrow.right.circle.fill" : "timer")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.snapshot.remainingToDos) TO DO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !entry.hasLiveData {
                Spacer()
                Text("Open LifeBoard to refresh").font(.headline)
                Text("Your To Dos will appear here.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if let focusTitle = entry.snapshot.activeFocusTitle {
                Text(focusTitle).font(.headline).lineLimit(2)
                if let end = entry.snapshot.activeFocusEnd { Text(end, style: .timer).font(.title2.bold().monospacedDigit()).foregroundStyle(.tint) }
            } else if items.isEmpty && toDos.isEmpty {
                Spacer()
                Text("Nothing else scheduled").font(.headline)
                Text("You're clear.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Link(destination: URL(string: item.isTask ? "lifeboard://task/\(item.id.uuidString)" : "lifeboard://calendar")!) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(index == 0 ? timeRange(item) : shortTime(item.startMinutes)).font(.caption.monospacedDigit()).foregroundStyle(index == 0 ? Color.accentColor : .secondary).frame(width: family == .systemSmall ? 54 : 78, alignment: .leading)
                            Text(item.title).font(index == 0 ? .headline : .subheadline).lineLimit(1)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if index == 0 && items.count > 1 { Divider() }
                }
                if !toDos.isEmpty {
                    if !items.isEmpty { Divider() }
                    Text("TO DO").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(toDos) { task in
                        Link(destination: URL(string: "lifeboard://task/\(task.id.uuidString)")!) {
                            HStack(spacing: 5) {
                                Image(systemName: "circle").font(.caption2)
                                Text(task.title).font(family == .systemSmall ? .subheadline : .callout).lineLimit(1)
                                Spacer(minLength: 0)
                                if family == .systemMedium && task.completionPercent > 0 {
                                    Text("\(Int(task.completionPercent))%").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "lifeboard://todo"))
    }

    private func shortTime(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    private func timeRange(_ item: WidgetAgendaItem) -> String { "\(shortTime(item.startMinutes))–\(shortTime(item.endMinutes))" }
}

private struct LifeBoardAgendaWidget: Widget {
    let kind = "LifeBoardAgendaWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgendaProvider()) { entry in LifeBoardWidgetView(entry: entry) }
            .configurationDisplayName("LifeBoard Next")
            .description("Your next scheduled item and remaining To Dos.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LifeBoardWidgets: WidgetBundle {
    var body: some Widget { LifeBoardAgendaWidget() }
}
