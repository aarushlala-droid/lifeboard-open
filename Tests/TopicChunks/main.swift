import Foundation
import LifeBoardCore
let source = "Cell structure\nCell division\nPhotosynthesis\nRespiration\nInheritance"
let chunks = try TopicImportIntelligence.completeChunks(source, maximumBytes: 30)
precondition(chunks.count > 1)
precondition(chunks.joined(separator: "\n") == source)
precondition(chunks.allSatisfy { $0.utf8.count <= 30 })
do { _ = try TopicImportIntelligence.completeChunks(String(repeating: "x", count: 31), maximumBytes: 30); preconditionFailure("Long source paragraph silently truncated") } catch { }
print("AI complete-source chunking: every source line retained, bounded chunks, oversized paragraph rejected explicitly")
