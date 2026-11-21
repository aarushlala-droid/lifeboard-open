import Foundation

let input = """
# Biology specification
Learning objectives:
1.1 Cell structure
1.2 Cell division
• cell structure
- Photosynthesis
2) Respiration
Cell division
"""
let drafts = try TopicImportParser.parse(input, existing: ["RESPIRATION"])
precondition(drafts.map(\.title) == ["Cell structure", "Cell division", "cell structure", "Photosynthesis", "Respiration", "Cell division"])
precondition(drafts.filter(\.isIncluded).count == 3)
precondition(drafts[0].originalLine == "1.1 Cell structure")
var edited = drafts
edited[2].title = "Specialised cells"; edited[2].isIncluded = true
let accepted = TopicImportParser.accepted(edited, existing: ["Respiration", "Photosynthesis"])
precondition(accepted.map(\.title) == ["Cell structure", "Cell division", "Specialised cells"])
precondition(accepted.last?.originalLine == "• cell structure")
precondition(TopicImportParser.normalizedTitle("  CAFÉ   study ") == "cafe study")
let tooLong = try TopicImportParser.parse(String(repeating: "x", count: 2_001))
precondition(tooLong[0].reviewReason != nil && !tooLong[0].isIncluded)
let large = (0..<5_000).map { "\($0 + 1). Topic \($0)" }.joined(separator: "\n")
let largeResult = try TopicImportParser.parse(large)
precondition(largeResult.count == 5_000)
do { _ = try TopicImportParser.parse(String(repeating: "x", count: 1_048_577)); preconditionFailure("Too large input accepted") } catch TopicImportError.tooLarge { }
do { _ = try TopicImportParser.parse(String(repeating: "topic\n", count: 10_001)); preconditionFailure("Too many lines accepted") } catch TopicImportError.tooManyLines { }
print("Topic import: numbering, headings, existing/preview duplicates, edited titles, original lines, 5,000 topics, size/line bounds passed")
let grounded = TopicImportParser.grounded(["Cell structure", "invented quantum biology", "CELL DIVISION"], in: input, existing: [])
precondition(grounded.map(\.title) == ["Cell structure", "CELL DIVISION"])
precondition(grounded[0].originalLine == "1.1 Cell structure")
print("AI grounding: invented titles rejected; case-insensitive literal source titles and original lines preserved")
