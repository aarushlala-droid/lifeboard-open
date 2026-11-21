import Foundation

public struct SyncMergeResult: Sendable {
    public let data: LifeBoardData?
    public let conflicts: [String]
}

/// Record and field merges. A conflict never silently selects a writer.
public enum LifeBoardSyncMerge {
    static let recordCollections = ["tasks", "events", "subjects", "projects", "yearMarkers", "activity", "focusSessions", "externalEvents"]
    static let bookkeeping = Set(["modifiedAt", "lastICloudBackup", "lastExternalCalendarRefresh", "lastActivity"])

    public static func merge(base: LifeBoardData, local: LifeBoardData, remote: LifeBoardData) throws -> SyncMergeResult {
        guard [base.schemaVersion, local.schemaVersion, remote.schemaVersion].allSatisfy({ $0 == 3 }) else { return SyncMergeResult(data: nil, conflicts: ["newer schema"]) }
        var conflicts: [String] = []
        var baseline = try dictionary(base), ours = try dictionary(local), theirs = try dictionary(remote)
        if let original = baseline["activeFocus"] as? [String: Any], let id = original["id"] as? String {
            let records = (ours["focusSessions"] as? [[String: Any]] ?? []) + (theirs["focusSessions"] as? [[String: Any]] ?? [])
            if records.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) {
                baseline.removeValue(forKey: "activeFocus")
                if (ours["activeFocus"] as? [String: Any])?["id"] as? String == id { ours.removeValue(forKey: "activeFocus") }
                if (theirs["activeFocus"] as? [String: Any])?["id"] as? String == id { theirs.removeValue(forKey: "activeFocus") }
            }
        }
        let result = mergeValue(base: baseline, local: ours, remote: theirs, path: [], conflicts: &conflicts)
        guard conflicts.isEmpty, var output = result as? [String: Any] else { return SyncMergeResult(data: nil, conflicts: conflicts.sorted()) }
        output["schemaVersion"] = 3
        // A finalised session cannot be resurrected by a stale pause/resume.
        if let active = output["activeFocus"] as? [String: Any], let id = active["id"] as? String,
           (output["focusSessions"] as? [[String: Any]])?.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) == true { output.removeValue(forKey: "activeFocus") }
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let decoder = LifeBoardJSON.decoder()
        return SyncMergeResult(data: try decoder.decode(LifeBoardData.self, from: bytes), conflicts: [])
    }

    static func mergeValue(base: Any?, local: Any?, remote: Any?, path: [String], conflicts: inout [String]) -> Any? {
        if equal(local, remote) { return local }
        if equal(local, base) { return remote }
        if equal(remote, base) { return local }
        if let key = path.last, bookkeeping.contains(key) {
            // ISO timestamps sort chronologically. Metadata is not user intent.
            return [local as? String, remote as? String].compactMap { $0 }.max() ?? local ?? remote
        }
        if let ours = local as? [String: Any], let theirs = remote as? [String: Any], let baseline = base as? [String: Any] {
            var result: [String: Any] = [:]
            for key in Set(baseline.keys).union(ours.keys).union(theirs.keys) {
                result[key] = mergeValue(base: baseline[key], local: ours[key], remote: theirs[key], path: path + [key], conflicts: &conflicts)
            }
            return result
        }
        if let ours = local as? [[String: Any]], let theirs = remote as? [[String: Any]], let baseline = base as? [[String: Any]],
           (ours + theirs + baseline).allSatisfy({ $0["id"] is String }) {
            let b = records(baseline), l = records(ours), r = records(theirs)
            var merged: [String: Any] = [:]
            for id in Set(b.keys).union(l.keys).union(r.keys) {
                if path == ["focusSessions"], b[id] == nil, let left = l[id] as? [String: Any], let right = r[id] as? [String: Any], equal(left["startedAt"], right["startedAt"]) {
                    // Both devices can finalise the same stable session. Completed
                    // timers have canonical time/seconds; a stop loses to completion.
                    if (left["completedTimer"] as? Bool) == true && (right["completedTimer"] as? Bool) == false { merged[id] = left; continue }
                    if (right["completedTimer"] as? Bool) == true && (left["completedTimer"] as? Bool) == false { merged[id] = right; continue }
                    if (left["completedTimer"] as? Bool) == true && (right["completedTimer"] as? Bool) == true {
                        let l = (try? JSONSerialization.data(withJSONObject: left, options: .sortedKeys)) ?? Data()
                        let r = (try? JSONSerialization.data(withJSONObject: right, options: .sortedKeys)) ?? Data()
                        merged[id] = l.lexicographicallyPrecedes(r) ? left : right; continue
                    }
                    if (left["completedTimer"] as? Bool) == false && (right["completedTimer"] as? Bool) == false {
                        merged[id] = (left["endedAt"] as? String ?? "") <= (right["endedAt"] as? String ?? "") ? left : right; continue
                    }
                }
                merged[id] = mergeValue(base: b[id], local: l[id], remote: r[id], path: path + [id], conflicts: &conflicts)
            }
            let order = (theirs + ours).compactMap { ($0["id"] as? String)?.lowercased() }
            var seen: Set<String> = []
            return order.filter { seen.insert($0).inserted }.compactMap { merged[$0] }
        }
        conflicts.append(path.joined(separator: "/"))
        return remote
    }

    static func dictionary(_ data: LifeBoardData) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(data)) as? [String: Any] ?? [:]
    }
    static func records(_ value: Any?) -> [String: Any] {
        var result: [String: Any] = [:]
        for item in value as? [[String: Any]] ?? [] { if let id = item["id"] as? String { result[id.lowercased()] = item } }
        return result
    }
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (nil, _), (_, nil): false
        default: NSDictionary(dictionary: ["value": lhs!]).isEqual(to: ["value": rhs!])
        }
    }
}

