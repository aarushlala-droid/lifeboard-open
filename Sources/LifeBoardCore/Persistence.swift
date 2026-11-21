import Foundation
import Darwin

public enum LifeBoardError: LocalizedError {
    case invalidPayload, itemNotFound, saveFailed
    case unsupportedSchema(Int), concurrentChange([String])
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "LifeBoard couldn't import that task. Check the title and dates, then try again."
        case .itemNotFound: "LifeBoard couldn't find that item."
        case .saveFailed: "LifeBoard couldn't save that change. Your previous data is still available."
        case .unsupportedSchema(let version): "This workspace uses LifeBoard schema \(version). Upgrade LifeBoard to open it. The original file has not been changed."
        case .concurrentChange(let paths): "Newer changes need review: " + paths.prefix(6).joined(separator: ", ")
        }
    }
}

public final class LifeBoardRepository: @unchecked Sendable {
    public let fileURL: URL
    public let backupDirectory: URL
    public let iCloudBackupDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let mutex = NSRecursiveLock()
    private var loadedBaseline: LifeBoardData?
    private var loadedBytes: Data?
    private var loaded = false

    public init(fileURL: URL? = nil, iCloudBackupDirectory: URL? = nil) {
        let manager = FileManager.default
        let base = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LifeBoard", isDirectory: true)
        let environmentFile = ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"].map { URL(fileURLWithPath: $0) }
        self.fileURL = fileURL ?? environmentFile ?? base.appendingPathComponent("LifeBoard.json")
        self.backupDirectory = (fileURL != nil || environmentFile != nil ? self.fileURL.deletingLastPathComponent() : base).appendingPathComponent("Backups", isDirectory: true)
        let environmentICloud = ProcessInfo.processInfo.environment["LIFEBOARD_ICLOUD_BACKUP_PATH"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.iCloudBackupDirectory = iCloudBackupDirectory ?? environmentICloud ?? manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LifeBoard Backups", isDirectory: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    /// Prefer loadThrowing for editable workspaces. This compatibility method
    /// returns an empty, never seeded, recovery view when decoding fails.
    public func load() -> LifeBoardData { (try? loadThrowing()) ?? LifeBoardData() }

    public func loadThrowing() throws -> LifeBoardData {
        try withLock {
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            if !exists && loadedBytes != nil { throw LifeBoardError.itemNotFound }
            let bytes = exists ? try Data(contentsOf: fileURL) : nil
            let value = try bytes.map(LifeBoardValidation.decode) ?? .seeded()
            loadedBaseline = value; loadedBytes = bytes; loaded = true
            if exists { try LifeBoardPrivateFiles.protect(fileURL) }
            return value
        }
    }

    public func save(_ data: LifeBoardData) throws { _ = try saveReturning(data) }

    /// A locked compare-and-swap, merging independent changes against the last
    /// successful load. Corrupt/newer files always fail before atomic replacement.
    @discardableResult public func saveReturning(_ proposed: LifeBoardData) throws -> LifeBoardData {
        try withLock {
            try LifeBoardValidation.validate(proposed)
            let currentBytes = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
            let current = try currentBytes.map(LifeBoardValidation.decode)
            var value = proposed
            if currentBytes != loadedBytes {
                guard loaded, let base = loadedBaseline, let current else { throw LifeBoardError.concurrentChange(["workspace changed or disappeared; reload and retry"]) }
                let result = try LifeBoardSyncMerge.merge(base: base, local: proposed, remote: current)
                guard let merged = result.data else { throw LifeBoardError.concurrentChange(result.conflicts) }
                value = merged
            } else if !loaded, current != nil {
                throw LifeBoardError.concurrentChange(["load workspace before editing"])
            }
            try LifeBoardValidation.validate(value)
            let bytes = try encoder.encode(value)
            guard bytes.count <= LifeBoardValidation.maximumDocumentBytes else { throw LifeBoardError.invalidPayload }
            if bytes != currentBytes { try LifeBoardPrivateFiles.write(bytes, to: fileURL) }
            loadedBaseline = value; loadedBytes = bytes; loaded = true
            return value
        }
    }

    /// Explicit user-requested recovery is the only path that replaces corrupt
    /// source bytes. Preserve those bytes first, under the same repository lock.
    @discardableResult public func replaceFromBackup(from url: URL) throws -> LifeBoardData {
        let imported = try importBackup(from: url)
        return try withLock {
            let encoded = try encoder.encode(imported)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let original = try Data(contentsOf: fileURL)
                try LifeBoardPrivateFiles.directory(backupDirectory)
                let previous = backupDirectory.appendingPathComponent("LifeBoard-before-restore-\(UUID().uuidString).json")
                try LifeBoardPrivateFiles.write(original, to: previous)
                guard try Data(contentsOf: previous) == original else { throw LifeBoardError.saveFailed }
            }
            try LifeBoardPrivateFiles.write(encoded, to: fileURL)
            loadedBaseline = imported; loadedBytes = encoded; loaded = true
            return imported
        }
    }

    /// A verified durable source for backup. It deliberately ignores stale UI data.
    public func durableSnapshot() throws -> LifeBoardData {
        try withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw LifeBoardError.itemNotFound }
            return try LifeBoardValidation.decode(Data(contentsOf: fileURL))
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try LifeBoardPrivateFiles.directory(fileURL.deletingLastPathComponent())
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw LifeBoardError.saveFailed }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0, flock(descriptor, LOCK_EX) == 0 else { throw LifeBoardError.saveFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    @discardableResult public func export(_ data: LifeBoardData, to url: URL? = nil) throws -> URL {
        try LifeBoardPrivateFiles.directory(backupDirectory)
        try LifeBoardValidation.validate(data)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = url ?? backupDirectory.appendingPathComponent("LifeBoard-\(formatter.string(from: .now)).json")
        try LifeBoardPrivateFiles.write(encoder.encode(data), to: destination)
        return destination
    }

    @discardableResult public func exportOriginal(to url: URL? = nil) throws -> URL {
        try withLock {
            let bytes = try Data(contentsOf: fileURL)
            let destination = url ?? backupDirectory.appendingPathComponent("LifeBoard-original-\(UUID().uuidString).json")
            guard destination.standardizedFileURL != fileURL.standardizedFileURL else { throw LifeBoardError.invalidPayload }
            try LifeBoardPrivateFiles.write(bytes, to: destination)
            return destination
        }
    }

    public func importBackup(from url: URL) throws -> LifeBoardData {
        try LifeBoardValidation.decode(Data(contentsOf: url))
    }

    @discardableResult public func exportToICloud(_ data: LifeBoardData, retain: Int = 10) throws -> URL {
        let manager = FileManager.default
        try LifeBoardValidation.validate(data)
        try LifeBoardPrivateFiles.directory(iCloudBackupDirectory)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = iCloudBackupDirectory.appendingPathComponent("LifeBoard-Auto-\(formatter.string(from: .now)).json")
        try LifeBoardPrivateFiles.write(encoder.encode(data), to: destination)
        let files = (try manager.contentsOfDirectory(at: iCloudBackupDirectory, includingPropertiesForKeys: [.contentModificationDateKey]))
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix("LifeBoard-Auto-") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for old in files.dropFirst(max(2, retain)) { try? manager.removeItem(at: old) }
        return destination
    }

    public func decodePayload(_ json: String) throws -> TaskImportPayload {
        guard let data = json.data(using: .utf8), data.count <= 1_048_576, let payload = try? decoder.decode(TaskImportPayload.self, from: data), !payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LifeBoardError.invalidPayload }
        return payload
    }

