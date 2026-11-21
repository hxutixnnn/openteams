import Foundation
import TeamsCore

private actor TextFragmentTransport: HTTPTransport {
    var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}

@main struct TextFragmentLoading {
    static let account = "fixture-a"
    static let tenant = "fixture-tenant"

    static func message(_ index: Int, tagged: Bool) -> TeamsWebMessage {
        let text = "Fictional message \(index) Xin chào 👋 Reference"
        return .init(id: String(1_800_000_000_000 + index), content: tagged ? "<p>\(text)</p>" : text,
                     messageType: "RichText/Html", imDisplayName: account, from: .string("8:orgid:" + account),
                     originalArrivalTime: String(1_800_000_000_000 + index), version: "1")
    }

    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    @MainActor static func main() async throws {
        for tagged in [false, true] {
            for count in [200, 2000] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-text-fragment-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let cache = TeamsReadCache(root: root, accountID: account, tenantID: tenant)
                let transport = TextFragmentTransport()
                let raw = (1...count).map { message($0, tagged: tagged) }
                try await cache.save(.init(messages: raw, messageToken: "older"), in: "fixture")
                let store = TeamsReaderStore(cacheRoot: root, transport: transport)
                await store.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
                var stages: [String: Double] = [:]
                store.onCachedLoadTiming = { name, milliseconds, _ in stages[name] = milliseconds }
                let start = ContinuousClock.now
                await store.loadConversation("fixture")
                let total = elapsed(start)
                let rendered = store.messages(in: "fixture")
                precondition(rendered.count == count && store.hasOlderMessages("fixture"))
                for (index, message) in rendered.enumerated() {
                    let text = "Fictional message \(index + 1) Xin chào 👋 Reference"
                    precondition(message.id == raw[index].id)
                    precondition(message.body == TeamsMessageBody(text: text, blocks: [.init(runs: [.init(text: text)])]))
                }
                let saved = try await cache.history(in: "fixture")
                precondition(saved.messages == raw && saved.messageToken == "older")
                let warmStart = ContinuousClock.now
                await store.loadConversation("fixture")
                let warm = elapsed(warmStart)
                precondition(store.messages(in: "fixture") == rendered)
                let row: [String: Any] = ["count": count, "tagged": tagged, "total_ms": total,
                                          "conversion_ms": stages["conversion"]!, "warm_ms": warm]
                print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                store.disconnect()
                let recovered = TeamsReaderStore(cacheRoot: root, transport: transport)
                await recovered.restoreAccount(accountID: account, tenantID: tenant, displayName: account)
                await recovered.loadConversation("fixture")
                precondition(recovered.messages(in: "fixture") == rendered)
                let requests = await transport.requests
                precondition(requests == 0)
            }
        }
        precondition(TeamsBodyParser.parse("").hasUnsupportedContent)
        precondition(TeamsBodyParser.parse(" \t\r\n").blocks.isEmpty)
        precondition(TeamsBodyParser.parse("A &amp; B").text == "A & B")
        precondition(TeamsBodyParser.parse("<strong>Bold</strong>").blocks.first?.runs.first?.bold == true)
        print("TEXT_FRAGMENT_LOADING_OK: tagless and tagged HTML, exact bodies, cached loading, warm reuse, raw persistence, restart, empty content, entities, formatting, no HTTP requests")
    }
}
