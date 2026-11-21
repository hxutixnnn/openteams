import Foundation
import TeamsCore

private actor GitHubTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var existingBody: String?
    var status = 0
    func setExisting(_ body: String?) { existingBody = body }
    func fail(with status: Int) { self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        if status != 0 {
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "0"])!)
        }
        let payload: Any
        let code: Int
        if url.path == "/search/issues" {
            let items: [[String: Any]] = existingBody.map { [["number": 7, "html_url": "https://github.com/hxutixnnn/openteams/issues/7", "state": "open", "body": $0]] } ?? []
            payload = ["total_count": items.count, "items": items]
            code = 200
        } else if url.path.hasSuffix("/comments") {
            payload = ["id": 1]
            code = 201
        } else {
            payload = ["number": 42, "html_url": "https://github.com/hxutixnnn/openteams/issues/42", "state": "open"]
            code = 201
        }
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private struct FixedToken: GitHubTokenSource {
    let value: String?
    func gitHubToken() async throws -> String? { value }
}

private func json(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

@main struct GitHubIssueFiling {
    static func main() async throws {
        let secret = "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"
        let messageBody = "Lunch at the usual place with Minh"
        let transport = GitHubTransport()
        let client = GitHubIssueClient(tokenSource: FixedToken(value: secret),
                                       redactor: GitHubIssueRedactor(sensitiveValues: [messageBody, "Minh Tran"]),
                                       transport: transport)
        let environment = GitHubIssueEnvironment(appVersion: "1.0 (7)", appRevision: String(repeating: "a", count: 40), osVersion: "macOS 27.0")
        let report = GitHubIssueReport(
            title: "Sync stalled for minh.tran@contoso.com",
            summary: "Refresh failed after sending \"\(messageBody)\" to Minh Tran",
            reproSteps: ["Open chat 19:abc123def@thread.v2", "Press ⌘R"],
            environment: environment,
            errorText: "HTTP 401 Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJl skypetoken=abc.def.ghi user 8:orgid:2f1c0b9e-1a2b-4c3d-9e8f-0123456789ab https://teams.microsoft.com/api/chats?token=abcdef {\"content\":\"\(messageBody)\",\"id\":\"1\"} call +84 912 345 678",
            stack: "0 TeamsCore 0x1 refresh() /Users/minh/Projects/OpenTeams/Sources/TeamsCore/Services/TeamsWebClient.swift:120 \(secret)",
            fingerprint: "sync-stalled-401")

        let created = try await client.fileOrBump(report)
        precondition(created == .created(.init(number: 42, url: URL(string: "https://github.com/hxutixnnn/openteams/issues/42")!, state: "open")), "\(created)")
        var requests = await transport.requests
        precondition(requests.count == 2, "\(requests.count)")
        precondition(requests[0].httpMethod == "GET" && requests[0].url!.path == "/search/issues")
        precondition(requests[0].url!.query!.contains("openteams-fingerprint-sync-stalled-401"))
        let create = requests[1]
        precondition(create.httpMethod == "POST" && create.url!.absoluteString == "https://api.github.com/repos/hxutixnnn/openteams/issues")
        precondition(create.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
        precondition(create.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        precondition(create.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        let issue = json(create)
        let title = issue["title"] as! String
        let body = issue["body"] as! String
        precondition(issue["labels"] as! [String] == ["auto", "bug"])
        precondition(title == "Sync stalled for [REDACTED_EMAIL]", title)
        let sent = title + body
        for leak in [secret, messageBody, "Minh", "minh", "contoso", "eyJhbGci", "abc.def.ghi", "2f1c0b9e", "abc123def", "token=abcdef", "912 345", "/Users/minh"] {
            precondition(!sent.contains(leak), "Leaked \(leak) in:\n\(sent)")
        }
        for expected in ["## Summary", "## Steps to reproduce", "1. Open chat [REDACTED_CONVERSATION]", "2. Press ⌘R", "## Environment",
                         "- App version: 1.0 (7)", "- Revision: " + String(repeating: "a", count: 40), "- OS: macOS 27.0", "## Error",
                         "HTTP 401", "## Stack", "TeamsWebClient.swift:120", "Fingerprint: `openteams-fingerprint-sync-stalled-401`"] {
            precondition(body.contains(expected), "Missing \(expected) in:\n\(body)")
        }

        await transport.setExisting(body)
        let bumped = try await client.fileOrBump(report)
        precondition(bumped == .bumped(.init(number: 7, url: URL(string: "https://github.com/hxutixnnn/openteams/issues/7")!, state: "open")), "\(bumped)")
        requests = await transport.requests
        precondition(requests.count == 4, "\(requests.count)")
        precondition(requests[3].httpMethod == "POST" && requests[3].url!.path == "/repos/hxutixnnn/openteams/issues/7/comments")
        let comment = json(requests[3])["body"] as! String
        precondition(comment.hasPrefix("Seen again: ") && comment.contains("## Environment"), comment)
        precondition(!comment.contains(messageBody) && !comment.contains(secret) && !comment.contains("Minh"), comment)

        await transport.setExisting("Different issue without the marker")
        let unrelated = try await client.find(fingerprint: "sync-stalled-401")
        precondition(unrelated == nil)

        let feedback = try await client.create(GitHubIssueReport(title: "Feedback: sidebar", summary: "Sidebar is great", environment: environment,
                                                                 labels: GitHubIssueReport.feedbackLabels))
        precondition(feedback.number == 42)
        requests = await transport.requests
        precondition(json(requests.last!)["labels"] as! [String] == ["feedback"])

        let countBeforeUnconfigured = requests.count
        for token in [nil, "", "  \n", "has space"] as [String?] {
            do {
                _ = try await GitHubIssueClient(tokenSource: FixedToken(value: token), transport: transport).fileOrBump(report)
                preconditionFailure("Filed without a usable token")
            } catch GitHubIssueError.notConfigured {}
        }
        let countAfterUnconfigured = await transport.requests.count
        precondition(countAfterUnconfigured == countBeforeUnconfigured, "Sent a request without a token")

        do {
            _ = try await client.create(GitHubIssueReport(title: " \n ", summary: "Empty title", environment: environment))
            preconditionFailure("Filed an issue without a title")
        } catch GitHubIssueError.invalidReport {}

        let failures: [(Int, GitHubIssueError)] = [(401, .unauthorized), (403, .rateLimited(retryAfter: nil)), (404, .repositoryUnavailable), (500, .http(status: 500))]
        for (status, expected) in failures {
            await transport.fail(with: status)
            do {
                _ = try await client.create(report)
                preconditionFailure("HTTP \(status) did not fail")
            } catch let error as GitHubIssueError {
                precondition(error == expected, "HTTP \(status): \(error)")
            }
        }
        print("GitHub issue filing create, find, bump, redaction and failure workflows: PASS")
    }
}