    public func decodePayloads(_ json: String) throws -> [TaskImportPayload] {
        guard let bytes = json.data(using: .utf8), bytes.count <= 1_048_576 else { throw LifeBoardError.invalidPayload }
        if let batch = try? decoder.decode([TaskImportPayload].self, from: bytes), !batch.isEmpty, batch.count <= 1000,
           batch.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return batch
        }
        return [try decodePayload(json)]
    }

    public func makeTask(from payload: TaskImportPayload, in data: LifeBoardData) throws -> TaskItem {
        var task = TaskItem(title: payload.title.trimmingCharacters(in: .whitespacesAndNewlines))
        task.notes = payload.notes ?? ""
        task.estimatedMinutes = payload.estimatedMinutes ?? data.settings.defaultTaskMinutes
        guard (1...1440).contains(task.estimatedMinutes), task.title.count <= 2000, task.notes.count <= 200000 else { throw LifeBoardError.invalidPayload }
        if let raw = payload.dueDate { guard let day = LocalDay(iso: raw) else { throw LifeBoardError.invalidPayload }; task.dueDay = day }
        if let raw = payload.scheduledDate { guard let day = LocalDay(iso: raw) else { throw LifeBoardError.invalidPayload }; task.scheduledDay = day }
        if let raw = payload.scheduledStart {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { throw LifeBoardError.invalidPayload }
            task.scheduledStartMinutes = parts[0] * 60 + parts[1]
        }
        guard let priority = TaskPriority(rawValue: payload.priority ?? "none") else { throw LifeBoardError.invalidPayload }; task.priority = priority
        if task.scheduledStartMinutes != nil && task.scheduledDay == nil { throw LifeBoardError.invalidPayload }
        task.subjectID = data.subjects.first { $0.title.localizedCaseInsensitiveCompare(payload.subject ?? "") == .orderedSame }?.id
        task.projectID = data.projects.first { $0.title.localizedCaseInsensitiveCompare(payload.project ?? "") == .orderedSame }?.id
        if let topic = payload.topic, let subjectID = task.subjectID { task.topicID = data.subjects.first(where: { $0.id == subjectID })?.topics.first(where: { $0.title.localizedCaseInsensitiveCompare(topic) == .orderedSame })?.id }
        if let subject = payload.subject, task.subjectID == nil, !subject.isEmpty { throw DocumentValidationError(["subject not found"]) }
        if let project = payload.project, task.projectID == nil, !project.isEmpty { throw DocumentValidationError(["project not found"]) }
        if let topic = payload.topic, task.topicID == nil, !topic.isEmpty { throw DocumentValidationError(["topic not found in selected subject"]) }
        return task
    }
}

/// Atomic owner-only files. User-selected exports are readable JSON, not encryption.
public enum LifeBoardPrivateFiles {
    public static func directory(_ url: URL, enforceExistingMode: Bool = true) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Never change permissions of a caller's home/root/shared temporary root.
        let protectedRoots = ["/", "/tmp", "/private/tmp", manager.homeDirectoryForCurrentUser.path, manager.temporaryDirectory.standardizedFileURL.path]
        if enforceExistingMode && !protectedRoots.contains(url.standardizedFileURL.path) { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    public static func protect(_ url: URL) throws { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    public static func write(_ bytes: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent(), enforceExistingMode: false)
        // Set the temporary file mode before publishing, avoiding a readable gap.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".LifeBoard-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw LifeBoardError.saveFailed }
        var failure = false
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { failure = true; break }
                offset += count
            }
        }
        if fsync(fd) != 0 { failure = true }; close(fd)
        guard !failure, rename(temporary.path, url.path) == 0 else { throw LifeBoardError.saveFailed }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
}
