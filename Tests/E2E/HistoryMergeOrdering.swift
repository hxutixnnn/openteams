import Foundation
import TeamsCore

@main
struct HistoryMergeOrdering {
    private static func message(_ id: String, arrival: String?, version: String? = "1", content: String = "<p>Fictional</p>") -> TeamsWebMessage {
        .init(id: id, content: content, messageType: "RichText/Html", imDisplayName: "fixture", from: .string("8:orgid:fixture"),
              originalArrivalTime: arrival, version: version)
    }

    private static func reference(_ existing: [TeamsWebMessage], _ incoming: [TeamsWebMessage]) -> [TeamsWebMessage] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for message in incoming {
            if let current = byID[message.id],
               let old = Decimal(string: current.version ?? ""), let new = Decimal(string: message.version ?? ""), new < old { continue }
            byID[message.id] = message
        }
        return byID.values.sorted {
            let left = $0.arrivalDate ?? .distantPast, right = $1.arrivalDate ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }
    }

    private static func check(_ existing: [TeamsWebMessage], _ incoming: [TeamsWebMessage]) {
        var history = TeamsCachedHistory(messages: existing, messageToken: "token")
        history.merge(incoming)
        precondition(history.messages == reference(existing, incoming), "Merged history differs from the reference order")
        precondition(history.messageToken == "token")
    }

    static func main() {
        let a = message("a", arrival: "2026-11-22T05:00:00.000Z")
        let b = message("b", arrival: "2026-11-22T05:00:00.000Z")
        let c = message("c", arrival: "2026-11-22T04:59:59.999Z")
        let undated = message("undated", arrival: nil)
        let undatedEarlier = message("0-undated", arrival: "not a date")
        check([], [])
        check([], [b, a, c])
        check([a, b, c], [])
        check([a, b], [b, a, undated, undatedEarlier, c])
        check([a], [message("a", arrival: "2026-11-22T06:00:00.000Z", version: "2")])
        check([message("a", arrival: "2026-11-22T06:00:00.000Z", version: "3")], [message("a", arrival: "2026-11-22T04:00:00.000Z", version: "2")])
        check([a], [message("a", arrival: "2026-11-22T04:00:00.000Z", version: nil, content: "<p>Unversioned</p>")])
        check([a, a, b], [b, b])

        var state: UInt64 = 0x4D45_5247
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        func generated() -> TeamsWebMessage {
            let arrival = next(8) == 0 ? nil : String(1_800_000_000_000 + next(40))
            return message(String(next(60)), arrival: arrival, version: next(5) == 0 ? nil : String(next(4)), content: "<p>\(next(1_000))</p>")
        }
        for _ in 0..<3_000 {
            check((0..<next(30)).map { _ in generated() }, (0..<next(30)).map { _ in generated() })
        }

        let history = (1...2_000).map { message(String(1_800_000_000_000 + $0), arrival: String(1_800_000_000_000 + $0)) }
        var timings: [Double] = []
        for index in 0..<15 {
            let incoming = history + [message(String(1_800_000_002_001 + index), arrival: String(1_800_000_002_001 + index)), history[1_999]]
            check(history, incoming)
            var merged = TeamsCachedHistory(messages: history, messageToken: nil)
            let start = ContinuousClock.now
            merged.merge(incoming)
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("HISTORY_MERGE_ORDERING_OK: 8 cases, 3000 generated merges, merge of one new message into 2000 median \(String(format: "%.2f", timings.sorted()[7])) ms")
    }
}
