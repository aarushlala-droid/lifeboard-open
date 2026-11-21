import AppKit
import Foundation
import LifeBoardCore
@preconcurrency import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

struct CaptureInterpretation: Sendable {
    var drafts: [CapturedTaskDraft]
    var usedAppleIntelligence: Bool
    var note: String
}

#if canImport(FoundationModels)
private struct GeneratedCaptureBatch: Decodable {
    var items: [GeneratedCaptureItem]
}

private struct GeneratedCaptureItem: Decodable {
    var title: String
    var estimatedMinutes: Int?
    var date: String?
    var time: String?
    var subject: String?
    var project: String?
    var priority: String
    var kind: String?
    var notes: String?
}
#endif

private struct RecognizedLine: Sendable {
    var text: String
    var confidence: Float
    var box: CGRect
}

enum CaptureIntelligence {
    static func availabilityDescription() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple Intelligence is ready on this Mac"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off; fast local parsing will be used"
            case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence; fast local parsing will be used"
            case .unavailable(.modelNotReady): return "Apple Intelligence is still preparing; fast local parsing will be used"
            case .unavailable: return "Apple Intelligence is unavailable; fast local parsing will be used"
            }
        }
        #endif
        return "Fast local parsing is available"
    }

    static func interpret(text: String, data: LifeBoardData, referenceDay: LocalDay = .today) async -> CaptureInterpretation {
        let fallback = NaturalLanguageTaskParser.parse(text, referenceDay: referenceDay, data: data)
        guard !fallback.isEmpty else { return CaptureInterpretation(drafts: [], usedAppleIntelligence: false, note: "Nothing to add yet") }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable, fallback.contains(where: \.needsReview) {
            do {
                let session = LanguageModelSession(instructions: "Extract planner tasks only. Never invent tasks, dates, exact times, subjects, or projects. Keep titles concise and actionable.")
                let subjectNames = data.subjects.filter { !$0.archived }.map(\.title).joined(separator: ", ")
                let projectNames = data.projects.filter { $0.status != .archived }.map(\.title).joined(separator: ", ")
                let prompt = """
                Today is \(referenceDay.id). Interpret every distinct task in the input below.
                Resolve relative dates against today. Leave date nil when none is implied.
                Only set a time when the input states an exact time. "Tonight" is today without an exact time.
                Available subjects: \(subjectNames).
                Available projects: \(projectNames).
                Return only valid JSON with this exact shape and no markdown:
                {"items":[{"title":"Concise actionable title","estimatedMinutes":30,"date":"YYYY-MM-DD or null","time":"HH:mm or null","subject":"exact supplied name or null","project":"exact supplied name or null","priority":"none|low|medium|high"}]}
                Input:
                \(text)
                """
                let content = try await boundedModelResponse(session: session, prompt: prompt)
                try Task.checkCancellation()
                let generated = try decodeBatch(from: content)
                let drafts = generated.items.compactMap { item -> CapturedTaskDraft? in
                    let clean = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return nil }
                    let day = item.date.flatMap(LocalDay.init(iso:))
                    let start = item.time.flatMap(parseTime)
                    let subjectID = data.subjects.first { $0.title.localizedCaseInsensitiveCompare(item.subject ?? "") == .orderedSame }?.id
                    let projectID = data.projects.first { $0.title.localizedCaseInsensitiveCompare(item.project ?? "") == .orderedSame }?.id
                    return CapturedTaskDraft(title: clean, estimatedMinutes: min(480, max(5, item.estimatedMinutes ?? data.settings.defaultTaskMinutes)), targetDay: day, startMinutes: start, priority: TaskPriority(rawValue: item.priority.lowercased()) ?? .none, subjectID: subjectID, projectID: projectID, kind: item.kind?.lowercased() == "event" ? .event : .task, notes: item.notes ?? "")
                }
                if drafts.count == fallback.count {
                    // Shared parser remains authoritative for dates, times, priorities and association.
                    // The model may improve unclear titles but cannot silently invent scheduling metadata.
                    let reviewed = zip(fallback, drafts).map { original, generated in
                        var result = original
                        if original.needsReview { result.notes = [original.notes, "Suggested title: " + generated.title].filter { !$0.isEmpty }.joined(separator: "\n") }
                        return result
                    }
                    return CaptureInterpretation(drafts: reviewed, usedAppleIntelligence: true, note: "Apple Intelligence suggested wording for review; original capture metadata is preserved")
                }
            } catch {
                return CaptureInterpretation(drafts: fallback, usedAppleIntelligence: false, note: "Apple Intelligence could not finish, so LifeBoard used its fast local parser")
            }
        }
        #endif
        return CaptureInterpretation(drafts: fallback, usedAppleIntelligence: false, note: "Interpreted with LifeBoard's fast local parser")
    }

    static func recognizeText(in image: NSImage) async throws -> String {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { throw CaptureError.unreadableImage }
        return try await recognizeLines(in: cgImage).map(\.text).joined(separator: "\n")
    }

    static func recognizeText(at url: URL) async throws -> String {
        guard let image = NSImage(contentsOf: url) else { throw CaptureError.unreadableImage }
        return try await recognizeText(in: image)
    }

    static func interpretImage(in image: NSImage, data: LifeBoardData, referenceDay: LocalDay = .today) async throws -> CaptureInterpretation {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { throw CaptureError.unreadableImage }
        return try await interpretImage(cgImage, data: data, referenceDay: referenceDay)
    }

    static func interpretImage(at url: URL, data: LifeBoardData, referenceDay: LocalDay = .today) async throws -> CaptureInterpretation {
        guard let image = NSImage(contentsOf: url) else { throw CaptureError.unreadableImage }
        return try await interpretImage(in: image, data: data, referenceDay: referenceDay)
    }

    private static func interpretImage(_ image: CGImage, data: LifeBoardData, referenceDay: LocalDay) async throws -> CaptureInterpretation {
        let lines = try await recognizeLines(in: image)
        let drafts = ImageCaptureParser.parse(lines: lines, data: data, referenceDay: referenceDay)
        guard !drafts.isEmpty else { throw CaptureError.noTasksFound }
        return CaptureInterpretation(drafts: drafts, usedAppleIntelligence: false, note: drafts.contains(where: \.needsReview) ? "Image read locally with Vision. Check the items marked for review." : "Image read locally with Vision and arranged into a clean preview.")
    }

    private static func recognizeLines(in image: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let clean = cleanOCR(candidate.string)
                    guard !clean.isEmpty else { return nil }
                    return RecognizedLine(text: clean, confidence: candidate.confidence, box: observation.boundingBox)
                }.sorted { lhs, rhs in
                    if abs(lhs.box.midY - rhs.box.midY) > 0.012 { return lhs.box.midY > rhs.box.midY }
                    return lhs.box.minX < rhs.box.minX
                } ?? []
                guard !lines.isEmpty else { continuation.resume(throwing: CaptureError.noTextFound); return }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-GB", "en-US"]
            request.minimumTextHeight = 0.008
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func cleanOCR(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "|", with: "I")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTime(_ raw: String) -> Int? {
        let pieces = raw.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2, (0..<24).contains(pieces[0]), (0..<60).contains(pieces[1]) else { return nil }
        return pieces[0] * 60 + pieces[1]
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func boundedModelResponse(session: LanguageModelSession, prompt: String) async throws -> String {
        let race = CaptureResponseRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await race.attach(continuation) }
                let model = Task {
                    do { let response = try await session.respond(to: prompt); await race.finish(.success(response.content)) }
                    catch { await race.finish(.failure(error)) }
                }
                Task {
                    do { try await Task.sleep(for: .seconds(12)); model.cancel(); await race.finish(.failure(CaptureError.interpretationTimedOut)) }
                    catch { }
                }
            }
        } onCancel: { Task { await race.finish(.failure(CancellationError())) } }
    }

    private static func decodeBatch(from raw: String) throws -> GeneratedCaptureBatch {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}") else {
            throw CaptureError.invalidModelResponse
        }
        let json = String(cleaned[first...last])
        guard let data = json.data(using: .utf8) else { throw CaptureError.invalidModelResponse }
        return try JSONDecoder().decode(GeneratedCaptureBatch.self, from: data)
    }
    #endif
}

