import AppKit
import SwiftUI
import LifeBoardCore

enum CalendarMode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month"; var id: String { rawValue } }

struct CalendarRefreshButton: View {
    @EnvironmentObject private var store: AppStore
    @State private var isRefreshing = false
    @State private var showsStatus = false
    @State private var status = ""

    var body: some View {
        Button {
            isRefreshing = true
            Task {
                status = await store.refreshSelectedCalendarsNow()
                isRefreshing = false
                showsStatus = true
            }
        } label: {
            if isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh Calendars", systemImage: "arrow.clockwise") }
        }
        .labelStyle(.iconOnly)
        .disabled(isRefreshing)
        .help("Refresh connected calendars")
        .popover(isPresented: $showsStatus) { Text(status).font(.callout).frame(width: 240, alignment: .leading).padding(12) }
    }
}

// MARK: - Time grid

/// Hour labels share the grid's origin. The current time is drawn in the
/// lamp colour on today's gutter.
struct CalendarTimeGutter: View {
    let width: CGFloat
    let hourHeight: CGFloat
    var showsNow: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour == 0 ? "" : timeString(hour * 60)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 7)
                        .frame(width: width, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                }
            }
            if showsNow {
                TimelineView(.everyMinute) { context in
                    let minute = CalendarViewport.currentMinute(now: context.date)
                    Text(timeString(minute)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(LB.lampText)
                        .padding(.horizontal, 3)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .padding(.trailing, 4)
                        .offset(y: CGFloat(minute) * hourHeight / 60 - 7)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: 24 * hourHeight, alignment: .top)
    }
}

