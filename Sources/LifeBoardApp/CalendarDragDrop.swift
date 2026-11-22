import AppKit
import LifeBoardCore
import SwiftUI
import UniformTypeIdentifiers

private let calendarItemType = UTType(exportedAs: LifeBoardEnvironment.calendarItemTypeIdentifier)

extension AppStore {
    func calendarDragProvider(for item: CalendarDragItem) -> NSItemProvider {
        calendarDrag = item
        // Keep the text representation for the existing subject, project and board targets.
        let provider = NSItemProvider(object: item.payload as NSString)
        let bytes = Data(item.payload.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: calendarItemType.identifier, visibility: .ownProcess) { completion in
            completion(bytes, nil)
            return nil
        }
        return provider
    }
}

enum CalendarDropDestination {
    case timeline(hourHeight: CGFloat)
    case date
    case untimed
}

private struct CalendarDropPreview: Equatable {
    let start: Int?
    let duration: Int?
    let files: Bool
}

extension View {
    func calendarDrop(day: LocalDay, destination: CalendarDropDestination) -> some View {
        modifier(CalendarDropTarget(day: day, destination: destination))
    }
}

private struct CalendarDropTarget: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var preview: CalendarDropPreview?
    @State private var pendingFileDrops = 0
    @State private var scrollProbe = CalendarDragScrollProbe()
    let day: LocalDay
    let destination: CalendarDropDestination

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if case .timeline = destination {
                    CalendarDragScrollReader(probe: scrollProbe).frame(width: 0, height: 0)
                }
            }
            .overlay(alignment: .topLeading) {
                if let preview {
                    if case .timeline(let hourHeight) = destination, let start = preview.start {
                        timelineIndicator(start: start, preview: preview, hourHeight: hourHeight)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .onDrop(of: [calendarItemType, .fileURL], delegate: CalendarDropHandler(
                store: store, day: day, destination: destination, preview: $preview,
                pendingFileDrops: $pendingFileDrops, scrollProbe: scrollProbe
            ))
            .overlay(alignment: .topTrailing) {
                if pendingFileDrops > 0 {
                    ProgressView().controlSize(.small).padding(6)
                        .accessibilityLabel("Reading dropped files").allowsHitTesting(false)
                }
            }
    }

    private func timelineIndicator(start: Int, preview: CalendarDropPreview, hourHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let y = CGFloat(start) * hourHeight / 60
            let end = min(1440, start + (preview.duration ?? 0))
            let height = max(2, CGFloat(end - start) * hourHeight / 60)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.16))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1) }
                .frame(height: height)
                .offset(y: y)
            Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: y)
            HStack(spacing: 4) {
                if preview.files { Image(systemName: "doc.badge.plus") }
                Text(timeString(start)).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .padding(.leading, 4)
            .offset(y: min(max(0, y - 22), max(0, geometry.size.height - 22)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CalendarDropHandler: DropDelegate {
    let store: AppStore
    let day: LocalDay
    let destination: CalendarDropDestination
    @Binding var preview: CalendarDropPreview?
    @Binding var pendingFileDrops: Int
    let scrollProbe: CalendarDragScrollProbe

    func validateDrop(info: DropInfo) -> Bool { target(at: info) != nil }

    func dropEntered(info: DropInfo) { updatePreview(target(at: info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = target(at: info)
        updatePreview(target)
        guard let target else { return DropProposal(operation: .forbidden) }
        scrollProbe.scrollDuringDrop()
        return DropProposal(operation: target.files ? .copy : .move)
    }

    func dropExited(info: DropInfo) { updatePreview(nil) }

    func performDrop(info: DropInfo) -> Bool {
        defer { updatePreview(nil) }
        guard let target = target(at: info) else { return false }
        if target.files {
            return importFiles(info.itemProviders(for: [.fileURL]), start: target.start)
        }

        guard let item = store.calendarDrag,
              let provider = info.itemProviders(for: [calendarItemType]).first else { return false }
        store.calendarDrag = nil
        provider.loadDataRepresentation(forTypeIdentifier: calendarItemType.identifier) { data, _ in
            let payload = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                guard payload == item.payload else {
                    store.message = .init(title: "Couldn't Move Item", detail: "LifeBoard couldn't read the dragged item. Try dragging it again.")
                    return
                }
                let moved: Bool
                switch item {
                case .task(let id):
                    if case .untimed = destination {
                        moved = store.unscheduleTime(id, day: day)
                    } else {
                        moved = store.moveScheduledTask(id, day: day, startMinutes: target.start)
                    }
                case .event(let id):
                    if let start = target.start ?? store.data.events.first(where: { $0.id == id })?.startMinutes {
                        moved = store.moveEvent(id, day: day, startMinutes: start)
                    } else {
                        moved = false
                    }
                }
                if !moved, store.message == nil {
                    store.message = .init(title: "Couldn't Move Item", detail: "The item is no longer available on this calendar.")
                }
            }
        }
        return true
    }

    private func target(at info: DropInfo) -> CalendarDropPreview? {
        var duration: Int?
        var eventDuration: Int?
        let files = info.hasItemsConforming(to: [.fileURL])
        if files {
            duration = store.data.settings.defaultTaskMinutes
        } else {
            guard info.hasItemsConforming(to: [calendarItemType]) else { return nil }
            switch store.calendarDrag {
            case .task(let id):
                guard let task = store.data.tasks.first(where: { $0.id == id && !$0.isCompleted && !$0.isArchived }) else { return nil }
                duration = task.scheduledStartMinutes == nil ? task.estimatedMinutes : task.scheduledDurationMinutes ?? task.estimatedMinutes
            case .event(let id):
                if case .untimed = destination { return nil }
                guard let event = store.data.events.first(where: { $0.id == id }) else { return nil }
                duration = event.endMinutes - event.startMinutes
                eventDuration = duration
            case nil:
                return nil
            }
        }
        let start: Int?
        if case .timeline(let hourHeight) = destination {
            start = SchedulingEngine.calendarDropStart(y: info.location.y, hourHeight: hourHeight, eventDuration: eventDuration)
        } else {
            start = nil
        }
        return CalendarDropPreview(start: start, duration: duration, files: files)
    }

    private func updatePreview(_ value: CalendarDropPreview?) {
        if preview != value { preview = value }
    }

    private func importFiles(_ providers: [NSItemProvider], start: Int?) -> Bool {
        guard !providers.isEmpty else { return false }
        pendingFileDrops += 1
        let batch = CalendarFileBatch(count: providers.count) { urls in
            pendingFileDrops -= 1
            guard let urls else {
                store.message = .init(title: "Couldn't Schedule Files", detail: "LifeBoard couldn't read every file in the drop. Drag the files from Finder and try again.")
                return
            }
            if !store.addCalendarFiles(urls, day: day, startMinutes: start), store.message == nil {
                store.message = .init(title: "Couldn't Schedule Files", detail: "LifeBoard couldn't use the file links in this drop.")
            }
        }
        for (index, provider) in providers.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                Task { @MainActor in batch.finish(index: index, url: url) }
            }
        }
        return true
    }
}

private struct CalendarDragScrollReader: NSViewRepresentable {
    let probe: CalendarDragScrollProbe
    func makeNSView(context: Context) -> CalendarDragScrollProbe { probe }
    func updateNSView(_ nsView: CalendarDragScrollProbe, context: Context) {}
}

/// Uses the native drag update cadence and the scroll view's visible bounds.
/// Scrolling stops with the drag, without a background timer.
private final class CalendarDragScrollProbe: NSView {
    private var lastScrollTime: TimeInterval = 0

    func scrollDuringDrop() {
        guard let window, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let pointer = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = clip.bounds
        guard bounds.contains(pointer) else { return }
        let edge = min(34, bounds.height / 4)
        let fromTop = clip.isFlipped ? pointer.y - bounds.minY : bounds.maxY - pointer.y
        let fromBottom = bounds.height - fromTop
        let delta = max(0, edge - fromBottom) - max(0, edge - fromTop)
        let now = ProcessInfo.processInfo.systemUptime
        guard delta != 0, now - lastScrollTime > 0.045 else { return }
        let direction: CGFloat = document.isFlipped ? 1 : -1
        let proposed = NSPoint(x: bounds.origin.x, y: bounds.origin.y + direction * delta * 0.8)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: proposed, size: bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        lastScrollTime = now
    }
}

@MainActor
private final class CalendarFileBatch {
    private var urls: [URL?]
    private var remaining: Int
    private let complete: ([URL]?) -> Void

    init(count: Int, complete: @escaping ([URL]?) -> Void) {
        urls = Array(repeating: nil, count: count)
        remaining = count
        self.complete = complete
    }

    func finish(index: Int, url: URL?) {
        urls[index] = url
        remaining -= 1
        guard remaining == 0 else { return }
        let resolved = urls.compactMap { $0 }
        complete(resolved.count == urls.count ? resolved : nil)
    }
}
