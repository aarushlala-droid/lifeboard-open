import AppKit
import SwiftUI
import LifeBoardCore

/// Position the local wall-clock grid with 90 minutes of preceding context.
/// Calendar components (rather than elapsed seconds since midnight) agree with
/// the displayed hours through time-zone changes and daylight-saving days.
enum CalendarViewport {
    static let defaultRequest = UUID()
    static func currentMinute(now: Date = .now, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func initialOffset(includesToday: Bool, now: Date = .now, calendar: Calendar = .current, hourHeight: CGFloat = 60) -> CGFloat {
        let minutes = includesToday ? currentMinute(now: now, calendar: calendar) - 90 : 8 * 60
        return CGFloat(max(0, minutes)) * hourHeight / 60
    }
}

/// The clip-view observer remembers actual pixel offsets without publishing a
/// planner change on every scroll. Restoration happens only when the period or
/// explicit Now request changes; ordinary data refreshes never move the view.
struct CalendarScrollRestoration: NSViewRepresentable {
    let key: String
    let initialOffset: CGFloat
    let nowRequest: UUID
    let storedOffset: (String) -> CGFloat?
    let rememberOffset: (String, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollObserver { ScrollObserver() }
    func updateNSView(_ view: ScrollObserver, context: Context) {
        view.configure(key: key, initialOffset: initialOffset, nowRequest: nowRequest, storedOffset: storedOffset, rememberOffset: rememberOffset)
    }

    final class ScrollObserver: NSView {
        private weak var scrollView: NSScrollView?
        // NotificationCenter tokens may be removed from nonisolated deinit.
        nonisolated(unsafe) private var observation: NSObjectProtocol?
        private var currentKey: String?
        private var currentRequest: UUID?
        private var pendingKey = ""
        private var initialOffset: CGFloat = 0
        private var pendingRequest = UUID()
        private var storedOffset: ((String) -> CGFloat?)?
        private var rememberOffset: ((String, CGFloat) -> Void)?

        func configure(key: String, initialOffset: CGFloat, nowRequest: UUID, storedOffset: @escaping (String) -> CGFloat?, rememberOffset: @escaping (String, CGFloat) -> Void) {
            pendingKey = key; self.initialOffset = initialOffset; pendingRequest = nowRequest
            self.storedOffset = storedOffset; self.rememberOffset = rememberOffset
            DispatchQueue.main.async { [weak self] in self?.connectAndRestore() }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectAndRestore() }
        override func layout() { super.layout(); connectAndRestore() }

        private func connectAndRestore() {
            guard !pendingKey.isEmpty, let enclosing = enclosingScrollView, let document = enclosing.documentView,
                  document.frame.height > enclosing.contentView.bounds.height else { return }
            if scrollView !== enclosing {
                if let observation { NotificationCenter.default.removeObserver(observation) }
                scrollView = enclosing
                enclosing.contentView.postsBoundsChangedNotifications = true
                observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: enclosing.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let key = self.currentKey, let clip = self.scrollView?.contentView else { return }
                        self.rememberOffset?(key, max(0, clip.bounds.origin.y))
                    }
                }
            }
            guard currentKey != pendingKey || currentRequest != pendingRequest else { return }
            let explicitNow = currentRequest != nil && currentRequest != pendingRequest
            let offset = explicitNow ? initialOffset : storedOffset?(pendingKey) ?? initialOffset
            currentKey = pendingKey; currentRequest = pendingRequest
            let maximum = max(0, document.frame.height - enclosing.contentView.bounds.height)
            enclosing.contentView.scroll(to: NSPoint(x: enclosing.contentView.bounds.origin.x, y: min(maximum, max(0, offset))))
            enclosing.reflectScrolledClipView(enclosing.contentView)
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
