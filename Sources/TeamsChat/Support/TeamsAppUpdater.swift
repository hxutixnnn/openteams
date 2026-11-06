import AppKit
import Foundation
import Observation

struct TeamsUpdateRevision: Decodable, Equatable {
    let sha: String

    static func parse(_ data: Data, statusCode: Int) throws -> Self {
        guard statusCode == 200 else {
            throw NSError(domain: "OpenTeams.Update", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: statusCode == 403 || statusCode == 429
                            ? "GitHub is limiting update checks. Try again later."
                            : "Could not check for updates (HTTP \(statusCode))."])
        }
        let revision = try JSONDecoder().decode(Self.self, from: data)
        guard revision.sha.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return revision
    }
}

struct TeamsUpdateStatus: Codable, Equatable {
    let state: String
    let message: String
    let commit: String
    let pid: Int32

    var active: Bool { ["starting", "downloading", "building", "installing"].contains(state) }
}

@MainActor @Observable final class TeamsAppUpdater {
    static let shared = TeamsAppUpdater()
    private(set) var checking = false
    private(set) var available: TeamsUpdateRevision?
    private(set) var message = "Check for updates to OpenTeams."
    private(set) var status: TeamsUpdateStatus?
    private(set) var logURL: URL?
    private var job: URL?
    private var worker: Process?
    private let root: URL
    private let installedRevision: String

    var revision: String { installedRevision }
    var busy: Bool { checking || status?.active == true }
    var canInstall: Bool {
        !busy && available != nil && Bundle.main.bundleURL.path == "/Applications/OpenTeams.app"
            && Bundle.main.url(forResource: "update_app", withExtension: "py") != nil
    }

    init(root: URL = URL.applicationSupportDirectory.appending(path: "TeamsChat/Updates", directoryHint: .isDirectory),
         installedRevision: String? = nil) {
        self.root = root
        self.installedRevision = installedRevision ?? Bundle.main.object(forInfoDictionaryKey: "OpenTeamsSourceRevision") as? String ?? "unknown"
        if let name = try? String(contentsOf: root.appending(path: "current"), encoding: .utf8),
           UUID(uuidString: name) != nil {
            job = root.appending(path: name, directoryHint: .isDirectory)
            refreshStatus()
        }
    }

    func check() async {
        guard !busy else { return }
        checking = true
        available = nil
        message = "Checking for updates…"
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/hxutixnnn/OpenTeams/commits/main")!)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("OpenTeams", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let latest = try TeamsUpdateRevision.parse(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            if latest.sha == revision {
                message = "OpenTeams is up to date."
            } else {
                available = latest
                message = "An update is available: \(latest.sha.prefix(7))."
            }
        } catch {
            message = "Could not check for updates: " + error.localizedDescription
        }
    }

    func install() {
        guard canInstall, let available,
              let script = Bundle.main.url(forResource: "update_app", withExtension: "py") else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let job = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let workerScript = job.appending(path: "update_app.py")
            try FileManager.default.copyItem(at: script, to: workerScript)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = [workerScript.path, available.sha]
            process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            worker = process
            self.job = job
            let starting = TeamsUpdateStatus(state: "starting", message: "Starting the update…", commit: available.sha, pid: process.processIdentifier)
            status = starting
            logURL = job.appending(path: "update.log")
            message = starting.message
        } catch {
            message = "Could not start the update: " + error.localizedDescription
        }
    }

    func refreshStatus() {
        guard let job else { return }
        if let data = try? Data(contentsOf: job.appending(path: "status.json")),
           let status = try? JSONDecoder().decode(TeamsUpdateStatus.self, from: data) {
            if self.status != status {
                self.status = status
                message = status.message
            }
            logURL = job.appending(path: "update.log")
        }
        if let status, status.active, kill(status.pid, 0) != 0, errno == ESRCH {
            self.status = TeamsUpdateStatus(state: "failed", message: "The update was interrupted. Check for updates to try again.", commit: status.commit, pid: status.pid)
            message = self.status!.message
        }
    }
}
