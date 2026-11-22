import Foundation
import TeamsCore

@main
struct MessagePropertyDecoding {
    private static let messageCount = 2_000

    static func main() {
        let reactions = "[{\"key\":\"like\",\"users\":[{\"mri\":\"8:orgid:a\"},{\"mri\":\"8:orgid:b\"}]},{\"key\":\"heart\",\"users\":[{\"mri\":\"8:orgid:c\"}]}]"
        let files = "[{\"title\":\"Plan.docx\",\"openUrl\":\"https://contoso.sharepoint.com/plan.docx\"}]"
        let expectedReactions = [["like": ["8:orgid:a", "8:orgid:b"]], ["heart": ["8:orgid:c"]]]

        for empty in ["[]", "", "[ ]", "{}", "not json", String(repeating: " ", count: 128_001)] {
            let message = rendered(files: .string(empty), emotions: .string(empty))
            precondition(message.files.isEmpty && message.reactions.isEmpty, "Expected no files or reactions for \(empty.prefix(12))")
        }

        let encoded = rendered(files: .string(files), emotions: .string(reactions))
        precondition(encoded.reactions.map { [$0.key: $0.userIDs] } == expectedReactions)
        precondition(encoded.files.map(\.title) == ["Plan.docx"])
        precondition(encoded.files.map(\.url.absoluteString) == ["https://contoso.sharepoint.com/plan.docx"])

        let padded = rendered(files: .string(" " + files), emotions: .string(" " + reactions + " "))
        precondition(padded.reactions == encoded.reactions && padded.files == encoded.files)

        let decodedReactions = try! JSONDecoder().decode(TeamsWebJSONValue.self, from: Data(reactions.utf8))
        let decodedFiles = try! JSONDecoder().decode(TeamsWebJSONValue.self, from: Data(files.utf8))
        let structured = rendered(files: decodedFiles, emotions: decodedReactions)
        precondition(structured.reactions == encoded.reactions && structured.files == encoded.files)

        let none = rendered(files: nil, emotions: nil)
        precondition(none.files.isEmpty && none.reactions.isEmpty)

        let empty = TeamsWebJSONValue.object(["files": .string("[]"), "emotions": .string("[]")])
        let withEmpty = best { renderAll(properties: empty) }
        let withoutProperties = best { renderAll(properties: nil) }
        print(String(format: "MessagePropertyDecoding passed: %d messages with empty files and emotions strings %.2f ms, without properties %.2f ms", messageCount, withEmpty, withoutProperties))
    }

    private static func rendered(files: TeamsWebJSONValue?, emotions: TeamsWebJSONValue?) -> TeamsRenderedMessage {
        var properties: [String: TeamsWebJSONValue] = [:]
        properties["files"] = files
        properties["emotions"] = emotions
        let message = TeamsWebMessage(id: "message", content: "<p>Hello</p>", messageType: "RichText/Html", imDisplayName: "A", from: .string("8:orgid:a"), originalArrivalTime: "1800000000000", version: "1", properties: .object(properties))
        return TeamsRenderedMessage(message, people: [:])
    }

    private static func renderAll(properties: TeamsWebJSONValue?) -> Int {
        (0..<messageCount).reduce(0) { total, index in
            let message = TeamsWebMessage(id: String(index), content: "<p>Hello \(index)</p>", messageType: "RichText/Html", imDisplayName: "A", from: .string("8:orgid:a"), originalArrivalTime: String(1_800_000_000_000 + index), version: "1", properties: properties)
            return total + TeamsRenderedMessage(message, people: [:]).files.count
        }
    }

    private static func best(_ work: () -> Int) -> Double {
        var fastest = Double.infinity
        for _ in 0..<5 {
            let start = ContinuousClock.now
            precondition(work() == 0)
            let elapsed = start.duration(to: .now).components
            fastest = min(fastest, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        return fastest
    }
}
