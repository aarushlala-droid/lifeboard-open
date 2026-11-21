import Foundation

public struct TopicImportDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var originalLine: String
    public var isIncluded: Bool
    public var reviewReason: String?
    public var isDuplicate: Bool
    public init(id: UUID = UUID(), title: String, originalLine: String, isIncluded: Bool = true, reviewReason: String? = nil, isDuplicate: Bool = false) {
        self.id = id; self.title = title; self.originalLine = originalLine; self.isIncluded = isIncluded; self.reviewReason = reviewReason; self.isDuplicate = isDuplicate
    }
}
public enum TopicImportError: LocalizedError {
    case tooLarge, tooManyLines
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Paste up to 1 MB of topic text at a time. Split a longer specification into sections."
        case .tooManyLines: "Import up to 10,000 topic lines at a time. Split this specification into sections."
        }
    }
}
/// Deterministic, on-device extraction. Each accepted topic retains its original source line.
public enum TopicImportParser {
    public static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func parse(_ text: String, existing: [String] = []) throws -> [TopicImportDraft] {
        guard text.utf8.count <= 1_048_576 else { throw TopicImportError.tooLarge }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= 10_000 else { throw TopicImportError.tooManyLines }
        var seen = Set(existing.map(normalizedTitle))
        var output: [TopicImportDraft] = []
        for source in lines {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Keep section headings in the unchanged source preview rather than inventing topics.
            if trimmed.hasPrefix("#") || trimmed.hasSuffix(":") || ["topics", "specification", "syllabus", "learning objectives"].contains(normalizedTitle(trimmed)) { continue }
            let title = trimmed
                .replacingOccurrences(of: #"^\s*(?:[•◦▪︎☐□*–—-]\s+|\d+(?:\.\d+)*(?:[.)]|\s)\s*)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let normalized = normalizedTitle(title)
            let duplicate = !seen.insert(normalized).inserted
            let reason: String? = title.count > 2_000 ? "This line is too long for a topic. Shorten its title; the original remains in notes." : title.count > 300 ? "This looks like a paragraph. Check or shorten the topic title before including it." : nil
            output.append(.init(title: title, originalLine: source, isIncluded: !duplicate && reason == nil, reviewReason: reason, isDuplicate: duplicate))
        }
        return output
    }
    /// Model proposals are allowed only when they are literal source substrings.
    public static func grounded(_ titles: [String], in source: String, existing: [String] = []) -> [TopicImportDraft] {
        var seen = Set(existing.map(normalizedTitle))
        return titles.compactMap { proposed in
            let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 2_000, source.range(of: title, options: .caseInsensitive) != nil else { return nil }
            let original = source.components(separatedBy: .newlines).first { $0.range(of: title, options: .caseInsensitive) != nil } ?? title
            let duplicate = !seen.insert(normalizedTitle(title)).inserted
            return TopicImportDraft(title: title, originalLine: original, isIncluded: !duplicate, isDuplicate: duplicate)
        }
    }
    /// Recheck edited proposals against the current subject at the moment of acceptance.
    public static func accepted(_ drafts: [TopicImportDraft], existing: [String]) -> [TopicImportDraft] {
        var seen = Set(existing.map(normalizedTitle))
        return drafts.filter { $0.isIncluded }.compactMap { draft in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 2_000, draft.originalLine.count <= 200_000, seen.insert(normalizedTitle(title)).inserted else { return nil }
            var accepted = draft; accepted.title = title; accepted.isDuplicate = false
            return accepted
        }
    }
}
