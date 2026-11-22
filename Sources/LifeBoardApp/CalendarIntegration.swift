import AppKit
import Combine
import CryptoKit
import EventKit
import Foundation
import LifeBoardCore

struct ExternalCalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let account: String
}

@MainActor
final class CalendarIntegrationService {
    private let store = EKEventStore()
    private var permissionRequest: Task<Bool, Never>?
    private var changeSubscription: AnyCancellable?
    var onChange: (@MainActor () -> Void)?

    init() {
        changeSubscription = NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
    }

    func refreshAccountSources() {
        store.refreshSourcesIfNecessary()
    }

    private var colourCache: [String: NSColor] = [:]

    /// The colour chosen for this calendar in Calendar, so connected events
    /// look the same in LifeBoard. Read locally; nothing is stored or synced.
    func colour(forCalendarID id: String) -> NSColor? {
        if let cached = colourCache[id] { return cached }
        guard hasFullAccess, let calendar = store.calendar(withIdentifier: id) else { return nil }
        let colour = NSColor(cgColor: calendar.cgColor)
        if let colour { colourCache[id] = colour }
        return colour
    }

    func refreshLocalStore() {
        colourCache = [:]
        guard hasFullAccess else { return }
        // This integration only reads events; there are no unsaved EventKit
        // edits to lose when invalidating objects from an earlier query.
        store.reset()
    }

    /// Background refreshes only inspect permission; they never open a prompt.
    var hasFullAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    var accessGuidance: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted:
            "Calendar access is off. Saved events are kept. Allow LifeBoard in macOS System Settings › Privacy & Security › Calendars, then use Settings › Integrations › Connect Calendars."
        default:
            "Saved calendar events are kept. To reconnect, choose Settings › Integrations › Connect Calendars."
        }
    }

    func requestAccess() async -> Bool {
        if let permissionRequest { return await permissionRequest.value }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        if status == .denied || status == .restricted { return false }
        // Only the explicit Connect Calendars action calls this method. Share
        // one request when several clicks arrive while the system dialog is up.
        let request = Task { @MainActor in
            let granted = await withCheckedContinuation { continuation in
                self.store.requestFullAccessToEvents { allowed, _ in
                    continuation.resume(returning: allowed)
                }
            }
            if granted { self.store.reset() }
            return granted
        }
        permissionRequest = request
        let granted = await request.value
        permissionRequest = nil
        return granted
    }

    func availableCalendars() -> [ExternalCalendarChoice] {
        guard hasFullAccess else { return [] }
        return store.calendars(for: .event)
            .filter { calendar in
                guard let source = calendar.source else { return false }
                return source.sourceType == .calDAV || source.sourceType == .exchange || source.title.localizedCaseInsensitiveContains("google") || source.title.localizedCaseInsensitiveContains("gmail")
            }
            .map { ExternalCalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Calendar account") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func events(calendarIDs: [String], from start: Date, to end: Date) -> [ExternalCalendarEvent] {
        guard hasFullAccess else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        var seen = Set<String>()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)).compactMap { event in
            guard let calendar = event.calendar, let startDate = event.startDate, let endDate = event.endDate else { return nil }
            // Recurring occurrences can share EventKit IDs, and those IDs can
            // exceed the sync API's limit. Include the start instant, then hash
            // the identity so each occurrence has a stable compact ID.
            let occurrence = Int64((startDate.timeIntervalSince1970 * 1_000).rounded())
            let identity = "\(calendar.calendarIdentifier)|\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(occurrence)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { return nil }
            let startParts = Calendar.current.dateComponents([.hour, .minute], from: startDate)
            let endParts = Calendar.current.dateComponents([.hour, .minute], from: endDate)
            let startMinutes = (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            let endMinutes = (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0)
            return ExternalCalendarEvent(id: id, calendarID: calendar.calendarIdentifier, calendarTitle: calendar.title, title: event.title ?? "Busy", day: LocalDay(startDate), startMinutes: event.isAllDay ? 0 : startMinutes, endMinutes: event.isAllDay || LocalDay(endDate) > LocalDay(startDate) ? 1440 : endMinutes, isAllDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "", startInstant: startDate, endInstant: endDate, timeZoneIdentifier: event.timeZone?.identifier ?? Calendar.current.timeZone.identifier)
        }
    }

    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