/// One drawing for every hour and half-hour line in a column.
struct CalendarGridLines: View {
    let hourHeight: CGFloat
    var body: some View {
        Canvas { context, size in
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight
                var line = Path(); line.move(to: CGPoint(x: 0, y: y + 0.5)); line.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                context.stroke(line, with: .color(Color(nsColor: .separatorColor)), lineWidth: hour == 0 ? 0 : 1)
                var half = Path(); half.move(to: CGPoint(x: 0, y: y + hourHeight / 2 + 0.5)); half.addLine(to: CGPoint(x: size.width, y: y + hourHeight / 2 + 0.5))
                context.stroke(half, with: .color(Color(nsColor: .separatorColor).opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NowLine: View {
    let hourHeight: CGFloat
    var body: some View {
        TimelineView(.everyMinute) { context in
            let minute = CalendarViewport.currentMinute(now: context.date)
            Rectangle().fill(LB.lamp).frame(height: 1.5)
                .overlay(alignment: .leading) { LampDot(size: 7).offset(x: -3) }
                .offset(y: CGFloat(minute) * hourHeight / 60 - 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Day column

struct CalendarDayColumn: View {
    @EnvironmentObject private var store: AppStore
    let day: LocalDay
    let width: CGFloat
    let hourHeight: CGFloat
    @State private var slotToCreate: CalendarSlot?

    var body: some View {
        let lanes = store.index.agenda(for: day).lanes
        let isToday = day == store.index.today
        ZStack(alignment: .topLeading) {
            CalendarGridLines(hourHeight: hourHeight)
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Color.clear
                        .frame(width: width, height: hourHeight)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                            slotToCreate = CalendarSlot(day: day, startMinutes: SchedulingEngine.calendarDropStart(y: CGFloat(hour) * hourHeight + tap.location.y, hourHeight: hourHeight))
                        })
                        .contextMenu { Button("Add at \(timeString(hour * 60))…") { slotToCreate = CalendarSlot(day: day, startMinutes: hour * 60) } }
                        .accessibilityHidden(true)
                }
            }
            ForEach(lanes) { lane in
                let laneWidth = width / CGFloat(lane.laneCount)
                let inset = min(2, laneWidth / 4)
                CalendarItemBlock(lane: lane, day: day, hourHeight: hourHeight)
                    .frame(width: max(4, laneWidth - 2 * inset), height: max(14, CGFloat(lane.end - lane.start) * hourHeight / 60 - 1))
                    .offset(x: CGFloat(lane.lane) * laneWidth + inset, y: CGFloat(lane.start) * hourHeight / 60)
            }
            if isToday { NowLine(hourHeight: hourHeight).frame(width: width) }
        }
        .frame(width: width, height: 24 * hourHeight, alignment: .topLeading)
        .background(isToday ? LB.lampGlow.opacity(0.05) : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).allowsHitTesting(false) }
        .calendarDrop(day: day, destination: .timeline(hourHeight: hourHeight))
        .sheet(item: $slotToCreate) { CalendarSlotCreationView(slot: $0).environmentObject(store) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.date().formatted(date: .complete, time: .omitted))
    }
}

/// Routes a lane to its task, event or connected-calendar block.
private struct CalendarItemBlock: View {
    @EnvironmentObject private var store: AppStore
    let lane: CalendarLane
    let day: LocalDay
    let hourHeight: CGFloat

    var body: some View {
        if let id = UUID(uuidString: lane.id), let task = store.index.tasksByID[id] {
            TaskBlock(task: task, start: lane.start, end: lane.end, hourHeight: hourHeight)
        } else if let id = UUID(uuidString: lane.id), let event = store.index.eventsByID[id] {
            EventBlock(event: event, hourHeight: hourHeight)
        } else if let event = store.index.externalByID[lane.id] {
            ExternalEventBlock(event: event, start: lane.start, end: lane.end)
        }
    }
}

private struct TaskBlock: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    let start: Int
    let end: Int
    let hourHeight: CGFloat
    @State private var resizeMinutes: Int?

    var body: some View {
        let shownEnd = resizeMinutes.map { start + $0 } ?? end
        CalendarCardLabel(title: task.title, detail: "\(timeString(start))–\(timeString(shownEnd % 1440))", tint: LB.accent, selected: store.selectedTaskID == task.id, done: task.isCompleted)
            .offset(y: 0)
            .frame(height: resizeMinutes.map { max(14, CGFloat($0) * hourHeight / 60 - 1) }, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { ResizeHandle(hourHeight: hourHeight, minutes: task.scheduledDurationMinutes ?? task.estimatedMinutes, live: $resizeMinutes) { store.resizeTask(task.id, durationMinutes: $0) } }
            .onTapGesture { store.selectedTaskID = task.id }
            .onDrag { store.calendarDragProvider(for: .task(task.id)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(task.title), \(timeString(start)) to \(timeString(end % 1440))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.selectedTaskID = task.id }
            .accessibilityAction(named: "Mark as done") { store.toggleCompletion(task.id, reduceMotion: reduceMotion) }
            .help("\(task.title) · \(timeString(start))–\(timeString(end % 1440))")
            .contextMenu {
                Button("Show Details", systemImage: "info.circle") { store.selectedTaskID = task.id }
                Button("Mark as Done", systemImage: "checkmark.circle") { store.toggleCompletion(task.id, reduceMotion: reduceMotion) }
                Divider()
                Button("Find a Free Time Today") {
                    let request = ScheduleRequest(id: task.id, duration: task.scheduledDurationMinutes ?? task.estimatedMinutes)
                    if let start = SchedulingEngine.suggest([request], data: store.data, day: .today).first?.start { _ = store.acceptSuggestedPlan([task.id: start], day: .today) }
                    else { store.message = .init(title: "No Free Time Today", detail: "Nothing fits before the end of your planning window. Drag the task to another time instead.") }
                }
                Button("Move to Today") { store.moveScheduledTask(task.id, day: .today) }
                Button("Remove Exact Time") { store.unscheduleTime(task.id) }
                Button("Remove from Calendar") { store.moveToInbox(task.id) }
                Divider()
                Button("Duplicate") { store.duplicateTask(task.id) }
                Button("Move to Trash", role: .destructive) { store.deleteTask(task.id) }
            }
    }
}

private struct EventBlock: View {
    @EnvironmentObject private var store: AppStore
    let event: CalendarEvent
    let hourHeight: CGFloat
    @State private var resizeMinutes: Int?

    var body: some View {
        let end = resizeMinutes.map { event.startMinutes + $0 } ?? event.endMinutes
        CalendarCardLabel(title: event.title, detail: "\(timeString(event.startMinutes))–\(timeString(end % 1440))" + (event.location.isEmpty ? "" : "  \(event.location)"), tint: LB.event, selected: store.selectedEventID == event.id)
            .frame(height: resizeMinutes.map { max(14, CGFloat($0) * hourHeight / 60 - 1) }, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                ResizeHandle(hourHeight: hourHeight, minutes: event.endMinutes - event.startMinutes, maximum: 1440 - event.startMinutes, live: $resizeMinutes) { minutes in
                    var updated = event; updated.endMinutes = min(1440, event.startMinutes + minutes); store.updateEvent(updated)
                }
            }
            .onTapGesture { store.selectedEventID = event.id }
            .onDrag { store.calendarDragProvider(for: .event(event.id)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Event, \(event.title), \(timeString(event.startMinutes)) to \(timeString(event.endMinutes % 1440))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.selectedEventID = event.id }
            .help("\(event.title) · \(timeString(event.startMinutes))–\(timeString(event.endMinutes % 1440))")
            .contextMenu {
                Button("Show Details", systemImage: "info.circle") { store.selectedEventID = event.id }
                Button("Duplicate") { store.duplicateEvent(event.id) }
                Divider()
                Button("Delete Event", role: .destructive) { store.deleteEvent(event.id) }
            }
    }
}

private struct ExternalEventBlock: View {
    @EnvironmentObject private var store: AppStore
    let event: ExternalCalendarEvent
    let start: Int
    let end: Int
    @State private var showsDetails = false

    var body: some View {
        CalendarCardLabel(title: event.title, detail: "\(timeString(start))–\(timeString(end % 1440))  \(event.calendarTitle)", tint: store.connectedColour(event.calendarID), selected: showsDetails, readOnly: true)
            .onTapGesture { showsDetails = true }
            .popover(isPresented: $showsDetails, arrowEdge: .trailing) { ExternalEventDetails(event: event) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(event.title), \(timeString(start)) to \(timeString(end % 1440)), \(event.calendarTitle), read only")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showsDetails = true }
            .help("\(event.title) · \(event.calendarTitle) · read only")
    }
}

struct ExternalEventDetails: View {
    let event: ExternalCalendarEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title).font(.headline)
            if let start = event.startInstant, let end = event.endInstant {
                Text(event.isAllDay ? start.formatted(date: .complete, time: .omitted) : "\(start.formatted(date: .abbreviated, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
                if let zone = event.timeZoneIdentifier, zone != TimeZone.current.identifier, !event.isAllDay {
                    Text("Shown in your time zone. Original zone: \(zone)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(event.isAllDay ? "All day" : "\(timeString(event.startMinutes))–\(timeString(event.endMinutes % 1440))").foregroundStyle(.secondary)
            }
            Label(event.calendarTitle, systemImage: "calendar").foregroundStyle(.secondary)
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
            if !event.notes.isEmpty { Text(event.notes).font(.callout).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled) }
            Text("From a connected calendar. LifeBoard only reads it.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

/// Drag the bottom edge of a block to change its length, in five-minute steps.
private struct ResizeHandle: View {
    let hourHeight: CGFloat
    let minutes: Int
    var maximum = 8 * 60
    @Binding var live: Int?
    let commit: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(Color.clear).frame(height: 7).contentShape(Rectangle())
            .overlay { if hovering || live != nil { Capsule().fill(.secondary.opacity(0.6)).frame(width: 18, height: 3) } }
            .onHover { inside in hovering = inside; if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let delta = Int((value.translation.height / hourHeight * 60 / 5).rounded()) * 5
                    live = min(maximum, max(15, minutes + delta))
                }
                .onEnded { _ in
                    if let value = live, value != minutes { commit(value) }
                    live = nil
                })
            .accessibilityHidden(true)
    }
}

struct CalendarCardLabel: View {
    let title: String
    let detail: String
    let tint: Color
    var selected = false
    var done = false
    var readOnly = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font((height >= 30 ? Font.caption : .caption2).weight(.semibold)).lineLimit(height >= 44 ? 2 : 1)
                    .strikethrough(done)
                if height >= 30 { Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.leading, 7).padding(.trailing, 4).padding(.top, height >= 22 ? 3 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            RoundedRectangle(cornerRadius: LB.blockCorner).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: LB.blockCorner).fill(tint.opacity(selected ? 0.26 : readOnly ? 0.10 : 0.16))
        }
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3).padding(.vertical, 2).padding(.leading, 1.5) }
        .overlay { if selected { RoundedRectangle(cornerRadius: LB.blockCorner).strokeBorder(tint, lineWidth: 1.25) } }
        .opacity(done ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - All-day band

/// Untimed tasks, important dates, milestones and all-day connected events.
struct AllDayCell: View {
    @EnvironmentObject private var store: AppStore
    let day: LocalDay
    var limit = 3
    var includesUntimedTasks = true
    var onMore: () -> Void = {}

    var body: some View {
        let agenda = store.index.agenda(for: day)
        let items = chips(agenda)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.prefix(limit)) { $0.view }
            if items.count > limit {
                Button("\(items.count - limit) more") { onMore() }.buttonStyle(.plain).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .calendarDrop(day: day, destination: .untimed)
    }

    private struct Chip: Identifiable { let id: String; let view: AnyView }

    private func chips(_ agenda: DayAgenda) -> [Chip] {
        var result: [Chip] = []
        for task in includesUntimedTasks ? agenda.untimedTasks : [] {
            result.append(Chip(id: task.id.uuidString, view: AnyView(
                Text(task.title).font(.caption2.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LB.accent.opacity(store.selectedTaskID == task.id ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedTaskID = task.id }
                    .onDrag { store.calendarDragProvider(for: .task(task.id)) }
                    .contextMenu { TaskActionsMenu(ids: [task.id]) }
                    .help("\(task.title) · untimed")
                    .accessibilityAddTraits(.isButton)
            )))
        }
        for marker in agenda.markers { result.append(Chip(id: marker.id.uuidString, view: AnyView(labelChip(marker.title, symbol: "flag.fill", tint: LB.marker)))) }
        for item in agenda.milestones { result.append(Chip(id: item.milestone.id.uuidString, view: AnyView(labelChip(item.milestone.title, symbol: "diamond.fill", tint: LB.marker)))) }
        for event in agenda.allDay {
            result.append(Chip(id: event.id, view: AnyView(ExternalAllDayChip(event: event))))
        }
        return result
    }

    private func labelChip(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ExternalAllDayChip: View {
    @EnvironmentObject private var store: AppStore
    let event: ExternalCalendarEvent
    @State private var showsDetails = false
    var body: some View {
        Text(event.title).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(store.connectedColour(event.calendarID).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { showsDetails = true }
            .popover(isPresented: $showsDetails) { ExternalEventDetails(event: event) }
            .help("\(event.title) · all day · read only")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Day timeline (Today and Calendar day view)

struct DayTimeline: View {
    @EnvironmentObject private var store: AppStore
    let day: LocalDay
    var nowRequest = CalendarViewport.defaultRequest
    var scrollContext = "day"
    var showsAllDay = true
    /// Today lists untimed To Dos beside the timeline, so it leaves them out here.
    var showsUntimedTasks = true
    private let gutter: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            let agenda = store.index.agenda(for: day)
            if showsAllDay, !agenda.allDay.isEmpty || !agenda.markers.isEmpty || !agenda.milestones.isEmpty || (showsUntimedTasks && !agenda.untimedTasks.isEmpty) {
                HStack(alignment: .top, spacing: 0) {
                    Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter, alignment: .trailing).padding(.trailing, 7).padding(.top, 5)
                    AllDayCell(day: day, limit: 4, includesUntimedTasks: showsUntimedTasks)
                }
                .frame(maxHeight: 96)
                Divider()
            }
            GeometryReader { geometry in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        CalendarTimeGutter(width: gutter, hourHeight: LB.hourHeight, showsNow: day == store.index.today)
                        CalendarDayColumn(day: day, width: max(1, geometry.size.width - gutter - 10), hourHeight: LB.hourHeight)
                    }
                    .padding(.trailing, 10).padding(.vertical, 8)
                    .background(CalendarScrollRestoration(
                        key: "\(scrollContext)-\(day.id)-\(TimeZone.current.identifier)",
                        initialOffset: CalendarViewport.initialOffset(includesToday: day == store.index.today, hourHeight: LB.hourHeight),
                        nowRequest: nowRequest,
                        storedOffset: { store.calendarScrollOffsets[$0] },
                        rememberOffset: { store.calendarScrollOffsets[$0] = $1 }
                    ).frame(width: 0, height: 0))
                }
            }
        }
    }
}

// MARK: - Calendar screen

struct CalendarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var mode: CalendarMode = .week
    @State private var nowRequest = UUID()
    @State private var anchor = LocalDay.today
    @State private var slotToCreate: CalendarSlot?
    @AppStorage("calendarMode") private var savedMode = CalendarMode.week.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .day:
                VStack(spacing: 0) {
                    DayWeekStrip(selectedDay: $anchor)
                    Divider()
                    DayTimeline(day: anchor, nowRequest: nowRequest, scrollContext: "calendar-day")
                }
            case .week:
                WeekCalendar(anchor: anchor, nowRequest: nowRequest, onOpenDay: openDay)
            case .month:
                MonthCalendar(anchor: anchor, onOpenDay: openDay, onAdd: addItem)
            }
        }
        .navigationTitle("Calendar")
        .sheet(item: $slotToCreate) { CalendarSlotCreationView(slot: $0).environmentObject(store) }
        .onAppear { mode = CalendarMode(rawValue: savedMode) ?? .week; anchor = store.index.today }
        .onChange(of: mode) { _, value in savedMode = value.rawValue }
        .onChange(of: store.temporalRevision) { _, _ in
            // Midnight or a time-zone change: follow "today" if the view was on it.
            anchor = store.index.today; nowRequest = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lifeBoardCalendarCommand)) { note in
            switch note.object as? String {
            case "today": goToToday()
            case "previous": shift(-1)
            case "next": shift(1)
            case "day": mode = .day
            case "week": mode = .week
            case "month": mode = .month
            default: break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(displayTitle).font(.title2.weight(.semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            Spacer(minLength: 8)
            ControlGroup {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("Previous (Command-[)").accessibilityLabel("Previous")
                Button("Today") { goToToday() }.help("Go to today and the current time (Shift-Command-T)")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("Next (Command-])").accessibilityLabel("Next")
            }
            .fixedSize()
            Picker("View", selection: $mode) { ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            CalendarRefreshButton()
            Button { addItem(anchor) } label: { Label("Add to Calendar", systemImage: "plus") }
                .labelStyle(.iconOnly).help("Add a task or event")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func goToToday() { anchor = store.index.today; nowRequest = UUID() }
    private func openDay(_ day: LocalDay) { anchor = day; mode = .day }

    private func addItem(_ day: LocalDay) {
        let start = day == store.index.today ? CalendarViewport.currentMinute() : 9 * 60
        slotToCreate = CalendarSlot(day: day, startMinutes: SchedulingEngine.calendarDropStart(y: Double(start), hourHeight: 60))
    }

    private func shift(_ direction: Int) {
        switch mode {
        case .month:
            if let date = Calendar.current.date(byAdding: .month, value: direction, to: anchor.date()) { anchor = LocalDay(date) }
        case .week: anchor = anchor.adding(days: direction * 7)
        case .day: anchor = anchor.adding(days: direction)
        }
    }

    private var displayTitle: String {
        switch mode {
        case .day: return anchor.date().formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let days = WeekMath.days(of: anchor, mondayFirst: store.data.settings.weekStartsMonday)
            let formatter = DateIntervalFormatter(); formatter.dateTemplate = "dMMMy"
            return formatter.string(from: days[0].date(), to: days[6].date())
        case .month: return anchor.date().formatted(.dateTime.month(.wide).year())
        }
    }
}

extension Notification.Name {
    static let lifeBoardCalendarCommand = Notification.Name("LifeBoardCalendarCommand")
}

private struct DayWeekStrip: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedDay: LocalDay

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WeekMath.days(of: selectedDay, mondayFirst: store.data.settings.weekStartsMonday)) { day in
                let isToday = day == store.index.today
                Button { selectedDay = day } label: {
                    VStack(spacing: 2) {
                        Text(day.date().formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(day.day)").font(.system(.subheadline, design: .rounded).weight(day == selectedDay ? .bold : .medium))
                            .foregroundStyle(isToday ? LB.lampText : .primary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(day == selectedDay ? LB.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.date().formatted(date: .complete, time: .omitted))
                .accessibilityValue(day == selectedDay ? "Selected" : isToday ? "Today" : "")
                .calendarDrop(day: day, destination: .date)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct WeekCalendar: View {
    @EnvironmentObject private var store: AppStore
    let anchor: LocalDay
    var nowRequest = CalendarViewport.defaultRequest
    let onOpenDay: (LocalDay) -> Void
    private let gutter: CGFloat = 52

    var body: some View {
        let days = WeekMath.days(of: anchor, mondayFirst: store.data.settings.weekStartsMonday)
        let rows = days.map { day -> Int in let a = store.index.agenda(for: day); return a.untimedTasks.count + a.markers.count + a.milestones.count + a.allDay.count }.max() ?? 0
        let bandHeight: CGFloat = rows == 0 ? 0 : min(3, CGFloat(rows)) * 21 + (rows > 3 ? 16 : 6)
        GeometryReader { geometry in
            let dayWidth = max(104, floor((geometry.size.width - gutter - 10) / 7))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutter)
                        ForEach(days) { day in
                            let isToday = day == store.index.today
                            Button { onOpenDay(day) } label: {
                                HStack(spacing: 5) {
                                    Text(day.date().formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    Text("\(day.day)").font(.system(.headline, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(isToday ? LB.lampText : .primary)
                                    if isToday { LampDot(size: 5) }
                                }
                                .frame(width: dayWidth, height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(day.date().formatted(date: .complete, time: .omitted))")
                            .accessibilityLabel(day.date().formatted(date: .complete, time: .omitted))
                            .accessibilityValue(isToday ? "Today" : "")
                            .calendarDrop(day: day, destination: .date)
                        }
                    }
                    .frame(height: 36)
                    if bandHeight > 0 {
                        Divider()
                        HStack(alignment: .top, spacing: 0) {
                            Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter - 7, alignment: .trailing).padding(.trailing, 7).padding(.top, 5)
                            ForEach(days) { day in
                                AllDayCell(day: day, limit: 3, onMore: { onOpenDay(day) })
                                    .frame(width: dayWidth, height: bandHeight)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
                            }
                        }
                        .frame(height: bandHeight)
                    }
                    Divider()
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            CalendarTimeGutter(width: gutter, hourHeight: LB.hourHeight, showsNow: days.contains(store.index.today))
                            ForEach(days) { day in CalendarDayColumn(day: day, width: dayWidth, hourHeight: LB.hourHeight) }
                        }
                        .padding(.trailing, 10).padding(.vertical, 8)
                        .background(CalendarScrollRestoration(
                            key: "week-\(days[0].id)-\(TimeZone.current.identifier)",
                            initialOffset: CalendarViewport.initialOffset(includesToday: days.contains(store.index.today), hourHeight: LB.hourHeight),
                            nowRequest: nowRequest,
                            storedOffset: { store.calendarScrollOffsets[$0] },
                            rememberOffset: { store.calendarScrollOffsets[$0] = $1 }
                        ).frame(width: 0, height: 0))
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: gutter + dayWidth * 7 + 10, alignment: .leading)
                .frame(height: geometry.size.height, alignment: .top)
            }
        }
    }
}

struct MonthCalendar: View {
    @EnvironmentObject private var store: AppStore
    let anchor: LocalDay
    let onOpenDay: (LocalDay) -> Void
    let onAdd: (LocalDay) -> Void

    var body: some View {
        let mondayFirst = store.data.settings.weekStartsMonday
        let first = LocalDay(year: anchor.year, month: anchor.month, day: 1)
        let leading = Calendar.current.dateComponents([.day], from: WeekMath.start(of: first, mondayFirst: mondayFirst).date(), to: first.date()).day ?? 0
        let count = Calendar.current.range(of: .day, in: .month, for: first.date())?.count ?? 30
        let cells: [LocalDay?] = Array(repeating: nil, count: leading) + (1...count).map { LocalDay(year: anchor.year, month: anchor.month, day: $0) }
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(WeekMath.weekdaySymbols(mondayFirst: mondayFirst), id: \.self) { symbol in
                    Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { MonthCell(day: day, selected: day == anchor, openDay: { onOpenDay(day) }, addItem: { onAdd(day) }) }
                    else { Color.clear.frame(minHeight: 92) }
                }
            }
            .padding(12)
        }
    }
}

private struct MonthCell: View {
    @EnvironmentObject private var store: AppStore
    @State private var hovering = false
    let day: LocalDay
    let selected: Bool
    let openDay: () -> Void
    let addItem: () -> Void

    var body: some View {
        let agenda = store.index.agenda(for: day)
        let isToday = day == store.index.today
        let tasks = agenda.untimedTasks.count + agenda.lanes.filter { store.index.tasksByID[UUID(uuidString: $0.id) ?? UUID()] != nil }.count
        let events = agenda.lanes.count - agenda.lanes.filter { store.index.tasksByID[UUID(uuidString: $0.id) ?? UUID()] != nil }.count + agenda.allDay.count
        let deadlines = agenda.deadlines.count + agenda.milestones.count + agenda.markers.count
        Button(action: openDay) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(day.day.formatted()).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(isToday ? LB.lampText : .primary)
                    if isToday { LampDot(size: 5) }
                }
                badge(tasks, "task", "tasks", "checklist", LB.accent)
                badge(events, "event", "events", "calendar", LB.event)
                badge(deadlines, "date", "dates", "flag", LB.marker)
            }
            .padding(7).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(LB.accent.opacity(selected ? 0.12 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(day.date().formatted(date: .complete, time: .omitted)), \(tasks) tasks, \(events) events, \(deadlines) dates")
        .accessibilityValue(isToday ? "Today" : "")
        .contextMenu {
            Button("Open Day", systemImage: "arrow.right.circle", action: openDay)
            Button("Add Task or Event…", systemImage: "plus", action: addItem)
        }
        .calendarDrop(day: day, destination: .date)
    }

    @ViewBuilder private func badge(_ count: Int, _ singular: String, _ plural: String, _ symbol: String, _ colour: Color) -> some View {
        if count > 0 {
            Label {
                ViewThatFits(in: .horizontal) {
                    Text("\(count) \(count == 1 ? singular : plural)").fixedSize(horizontal: true, vertical: false)
                    Text(count.formatted()).monospacedDigit()
                }
            } icon: { Image(systemName: symbol).foregroundStyle(colour) }
            .font(.caption2.weight(.medium)).lineLimit(1)
        }
    }
}
