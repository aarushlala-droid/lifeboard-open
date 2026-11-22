import AppKit
import Foundation
import LifeBoardCore

@main
struct CaptureIntelligenceChecks {
    @MainActor
    static func main() async throws {
        let day = LocalDay(iso: "2026-11-07")!
        let data = LifeBoardData()
        let text = "Please send the chemistry worksheet tomorrow at 4 pm for 30 minutes"
        let baseline = NaturalLanguageTaskParser.parse(text, referenceDay: day, data: data)
        let manual = await CaptureIntelligence.interpret(text: text, data: data, referenceDay: day, useAppleIntelligence: false)
        require(!manual.usedAppleIntelligence && manual.note.contains("local parser"), "manual mode uses and identifies the local parser")
        require(manual.drafts.first?.targetDay == day.adding(days: 1) && manual.drafts.first?.startMinutes == 960, "manual dates and times remain available")

        let sources = NaturalLanguageTaskParser.parse("Call Priya tomorrow at 09:25\nFinish maths on Monday", referenceDay: day, data: data)
        let reordered = try CaptureIntelligence.applying([
            .init(index: 2, title: "Finish maths"),
            .init(index: 1, title: "Call Priya")
        ], to: sources)
        var expected = sources
        expected[0].title = "Call Priya"
        expected[1].title = "Finish maths"
        require(reordered == expected, "model titles map to original rows without changing any other fields")
        let drama = NaturalLanguageTaskParser.parse("research drama scenes scripts", referenceDay: day, data: data)
        let paraphrase = try CaptureIntelligence.applying([.init(index: 1, title: "analyze theatrical dialogue options")], to: drama)
        require(paraphrase == drama, "Capture keeps research drama scenes scripts when the model paraphrases it")
        let shortened = try CaptureIntelligence.applying([.init(index: 1, title: "Research drama scripts")], to: drama)
        require(shortened == drama, "Capture retains task words even if the model drops only one word")
        let polite = CapturedTaskDraft(title: "Please send the STEM report")
        let trimmed = try CaptureIntelligence.applying([.init(index: 1, title: "Send the stem report")], to: [polite])
        require(trimmed.first?.title == "send the STEM report", "Capture can trim Please while preserving the user's words and acronym capitalisation")
        for invalid: [CaptureTitleSuggestion] in [
            [.init(index: 1, title: "Only one row")],
            [.init(index: 1, title: "Duplicate"), .init(index: 1, title: "Duplicate")],
            [.init(index: 0, title: "Invalid"), .init(index: 2, title: "Valid")],
            [.init(index: 1, title: "  "), .init(index: 2, title: "Valid")]
        ] {
            require((try? CaptureIntelligence.applying(invalid, to: sources)) == nil, "incomplete or invalid model responses cannot overwrite the parser preview")
        }

        // The model may write abbreviated words out in full, and nothing else.
        func checked(_ original: String, _ model: String) throws -> String {
            try CaptureIntelligence.applying([.init(index: 1, title: model)], to: [CapturedTaskDraft(title: original)])[0].title
        }
        for (original, model, expected) in [
            ("Chem hw ws", "Chemistry homework worksheet", "Chemistry homework worksheet"),
            ("Rev pp ch 3", "Revision past paper chapter 3", "Revision past paper chapter 3"),
            ("Eng qs pg 4", "English questions page 4", "English questions page 4"),
            ("Physics prac write-up", "Physics practical write-up", "Physics practical write-up"),
            ("Hand in assgn", "Hand in assignment", "Hand in assignment"),
            ("History asgmt", "History assignment", "History assignment"),
            ("Do ex 2b", "Do exercise 2b", "Do exercise 2b"),
            ("q3 then q4", "question 3 then question 4", "question 3 then question 4"),
            ("Finish hw, then ws", "Finish homework, then worksheet", "Finish homework, then worksheet"),
            ("Hw for maths", "homework for Maths", "Homework for maths"),
            ("Please do chem hw", "Do chemistry homework", "do chemistry homework"),
            ("Read the STEM brief", "Read the STEM brief", "Read the STEM brief")
        ] {
            let result = try checked(original, model)
            require(result == expected, "Capture accepts \(model.debugDescription) for \(original.debugDescription) as \(expected.debugDescription) (got \(result.debugDescription))")
        }
        for (original, model) in [
            ("SAT prep", "Saturday preparation"),
            ("PE kit", "Physical Education kit"),
            ("Do ex 2", "Do exercise 20"),
            ("Read ch 3", "Read chapter three"),
            ("Chem hw", "Chemistry homework tomorrow"),
            ("Chem hw", "Homework chemistry"),
            ("Chem hw ws", "Chemistry homework"),
            ("Chem hw", "Chemistry work"),
            ("Bio pp", "Biology past, paper"),
            ("Bio hw", "Biology homework 2"),
            ("Chem hw", "Chem h")
        ] {
            require(try checked(original, model) == original, "Capture keeps \(original.debugDescription) when the model returns \(model.debugDescription)")
        }
        let parsed = NaturalLanguageTaskParser.parse("chem hw due fri @4p\nSAT prep tmr", referenceDay: day, data: data)
        let mixed = try CaptureIntelligence.applying([.init(index: 1, title: "Chemistry homework"), .init(index: 2, title: "Saturday prep")], to: parsed)
        var expectedRows = parsed
        expectedRows[0].title = "Chemistry homework"
        require(mixed == expectedRows, "each row is checked on its own and only the title of an accepted row changes")
        require(mixed[0].targetDay == day.adding(days: 6) && mixed[0].startMinutes == 960, "expanded titles keep the parsed date and time")
        let longOriginal = Array(repeating: "hw", count: 200).joined(separator: " ")
        let longModel = Array(repeating: "homework", count: 200).joined(separator: " ")
        require(try checked(longOriginal, longModel) == longModel, "long titles are aligned without recursion")

        if CommandLine.arguments.contains("--live") {
            require(baseline.count == 1 && baseline.allSatisfy { !$0.needsReview }, "live input exercises the old skipped-model path")
            let live = await CaptureIntelligence.interpret(text: text, data: data, referenceDay: day)
            print(live.note)
            require(live.usedAppleIntelligence && live.drafts.count == 1, "normal capture uses the real on-device model")
            require(live.drafts[0].title.localizedCaseInsensitiveContains("chemistry")
                    && live.drafts[0].targetDay == day.adding(days: 1) && live.drafts[0].startMinutes == 960,
                    "model title remains grounded while the exact date and time survive")
            let image = NSImage(size: NSSize(width: 1100, height: 180), flipped: true) { rect in
                NSColor.white.setFill()
                NSBezierPath.fill(rect)
                (text as NSString).draw(at: NSPoint(x: 24, y: 40), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.black
                ])
                return true
            }
            let imageResult = try await CaptureIntelligence.interpretImage(in: image, data: data, referenceDay: day)
            print(imageResult.note)
            require(imageResult.usedAppleIntelligence && imageResult.drafts.first?.startMinutes == 960,
                    "Vision OCR flows through the real on-device model and keeps the time")
        }
    }

    static func require(_ result: Bool, _ message: String) {
        guard result else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
}
