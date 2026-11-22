import AppKit
import SwiftUI
import LifeBoardCore

/// LifeBoard's visual tokens. Everything uses the system palette, so the app
/// follows your accent colour, light and dark appearance and Increase
/// Contrast. Each colour means one thing: accent for actions, selection and
/// your To Dos; orange for the present moment; red for overdue and destructive.
enum LB {
    static func dynamic(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            switch best {
            case .darkAqua?: return NSColor(hex: dark)
            case .accessibilityHighContrastDarkAqua?: return NSColor(hex: darkHigh ?? dark)
            case .accessibilityHighContrastAqua?: return NSColor(hex: lightHigh ?? light)
            default: return NSColor(hex: light)
            }
        })
    }

    /// Actions, selection and your own To Dos: the accent chosen in System Settings.
    static let accent = Color.accentColor
    /// The present moment (now line, Now/Next, running Focus). Lines and dots
    /// use system orange; text uses `lampText`, which keeps 4.5:1 or better.
    static let lamp = Color(nsColor: .systemOrange)
    static let lampText = dynamic(light: 0xB35300, dark: 0xFFB340, lightHigh: 0x8A3F00, darkHigh: 0xFFC870)
    static let lampGlow = Color(nsColor: .systemOrange)
    /// Overdue work and destructive actions: Apple's accessible red (5.4:1 on white).
    static let signal = dynamic(light: 0xD70015, dark: 0xFF6961, lightHigh: 0xA5000F, darkHigh: 0xFF8E87)
    /// Events you created in LifeBoard.
    static let event = Color(nsColor: .systemPurple)
    /// Connected calendars when their own colour is unavailable.
    static let connected = Color(nsColor: .systemGray)
    /// Important dates and milestones.
    static let marker = Color(nsColor: .systemPink)

    static let rowCorner: CGFloat = 7
    static let blockCorner: CGFloat = 6
    static let hourHeight: CGFloat = 56

    static func subjectColour(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": .red; case "orange": .orange; case "yellow": .yellow; case "green": .green; case "mint": .mint
        case "teal": .teal; case "cyan": .cyan; case "indigo": .indigo; case "purple": .purple; case "pink": .pink; case "brown": .brown
        default: accent
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Motion is short, answers an action, and becomes a cross-fade or nothing
/// when Reduce Motion is on.
enum Motion {
    static func quick(_ reduce: Bool) -> Animation? { reduce ? nil : .snappy(duration: 0.18) }
    static func move(_ reduce: Bool) -> Animation? { reduce ? .easeOut(duration: 0.12) : .snappy(duration: 0.24) }
}

func withMotion(_ animation: Animation?, _ body: () -> Void) {
    if let animation { withAnimation(animation, body) } else { body() }
}

struct ScreenTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The lamp: a small warm point of light with a soft halo.
struct LampDot: View {
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(LB.lamp).frame(width: size, height: size)
            .background(Circle().fill(LB.lampGlow.opacity(0.25)).frame(width: size * 2.2, height: size * 2.2).blur(radius: 2))
            .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    let title: String
    var count: Int? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

func durationText(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60, remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

func relativeDayText(_ day: LocalDay, today: LocalDay = .today) -> String {
    if day == today { return "Today" }
    if day == today.adding(days: 1) { return "Tomorrow" }
    if day == today.adding(days: -1) { return "Yesterday" }
    let delta = Calendar.current.dateComponents([.day], from: today.date(), to: day.date()).day ?? 0
    if (2...6).contains(delta) { return day.date().formatted(.dateTime.weekday(.wide)) }
    return day.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

func timeString(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
