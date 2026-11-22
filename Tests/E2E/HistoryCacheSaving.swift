import Foundation
import TeamsCore

@main
struct HistoryCacheSaving {
    private static let chatID = "19:fixture-history-cache@thread.v2"

    private static func message(_ index: Int, version: Int = 1, content: String? = nil) -> TeamsWebMessage {
        .init(id: String(1_800_000_000_000 + index), content: content ?? "<p><strong>Fictional message \(index)</strong> Xin chào</p>",
              messageType: "RichText/Html", imDisplayName: "Fixture User", from: .string("8:orgid:fixture"),
              originalArrivalTime: String(1_800_000_000_000 + index), version: String(version),
              properties: .object(["files": .string("[]"), "emotions": .string("[]")]))
    }

    private static func fileURL(_ root: URL) throws -> URL {
        let accountDirectory = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.hasDirectoryPath }
        guard let accountDirectory else { preconditionFailure("Cache directory was not created") }
        let files = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil)
        guard let file = files.first(where: { $0.lastPathComponent.hasPrefix("chat-") }) else { preconditionFailure("History file was not written") }
        return file
    }

    private static func fileNumber(_ root: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: fileURL(root).path)[.systemFileNumber] as? NSNumber)?.intValue ?? -1
    }

    private static func stored(_ root: URL) async throws -> TeamsCachedHistory {
        try await TeamsReadCache(root: root, accountID: "account", tenantID: "tenant").history(in: chatID)
    }

    private static func expectWrite(_ root: URL, _ cache: TeamsReadCache, _ history: TeamsCachedHistory, _ label: String) async throws {
        let before = try fileNumber(root)
        try await cache.save(history, in: chatID)
        let after = try fileNumber(root)
        precondition(after != before, "\(label): history was not rewritten")
        let reread = try await stored(root)
        precondition(reread.messages == history.messages && reread.messageToken == history.messageToken, "\(label): stored history differs")
    }

    private static func expectSkip(_ root: URL, _ cache: TeamsReadCache, _ history: TeamsCachedHistory, _ label: String) async throws {
        let before = try fileNumber(root)
        try await cache.save(history, in: chatID)
        let after = try fileNumber(root)
        precondition(after == before, "\(label): unchanged history was rewritten")
        let reread = try await stored(root)
        precondition(reread.messages == history.messages && reread.messageToken == history.messageToken, "\(label): stored history differs")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-cache-saving-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        var history = TeamsCachedHistory(messages: (1...20).map { message($0) }, messageToken: "older-1", refreshedAt: Date(timeIntervalSince1970: 1))
        try await cache.save(history, in: chatID)
        let first = try await stored(root)
        precondition(first.messages == history.messages)

        history.refreshedAt = Date(timeIntervalSince1970: 2)
        history.merge(history.messages)
        try await expectSkip(root, cache, history, "refresh without changes")

        history.merge([message(21)])
        try await expectWrite(root, cache, history, "new message")

        history.messageToken = "older-2"
        try await expectWrite(root, cache, history, "new page token")

        history.messageToken = nil
        try await expectWrite(root, cache, history, "removed page token")

        history.merge([message(5, version: 2, content: "<p>Edited fictional message</p>")])
        try await expectWrite(root, cache, history, "edited message")

        history.merge([message(5, version: 1)])
        try await expectSkip(root, cache, history, "older version ignored")

        let reopened = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        var restored = try await reopened.history(in: chatID)
        precondition(restored.messages == history.messages)
        restored.refreshedAt = Date(timeIntervalSince1970: 3)
        try await expectSkip(root, reopened, restored, "unchanged history after reading the cache")
        restored.merge([message(22)])
        try await expectWrite(root, reopened, restored, "new message after reading the cache")

        let directory = try fileURL(root).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        var failed = restored
        failed.merge([message(23)])
        var failedToSave = false
        do { try await reopened.save(failed, in: chatID) } catch { failedToSave = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        precondition(failedToSave, "Saving into a read-only cache directory unexpectedly succeeded")
        try await expectWrite(root, reopened, failed, "retry after a failed save")
        try await expectWrite(root, reopened, restored, "return to an earlier history")

        let fresh = TeamsReadCache(root: root, accountID: "account", tenantID: "tenant")
        try await expectWrite(root, fresh, restored, "first save by a new cache")

        let large = TeamsCachedHistory(messages: (1...2_000).map { message($0) }, messageToken: "older")
        try await fresh.save(large, in: chatID)
        var timings: [Double] = []
        for index in 0..<15 {
            var refreshed = large
            refreshed.refreshedAt = Date(timeIntervalSince1970: Double(index))
            refreshed.merge(large.messages)
            let start = ContinuousClock.now
            try await fresh.save(refreshed, in: chatID)
            timings.append(milliseconds(start.duration(to: .now)))
        }
        let final = try await stored(root)
        precondition(final.messages == large.messages)
        print("HISTORY_CACHE_SAVING_OK: 11 cases, unchanged 2000-message refresh save median \(String(format: "%.3f", timings.sorted()[7])) ms")
    }
}