enum CaptureError: LocalizedError {
    case unreadableImage, noTextFound, noTasksFound, invalidModelResponse, interpretationTimedOut
    var errorDescription: String? {
        switch self {
        case .unreadableImage: "LifeBoard couldn't open that image."
        case .noTextFound: "LifeBoard couldn't find readable task text in that image."
        case .noTasksFound: "LifeBoard could read the image, but couldn't confidently find any tasks."
        case .interpretationTimedOut: "Apple Intelligence took too long. The local parser is available."
        case .invalidModelResponse: "Apple Intelligence returned an unreadable task list."
        }
    }
}

private enum ImageCaptureParser {
    private static let timeRange = try! NSRegularExpression(pattern: #"(?i)^\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*[-–—]\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*[-–—:]\s*(.+)$"#)

    static func parse(lines: [RecognizedLine], data: LifeBoardData, referenceDay: LocalDay) -> [CapturedTaskDraft] {
        var drafts: [CapturedTaskDraft] = []
        var currentIndex: Int?
        var inheritedDay: LocalDay?

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if isDateHeading(text) {
                let todayName = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: referenceDay.date()) - 1]
                inheritedDay = text.localizedCaseInsensitiveCompare(todayName) == .orderedSame ? referenceDay : (NaturalLanguageTaskParser.parse(text, referenceDay: referenceDay, data: data).first?.targetDay ?? inheritedDay)
                continue
            }
            if isCrossedOut(text) { continue }
            if let ranged = parseTimeRange(text, day: inheritedDay ?? referenceDay, data: data, confidence: line.confidence) {
                drafts.append(ranged); currentIndex = drafts.count - 1; continue
            }
            if isBullet(text) {
                let clean = stripBullet(text)
                guard clean.count >= 2 else { continue }
                if let index = currentIndex, looksLikeSupportingNote(clean) {
                    drafts[index].notes = [drafts[index].notes, clean].filter { !$0.isEmpty }.joined(separator: "\n")
                } else if let draft = basicDraft(clean, inheritedDay: inheritedDay, confidence: line.confidence, data: data, referenceDay: referenceDay) {
                    drafts.append(draft); currentIndex = nil
                }
                continue
            }
            if let index = currentIndex, looksLikeSupportingNote(text) {
                drafts[index].notes = [drafts[index].notes, text].filter { !$0.isEmpty }.joined(separator: "\n")
            } else if let draft = basicDraft(text, inheritedDay: inheritedDay, confidence: line.confidence, data: data, referenceDay: referenceDay) {
                drafts.append(draft); currentIndex = nil
            }
        }
        return drafts.filter { !$0.title.isEmpty }.prefix(40).map { $0 }
    }

    private static func basicDraft(_ text: String, inheritedDay: LocalDay?, confidence: Float, data: LifeBoardData, referenceDay: LocalDay) -> CapturedTaskDraft? {
        guard !looksLikeNoise(text) else { return nil }
        var draft = NaturalLanguageTaskParser.parse(text, referenceDay: referenceDay, data: data).first ?? CapturedTaskDraft(title: text)
        if draft.targetDay == nil { draft.targetDay = inheritedDay }
        draft.needsReview = draft.needsReview || confidence < 0.55 || text.count > 110
        return draft
    }

    private static func parseTimeRange(_ text: String, day: LocalDay, data: LifeBoardData, confidence: Float) -> CapturedTaskDraft? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = timeRange.firstMatch(in: text, range: range),
              let startHourRange = Range(match.range(at: 1), in: text), let endHourRange = Range(match.range(at: 4), in: text),
              let titleRange = Range(match.range(at: 7), in: text), var startHour = Int(text[startHourRange]), var endHour = Int(text[endHourRange]) else { return nil }
        let startMinute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let endMinute = Range(match.range(at: 5), in: text).flatMap { Int(text[$0]) } ?? 0
        let startSuffix = Range(match.range(at: 3), in: text).map { text[$0].lowercased() }
        let endSuffix = Range(match.range(at: 6), in: text).map { text[$0].lowercased() }
        if startSuffix == "pm", startHour < 12 { startHour += 12 }; if startSuffix == "am", startHour == 12 { startHour = 0 }
        if endSuffix == "pm", endHour < 12 { endHour += 12 }; if endSuffix == "am", endHour == 12 { endHour = 0 }
        if startSuffix == nil, endSuffix == nil, startHour < 8 { startHour += 12 }
        if endHour * 60 + endMinute <= startHour * 60 + startMinute { endHour += 12 }
        guard startHour < 24, endHour < 24 else { return nil }
        let start = startHour * 60 + startMinute
        let duration = max(5, endHour * 60 + endMinute - start)
        let rawTitle = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = NaturalLanguageTaskParser.parse(rawTitle, referenceDay: day, data: data).first ?? CapturedTaskDraft(title: rawTitle)
        draft.targetDay = day; draft.startMinutes = start; draft.estimatedMinutes = duration
        draft.kind = rangedKind(rawTitle); draft.needsReview = confidence < 0.55
        return draft
    }

    private static func rangedKind(_ title: String) -> CapturedItemKind {
        let lower = title.lowercased()
        return ["meeting", "lunch", "dinner", "break", "appointment", "lesson", "class", "exam", "rehearsal"].contains(where: lower.contains) ? .event : .task
    }

    private static func isDateHeading(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return Calendar.current.weekdaySymbols.map { $0.lowercased() }.contains(lower) || lower.range(of: #"^(mon|tue|wed|thu|fri|sat|sun)(day)?\s+\d{1,2}"#, options: .regularExpression) != nil
    }
    private static func isBullet(_ text: String) -> Bool { text.range(of: #"^\s*([•◦▪︎☐□✓✔︎-]|\d+[.)])\s+"#, options: .regularExpression) != nil }
    private static func stripBullet(_ text: String) -> String { text.replacingOccurrences(of: #"^\s*([•◦▪︎☐□✓✔︎-]|\d+[.)])\s+"#, with: "", options: .regularExpression) }
    private static func isCrossedOut(_ text: String) -> Bool { text.contains("~~") || text.hasPrefix("✓") || text.hasPrefix("✔") }
    private static func looksLikeSupportingNote(_ text: String) -> Bool { text.count > 55 || text.hasSuffix(":") || text.lowercased().hasPrefix("do ") || text.lowercased().hasPrefix("spend ") }
    private static func looksLikeNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard trimmed.count >= 2 else { return true }
        let lower = trimmed.lowercased()
        return ["to do", "todo", "tasks", "notes", "schedule", "planner", "date"].contains(lower)
    }
}


/// The preview deadline must not wait for a model that ignores cancellation.
private actor CaptureResponseRace {
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    func attach(_ continuation: CheckedContinuation<String, Error>) {
        if let result { continuation.resume(with: result) } else { self.continuation = continuation }
    }
    func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
