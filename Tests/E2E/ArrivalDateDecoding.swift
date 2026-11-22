import Foundation
import TeamsCore

@main struct ArrivalDateDecoding {
    private static func reference(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func samples() -> [String] {
        var values = ["2026-11-21T15:19:25.250Z", "2026-11-21T15:19:25Z", "2026-11-21T15:19:25.2Z", "2026-11-21T15:19:25.2501234Z",
                      "2026-11-21T15:19:25.250+07:00", "2026-11-21T15:19:25+0700", "2026-11-21T15:19:25.250-05:30", "2026-11-21T15:19:25.250z",
                      "2026-11-21 15:19:25Z", "2026-11-21T15:19Z", "2026-11-21", "20261121T151925Z", "garbage", "2026-11-21T15:19:60Z",
                      "2026-02-30T00:00:00Z", " 2026-11-21T15:19:25Z", "2026-11-21T15:19:25.1234567890Z", "0001-01-01T00:00:00Z",
                      "9999-12-31T23:59:59.999Z", "2026-11-21T15:19:25,250Z", "2026-11-21T24:00:00Z", "2026-13-01T00:00:00Z",
                      "2026-11-31T00:00:00Z", "2026-11-21T15:19:25+07", "2026-11-21T15:19:25.Z", "2026-11-21T15:19:25.250+07:00:00",
                      "2026-11-21T15:19:25Zjunk", "-2026-11-21T15:19:25Z", "1969-12-31T23:59:59.999Z", "1901-01-01T00:00:00.001-12:00",
                      "2026-11-21T15:19:25.999999999+14:00", "2026-11-21T15:19:25.0005Z", "2026-11-21t15:19:25Z", "2026-11-21T15:19:25+24:00"]
        let whole = ISO8601DateFormatter()
        for index in 0..<2_000 {
            let stamp = whole.string(from: Date(timeIntervalSince1970: -2_000_000_000 + Double(index) * 2_919_919.37))
            let fraction = String(String(repeating: String(index * 7_919 % 1_000_000_007), count: 2).prefix(index % 9))
            let zone = ["Z", "+07:00", "-03:30", "+0545", "z", "+00:00"][index % 6]
            values.append(String(stamp.dropLast()) + (fraction.isEmpty ? "" : "." + fraction) + zone)
        }
        return values
    }

    private static func message(_ index: Int, arrival: String) -> TeamsWebMessage {
        TeamsWebMessage(id: "\(1_793_420_000_000 + index)", content: "<p>\(index)</p>", messageType: "RichText/Html", originalArrivalTime: arrival)
    }

    private static func json(_ values: [String]) -> Data {
        let items = values.enumerated().map { index, value in
            "{\"id\":\"\(1_793_420_000_000 + index)\",\"messageType\":\"RichText/Html\",\"content\":\"<p>\(index)</p>\",\"originalArrivalTime\":\(String(reflecting: value)),\"composeTime\":\(String(reflecting: value))}"
        }
        return Data(("[" + items.joined(separator: ",") + "]").utf8)
    }

    private static func check(_ decoded: [TeamsWebMessage], against values: [String]) {
        precondition(decoded.count == values.count)
        for (message, value) in zip(decoded, values) {
            let expected = reference(value) ?? (Double(message.id).map { Date(timeIntervalSince1970: $0 / 1_000) })
            precondition(message.arrivalDate == expected, "Arrival date mismatch for \(value.debugDescription)")
        }
    }

    static func main() async throws {
        let values = samples()
        let data = json(values)
        check(values.enumerated().map { message($0.offset, arrival: $0.element) }, against: values)
        check(try JSONDecoder().decode([TeamsWebMessage].self, from: data), against: values)
        try await withThrowingTaskGroup(of: [TeamsWebMessage].self) { group in
            for _ in 0..<8 { group.addTask { try JSONDecoder().decode([TeamsWebMessage].self, from: data) } }
            for try await decoded in group { check(decoded, against: values) }
        }
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = try JSONDecoder().decode([TeamsWebMessage].self, from: data)
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("ArrivalDateDecoding passed: \(values.count) ISO arrival times, decode median \(String(format: "%.1f", timings.sorted()[2])) ms")
    }
}
