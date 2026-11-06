import Foundation

@main struct AppUpdateCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenTeams-update-check-" + UUID().uuidString)
        let older = TeamsAppUpdater(root: root, installedRevision: String(repeating: "0", count: 40))
        await older.check()
        guard let latest = older.available else {
            fatalError("Live GitHub update check failed: " + older.message)
        }
        precondition(latest.sha.count == 40)
        precondition(!older.busy)
        precondition(!older.canInstall)
        let current = TeamsAppUpdater(root: root, installedRevision: latest.sha)
        await current.check()
        precondition(current.available == nil, "Current build offered itself as an update")
        precondition(current.message == "OpenTeams is up to date.", current.message)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Checking created an update job")
        print("Live GitHub older-build and up-to-date workflows: PASS (\(latest.sha))")
    }
}
