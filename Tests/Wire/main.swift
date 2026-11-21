import Foundation
@main enum WireGate {
 static func main() throws {
  for path in CommandLine.arguments.dropFirst() {
   let data = try Data(contentsOf: URL(fileURLWithPath: path))
   let decoded = try LifeBoardValidation.decode(data)
   print("VALID " + URL(fileURLWithPath: path).lastPathComponent + " tasks=" + String(decoded.tasks.count))
  }
 }
}
