import Foundation
import Darwin

/// One place for every identity a build touches on disk, in Keychain, in
/// LaunchServices and in WidgetKit. The Preview build is compiled with
/// `-D LIFEBOARD_PREVIEW`, so the app, widget and bundled helper agree at
/// compile time and can never fall back to the installed app's data.
public enum LifeBoardEnvironment {
    #if LIFEBOARD_PREVIEW
    public static let isPreview = true
    public static let productName = "LifeBoard Preview"
    public static let supportFolderName = "LifeBoard Preview"
    public static let urlScheme = "lifeboard-preview"
    public static let keychainService = "app.lifeboard.preview.sync"
    public static let appGroupIdentifier = "group.app.lifeboard.preview"
    public static let widgetKind = "LifeBoardPreviewAgendaWidget"
    public static let calendarItemTypeIdentifier = "app.lifeboard.preview.calendar-item"
    #else
    public static let isPreview = false
    public static let productName = "LifeBoard"
    public static let supportFolderName = "LifeBoard"
    public static let urlScheme = "lifeboard"
    public static let keychainService = "app.lifeboard.mac.sync"
    public static let appGroupIdentifier = "group.app.lifeboard.mac"
    public static let widgetKind = "LifeBoardAgendaWidget"
    public static let calendarItemTypeIdentifier = "app.lifeboard.calendar-item"
    #endif

    /// The Preview never talks to the mobile sync service. It has no endpoint
    /// file of its own and this switch keeps it off even if one is copied in.
    public static var networkSyncAllowed: Bool { !isPreview }

    /// The real home folder. A sandboxed widget's Foundation home resolves to
    /// its container, so read the password database instead.
    public static var userHome: URL {
        let path = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static var dataPathOverride: URL? {
        ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"].map { URL(fileURLWithPath: $0) }
    }

    public static var supportDirectory: URL {
        if let override = dataPathOverride { return override.deletingLastPathComponent() }
        return userHome.appendingPathComponent("Library/Application Support/\(supportFolderName)", isDirectory: true)
    }

    public static var dataFileURL: URL { dataPathOverride ?? supportDirectory.appendingPathComponent("LifeBoard.json") }

    /// The installed app backs up into iCloud Drive. The Preview keeps its
    /// automatic backups on this Mac so it never writes to a synced folder.
    public static var automaticBackupDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LIFEBOARD_ICLOUD_BACKUP_PATH"] { return URL(fileURLWithPath: path, isDirectory: true) }
        if isPreview { return supportDirectory.appendingPathComponent("Automatic Backups", isDirectory: true) }
        return userHome.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LifeBoard Backups", isDirectory: true)
    }

    public static func url(_ path: String) -> URL { URL(string: "\(urlScheme)://\(path)")! }
}
