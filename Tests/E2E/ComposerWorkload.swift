import CryptoKit
import Foundation
import TeamsCore

private struct Snapshot: Codable, Equatable {
    let accountKey: String
    var drafts: [String: String]
    var outgoing: [String: TeamsOutgoingMessage]
    var replies: [String: TeamsReplyDraft]?
    var richDrafts: [String: TeamsRichDraft]?
}

@main struct ComposerWorkload {
    static let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    static let tenant = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    static func fixture(_ index: Int, rich: Bool, edit: Int = 0) -> TeamsRichDraft {
        let title = "Fictional release notes \(index): edit \(edit). Xin chào 👋."
        guard rich else { return .init(plainText: title) }
        let mention = TeamsRichDraft.Mention(mri: "8:orgid:fixture-person", displayName: "Alex Example",
                                            occurrenceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        return .init(blocks: [
            .init(runs: [.init(text: title, bold: true), .init(text: " Please review "), .init(text: "Alex Example", mention: mention)]),
            .init(kind: .numberedList, children: (0..<8).map { item in
                .init(kind: .listItem, runs: [.init(text: "Item \(item): ", bold: true),
                    .init(text: "Check the fictional release layout and keyboard behavior. "),
                    .init(text: "Reference", link: URL(string: "https://example.com/fixture/\(item)")),
                    .init(text: " — all data here is synthetic.", italic: true)])
            }),
            .init(kind: .quote, runs: [.init(text: "A saved draft must retain formatting and mention identity.")])
        ])
    }

    @MainActor static func main() throws {
        let samples = Int(ProcessInfo.processInfo.environment["COMPOSER_SAMPLES"] ?? "20")!
        let key = SHA256.hash(data: Data((tenant + "\n" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        for rich in [false, true] {
            for count in [1, 20, 100] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("openteams-composer-bench-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let file = root.appendingPathComponent(key + ".json")
                let documents = (0..<count).map { fixture($0, rich: rich) }
                var expected = Snapshot(accountKey: key, drafts: [:], outgoing: [:], replies: [:], richDrafts: [:])
                for (index, document) in documents.enumerated() {
                    expected.drafts["chat-\(index)"] = document.plainText
                    if rich { expected.richDrafts?["chat-\(index)"] = document }
                }
                try JSONEncoder().encode(expected).write(to: file, options: .atomic)
                let store = TeamsComposeStore(root: root)
                store.restore(accountID: account, tenantID: tenant)
                precondition(store.persistenceError == nil)
                for mode in ["edit", "identical"] {
                    var times: [Double] = [], writes = 0, bytes = 0
                    for sample in -3..<samples {
                        let document = mode == "edit" ? fixture(0, rich: rich, edit: sample + 10) : fixture(0, rich: rich, edit: samples + 9)
                        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
                        let start = ContinuousClock.now
                        store.setRichDraft(document, in: "chat-0")
                        let duration = start.duration(to: .now).components
                        let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                        let data = try Data(contentsOf: file)
                        let saved = try JSONDecoder().decode(Snapshot.self, from: data)
                        expected.drafts["chat-0"] = document.plainText
                        if rich { expected.richDrafts?["chat-0"] = document }
                        precondition(saved == expected && store.persistenceError == nil)
                        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
                        if sample >= 0 {
                            times.append(elapsed)
                            if attributes[.systemFileNumber] as! NSNumber != before { writes += 1; bytes += data.count }
                        }
                    }
                    let sorted = times.sorted()
                    let row: [String: Any] = ["kind": rich ? "rich" : "plain", "drafts": count, "mode": mode,
                        "samples_ms": times, "median_ms": sorted[sorted.count / 2], "min_ms": sorted.first!, "max_ms": sorted.last!,
                        "write_count": writes, "bytes_written": bytes, "saved_bytes": try Data(contentsOf: file).count,
                        "plain_utf8_per_draft": documents[0].plainText.utf8.count, "saved_state_and_permissions_ok": true]
                    let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    FileHandle.standardOutput.write(json + Data([10]))
                }
                let recovered = TeamsComposeStore(root: root)
                recovered.restore(accountID: account, tenantID: tenant)
                precondition(recovered.drafts == expected.drafts && recovered.richDrafts == expected.richDrafts && recovered.persistenceError == nil)
            }
        }
        print("E2E_OK composer workload: 12 cases")
    }
}