/// Stores changed fields/records only. Undo checks the value it originally wrote
/// and preserves unrelated fields, newly synced records and independent settings.
public struct LifeBoardDataPatch {
    private struct Operation { let path: [String]; let before: Any?; let after: Any? }
    private let operations: [Operation]
    public var isEmpty: Bool { operations.isEmpty }
    public var paths: [String] { operations.map { $0.path.joined(separator: "/") } }

    public init(before: LifeBoardData, after: LifeBoardData) throws {
        var list: [Operation] = []
        Self.diff(try LifeBoardSyncMerge.dictionary(before), try LifeBoardSyncMerge.dictionary(after), path: [], list: &list)
        operations = list
    }
    private init(operations: [Operation]) { self.operations = operations }
    public func reversed() -> LifeBoardDataPatch { LifeBoardDataPatch(operations: operations.map { Operation(path: $0.path, before: $0.after, after: $0.before) }) }

    public func applying(to data: LifeBoardData) throws -> LifeBoardData {
        var root: Any = try LifeBoardSyncMerge.dictionary(data)
        var conflicts: [String] = []
        for operation in operations {
            let current = Self.value(root, at: operation.path)
            if LifeBoardSyncMerge.equal(current, operation.after) { continue }
            guard LifeBoardSyncMerge.equal(current, operation.before) else { conflicts.append(operation.path.joined(separator: "/")); continue }
            root = Self.setting(root, path: operation.path, value: operation.after)
        }
        guard conflicts.isEmpty else { throw LifeBoardError.concurrentChange(conflicts) }
        let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try LifeBoardValidation.decode(bytes)
    }

    /// Copy explicitly reviewed conflict paths, retaining every other field.
    public static func copying(paths: [String], from source: LifeBoardData, to target: LifeBoardData) throws -> LifeBoardData {
        let sourceRoot: Any = try LifeBoardSyncMerge.dictionary(source)
        var root: Any = try LifeBoardSyncMerge.dictionary(target)
        for raw in paths {
            let path = raw.split(separator: "/").map(String.init)
            root = setting(root, path: path, value: value(sourceRoot, at: path))
        }
        let decoder = LifeBoardJSON.decoder()
        return try decoder.decode(LifeBoardData.self, from: JSONSerialization.data(withJSONObject: root))
    }
    public static func displayValue(path: String, in data: LifeBoardData) -> String {
        guard let root = try? LifeBoardSyncMerge.dictionary(data), let item = value(root, at: path.split(separator: "/").map(String.init)) else { return "Removed" }
        if let text = item as? String { return text }
        if let bytes = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) { return String(decoding: bytes, as: UTF8.self) }
        return String(describing: item)
    }
    private static func diff(_ before: Any?, _ after: Any?, path: [String], list: inout [Operation]) {
        guard !LifeBoardSyncMerge.equal(before, after) else { return }
        if let key = path.last, LifeBoardSyncMerge.bookkeeping.contains(key) { return }
        if let b = before as? [String: Any], let a = after as? [String: Any] {
            for key in Set(b.keys).union(a.keys).sorted() { diff(b[key], a[key], path: path + [key], list: &list) }
        } else if let b = before as? [[String: Any]], let a = after as? [[String: Any]], (b + a).allSatisfy({ $0["id"] is String }) {
            let baseline = LifeBoardSyncMerge.records(b), changed = LifeBoardSyncMerge.records(a)
            for id in Set(baseline.keys).union(changed.keys).sorted() { diff(baseline[id], changed[id], path: path + [id], list: &list) }
        } else { list.append(Operation(path: path, before: before, after: after)) }
    }
    private static func value(_ node: Any, at path: [String]) -> Any? {
        guard let first = path.first else { return node }
        let child: Any?
        if let dictionary = node as? [String: Any] { child = dictionary[first] }
        else if let records = node as? [[String: Any]] { child = records.first { ($0["id"] as? String)?.lowercased() == first.lowercased() } }
        else { return nil }
        return child.flatMap { value($0, at: Array(path.dropFirst())) }
    }
    private static func setting(_ node: Any, path: [String], value: Any?) -> Any {
        guard let first = path.first else { return value ?? NSNull() }
        if var dictionary = node as? [String: Any] {
            if path.count == 1 { dictionary[first] = value }
            else { dictionary[first] = setting(dictionary[first] ?? [:], path: Array(path.dropFirst()), value: value) }
            return dictionary
        }
        if var records = node as? [[String: Any]] {
            if let index = records.firstIndex(where: { ($0["id"] as? String)?.lowercased() == first.lowercased() }) {
                if path.count == 1 { if let record = value as? [String: Any] { records[index] = record } else { records.remove(at: index) } }
                else { records[index] = setting(records[index], path: Array(path.dropFirst()), value: value) as? [String: Any] ?? records[index] }
            } else if path.count == 1, let record = value as? [String: Any] { records.append(record) }
            return records
        }
        return node
    }
}
