import Foundation
import TeamsCore

@main
struct JSONValueDecoding {
    private struct Reference: Decodable {
        let value: TeamsWebJSONValue

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = .null }
            else if let decoded = try? container.decode(Bool.self) { value = .bool(decoded) }
            else if let decoded = try? container.decode(String.self) { value = .string(decoded) }
            else if let decoded = try? container.decode(Decimal.self) { value = .number(decoded) }
            else if let decoded = try? container.decode([String: Reference].self) { value = .object(decoded.mapValues(\.value)) }
            else if let decoded = try? container.decode([Reference].self) { value = .array(decoded.map(\.value)) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.") }
        }
    }

    private static let properties = "{\"files\":\"[]\",\"emotions\":[{\"key\":\"like\",\"users\":[{\"mri\":\"8:orgid:a\",\"time\":1793420000000,\"value\":\"1793420000000\"}]}],\"importance\":\"\",\"subject\":\"\",\"title\":\"\",\"cards\":\"[]\",\"links\":\"[]\",\"mentions\":\"[]\",\"formatVariant\":\"TEAMS\",\"languageStamp\":\"languages=en:100;\",\"edittime\":\"1793420000000\",\"s2spartnername\":\"skypespaces\"}"

    private static let literals = [
        "null", "true", "false", "0", "1", "-1", "1.5", "-0.0", "1e3", "2.5E-3", "12345678901234567890123", "0.1",
        "\"\"", "\"true\"", "\"1\"", "\"null\"", "\"[]\"", "\"{}\"", "\"Xin chào 👋\"", "\"\\u0000\\n\\\"\"",
        "[]", "{}", "[[[]]]", "[1,\"1\",true,null,{}]", "{\"a\":{\"b\":[false,0,\"x\"]}}", "{\"\":\"\"}", properties,
        "", "nul", "[1,", "{\"a\"}", "tru", "\"unterminated",
    ]

    private static func randomDocument(_ state: inout UInt64, depth: Int = 0) -> String {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let pick = Int(state >> 33) % (depth > 3 ? 6 : 8)
        switch pick {
        case 0: return "null"
        case 1: return state & 1 == 0 ? "true" : "false"
        case 2: return "\"value-\(state % 997)\""
        case 3: return String(Int64(bitPattern: state) % 1_000_000)
        case 4: return "\(Double(state % 100_000) / 128)"
        case 5: return ["\"[]\"", "\"\"", "\"true\"", "\"0\""][Int(state % 4)]
        case 6: return "[" + (0..<Int(state % 4)).map { _ in randomDocument(&state, depth: depth + 1) }.joined(separator: ",") + "]"
        default: return "{" + (0..<Int(state % 4)).map { "\"k\($0)\":" + randomDocument(&state, depth: depth + 1) }.joined(separator: ",") + "}"
        }
    }

    private static func check(_ document: String) {
        let data = Data(document.utf8)
        let actual = try? JSONDecoder().decode(TeamsWebJSONValue.self, from: data)
        let expected = try? JSONDecoder().decode(Reference.self, from: data).value
        precondition(actual == expected, "JSON value mismatch for \(document.prefix(80))")
        if let actual {
            let roundTrip = try! JSONDecoder().decode(TeamsWebJSONValue.self, from: JSONEncoder().encode(actual))
            precondition(roundTrip == actual, "JSON value round trip mismatch for \(document.prefix(80))")
        }
    }

    static func main() throws {
        literals.forEach(check)
        var state: UInt64 = 0x5EED
        for _ in 0..<4_000 { check(randomDocument(&state)) }

        let messages = (0..<2_000).map { "{\"id\":\"\($0)\",\"content\":\"<p>Fixture \($0)</p>\",\"messageType\":\"RichText/Html\",\"from\":\"8:orgid:other\",\"originalArrivalTime\":\"2026-11-22T05:00:00.123Z\",\"properties\":\(properties)}" }
        let data = Data(("[" + messages.joined(separator: ",") + "]").utf8)
        let decoded = try JSONDecoder().decode([TeamsWebMessage].self, from: data)
        let expected = try JSONDecoder().decode(Reference.self, from: Data(properties.utf8)).value
        precondition(decoded.count == 2_000 && decoded.allSatisfy { $0.properties == expected })
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = try JSONDecoder().decode([TeamsWebMessage].self, from: data)
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("JSON_VALUE_DECODING_OK: \(literals.count) literals, 4000 generated documents, round trips, 2000 messages decode median \(String(format: "%.1f", timings.sorted()[2])) ms")
    }
}
