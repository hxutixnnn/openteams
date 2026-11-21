import Foundation

public protocol GitHubTokenSource: Sendable {
    func gitHubToken() async throws -> String?
}

public struct GitHubIssueEnvironment: Sendable, Equatable {
    public var appVersion: String
    public var appRevision: String
    public var osVersion: String
    public init(appVersion: String, appRevision: String, osVersion: String) {
        self.appVersion = appVersion; self.appRevision = appRevision; self.osVersion = osVersion
    }
    public static func current(bundle: Bundle = .main) -> GitHubIssueEnvironment {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return .init(appVersion: build.map { version + " (" + $0 + ")" } ?? version,
                     appRevision: bundle.object(forInfoDictionaryKey: "OpenTeamsSourceRevision") as? String ?? "unknown",
                     osVersion: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

public struct GitHubIssueReport: Sendable, Equatable {
    public static let automaticLabels = ["auto", "bug"]
    public static let feedbackLabels = ["feedback"]
    public var title: String
    public var summary: String
    public var reproSteps: [String]
    public var environment: GitHubIssueEnvironment
    public var errorText: String?
    public var stack: String?
    public var screenshotURL: URL?
    public var labels: [String]
    public var fingerprint: String?
    public init(title: String, summary: String, reproSteps: [String] = [], environment: GitHubIssueEnvironment = .current(),
                errorText: String? = nil, stack: String? = nil, screenshotURL: URL? = nil,
                labels: [String] = GitHubIssueReport.automaticLabels, fingerprint: String? = nil) {
        self.title = title; self.summary = summary; self.reproSteps = reproSteps; self.environment = environment
        self.errorText = errorText; self.stack = stack; self.screenshotURL = screenshotURL
        self.labels = labels; self.fingerprint = fingerprint
    }
}

public struct GitHubIssue: Sendable, Equatable, Decodable {
    public let number: Int
    public let url: URL
    public let state: String
    public init(number: Int, url: URL, state: String) { self.number = number; self.url = url; self.state = state }
    private enum CodingKeys: String, CodingKey { case number, url = "html_url", state }
}

public enum GitHubIssueFilingResult: Sendable, Equatable {
    case created(GitHubIssue)
    case bumped(GitHubIssue)
    public var issue: GitHubIssue {
        switch self { case .created(let issue), .bumped(let issue): issue }
    }
}

public enum GitHubIssueError: Error, Sendable, Equatable {
    case notConfigured
    case invalidReport
    case unauthorized
    case forbidden
    case repositoryUnavailable
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network
    case invalidResponse
}

public protocol GitHubIssueFiling: Sendable {
    func create(_ report: GitHubIssueReport) async throws -> GitHubIssue
    func find(fingerprint: String) async throws -> GitHubIssue?
    func bump(_ issue: GitHubIssue, with report: GitHubIssueReport) async throws
}

public extension GitHubIssueFiling {
    func fileOrBump(_ report: GitHubIssueReport) async throws -> GitHubIssueFilingResult {
        if let fingerprint = report.fingerprint, let existing = try await find(fingerprint: fingerprint) {
            try await bump(existing, with: report)
            return .bumped(existing)
        }
        return .created(try await create(report))
    }
}

public struct GitHubIssueRedactor: Sendable {
    public static let placeholder = "[REDACTED]"
    private static let rules: [(pattern: String, template: String)] = [
        (#"(?i)("(?:content|body|text|richText|displayName|imdisplayname|fromDisplayName|subject|preview|email|mail|upn|userPrincipalName|givenName|surname|phone)"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"[REDACTED]\""),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, "$1 [REDACTED]"),
        (#"(?i)\b(authorization|x-skypetoken|skypetoken|authentication|access_token|refresh_token|id_token|client_secret|token|password|passwd|secret|api[_-]?key|cookie|set-cookie)(["']?\s*[:=]\s*["']?)[^\s"',;&<>]+"#, "$1$2[REDACTED]"),
        (#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "[REDACTED_TOKEN]"),
        (#"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#, "[REDACTED_TOKEN]"),
        (#"(https?://[^\s?#"'<>()]+)[?#][^\s"'<>()]*"#, "$1?[REDACTED]"),
        (#"\b\d{1,2}:[A-Za-z0-9_.=-]+@(?:thread\.(?:v2|skype|tacv2)|unq\.gbl\.spaces)\b"#, "[REDACTED_CONVERSATION]"),
        (#"\b8:(?:orgid|live|teamsvisitor|guest):[A-Za-z0-9_.@-]+"#, "[REDACTED_USER]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[REDACTED_EMAIL]"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "[REDACTED_ID]"),
        (#"(/(?:Users|home)/)[^/\s"']+"#, "$1[REDACTED]"),
        (#"\+\d{1,3}[\s.-]?\(?\d{2,4}\)?[\s.-]?\d{3,4}[\s.-]?\d{3,4}\b"#, "[REDACTED_PHONE]"),
        (#"(?<![$\w])(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{48,}={0,2}"#, "[REDACTED_TOKEN]")
    ]

    public var sensitiveValues: [String]
    public init(sensitiveValues: [String] = []) { self.sensitiveValues = sensitiveValues }

    public func redact(_ text: String) -> String {
        var result = text
        for value in sensitiveValues.filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: value, with: Self.placeholder, options: [.caseInsensitive])
        }
        for rule in Self.rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template)
        }
        return result
    }
}

public struct GitHubIssueClient: GitHubIssueFiling {
    public static let defaultRepository = "hxutixnnn/openteams"
    public static let defaultAPIBaseURL = URL(string: "https://api.github.com")!
    static let fingerprintPrefix = "openteams-fingerprint-"
    private static let maximumBody = 60_000
    private static let maximumSection = 8_000
    private static let maximumTitle = 200

    private let repository: String
    private let apiBaseURL: URL
    private let tokenSource: any GitHubTokenSource
    private let redactor: GitHubIssueRedactor
    private let transport: any HTTPTransport

    public init(repository: String = GitHubIssueClient.defaultRepository, apiBaseURL: URL = GitHubIssueClient.defaultAPIBaseURL,
                tokenSource: any GitHubTokenSource, redactor: GitHubIssueRedactor = .init(),
                transport: any HTTPTransport = TeamsWebURLSessionTransport()) {
        self.repository = repository; self.apiBaseURL = apiBaseURL; self.tokenSource = tokenSource
        self.redactor = redactor; self.transport = transport
    }

    public func create(_ report: GitHubIssueReport) async throws -> GitHubIssue {
        let title = Self.singleLine(redactor.redact(report.title), limit: Self.maximumTitle)
        guard !title.isEmpty else { throw GitHubIssueError.invalidReport }
        let labels = report.labels.filter(Self.isSafeLabel)
        let payload = try JSONSerialization.data(withJSONObject: ["title": title, "body": issueBody(for: report), "labels": labels])
        let data = try await send("POST", path: ["issues"], body: payload, expecting: 201)
        guard let issue = try? JSONDecoder().decode(GitHubIssue.self, from: data) else { throw GitHubIssueError.invalidResponse }
        return issue
    }

    public func find(fingerprint: String) async throws -> GitHubIssue? {
        guard let marker = Self.marker(for: fingerprint) else { throw GitHubIssueError.invalidReport }
        let query = "repo:\(repository) is:issue is:open in:body \"\(marker)\""
        let data = try await send("GET", path: nil, query: [.init(name: "q", value: query), .init(name: "per_page", value: "20")], expecting: 200)
        guard let page = try? JSONDecoder().decode(SearchPage.self, from: data) else { throw GitHubIssueError.invalidResponse }
        return page.items.first { $0.pullRequest == nil && $0.body?.contains(marker) == true }?.issue
    }

    public func bump(_ issue: GitHubIssue, with report: GitHubIssueReport) async throws {
        var sections = ["Seen again: " + redactor.redact(report.summary), environmentSection(report.environment)]
        if let error = report.errorText.map(redactor.redact), !error.isEmpty { sections.append(Self.codeBlock("Error", error)) }
        let payload = try JSONSerialization.data(withJSONObject: ["body": Self.truncated(sections.joined(separator: "\n\n"), limit: Self.maximumBody)])
        _ = try await send("POST", path: ["issues", String(issue.number), "comments"], body: payload, expecting: 201)
    }

    public func issueBody(for report: GitHubIssueReport) -> String {
        var sections = ["## Summary\n" + Self.truncated(redactor.redact(report.summary), limit: Self.maximumSection)]
        let steps = report.reproSteps.map(redactor.redact).map { Self.singleLine($0, limit: 500) }.filter { !$0.isEmpty }
        if !steps.isEmpty {
            sections.append("## Steps to reproduce\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        sections.append(environmentSection(report.environment))
        if let error = report.errorText.map(redactor.redact), !error.isEmpty { sections.append(Self.codeBlock("## Error", error)) }
        if let stack = report.stack.map(redactor.redact), !stack.isEmpty { sections.append(Self.codeBlock("## Stack", stack)) }
        if let screenshot = report.screenshotURL, screenshot.scheme == "https" {
            sections.append("## Screenshot\n![Screenshot](" + redactor.redact(screenshot.absoluteString) + ")")
        }
        var body = Self.truncated(sections.joined(separator: "\n\n"), limit: Self.maximumBody)
        if let marker = report.fingerprint.flatMap(Self.marker) { body += "\n\nFingerprint: `" + marker + "`" }
        return body
    }

    private func environmentSection(_ environment: GitHubIssueEnvironment) -> String {
        "## Environment\n- App version: " + Self.singleLine(redactor.redact(environment.appVersion), limit: 100)
            + "\n- Revision: " + Self.singleLine(environment.appRevision, limit: 64)
            + "\n- OS: " + Self.singleLine(redactor.redact(environment.osVersion), limit: 100)
    }

    private func send(_ method: String, path: [String]?, query: [URLQueryItem] = [], body: Data? = nil, expecting status: Int) async throws -> Data {
        guard let token = try await tokenSource.gitHubToken()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              token.utf8.count <= 512, token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw GitHubIssueError.notConfigured }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 100
                && $0.unicodeScalars.allSatisfy { scalar in Self.isNameScalar(scalar, extra: "-_.") } }),
              apiBaseURL.scheme == "https", var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubIssueError.repositoryUnavailable
        }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let segments = path.map { ["repos", String(parts[0]), String(parts[1])] + $0 } ?? ["search", "issues"]
        components.percentEncodedPath = base + segments.map { segment in "/" + segment }.joined()
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GitHubIssueError.repositoryUnavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpShouldHandleCookies = false; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenTeams", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw GitHubIssueError.network }
        switch response.statusCode {
        case status: break
        case 401: throw GitHubIssueError.unauthorized
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField: "Retry-After") != nil,
             429:
            throw GitHubIssueError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 403: throw GitHubIssueError.forbidden
        case 404, 410: throw GitHubIssueError.repositoryUnavailable
        default: throw GitHubIssueError.http(status: response.statusCode)
        }
        guard data.count <= 5_000_000 else { throw GitHubIssueError.invalidResponse }
        return data
    }

    private static func marker(for fingerprint: String) -> String? {
        guard !fingerprint.isEmpty, fingerprint.utf8.count <= 64,
              fingerprint.unicodeScalars.allSatisfy({ isNameScalar($0, extra: "-_") }) else { return nil }
        return fingerprintPrefix + fingerprint
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar, extra: String) -> Bool {
        (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || extra.unicodeScalars.contains(scalar)
    }

    private static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 50 && label.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        truncated(text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces), limit: limit)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n… [truncated]"
    }

    private static func codeBlock(_ heading: String, _ text: String) -> String {
        heading + "\n```\n" + truncated(text.replacingOccurrences(of: "```", with: "'''"), limit: maximumSection) + "\n```"
    }

    private struct SearchPage: Decodable {
        struct Item: Decodable {
            let number: Int
            let htmlURL: URL
            let state: String
            let body: String?
            let pullRequest: PullRequestMarker?
            var issue: GitHubIssue { .init(number: number, url: htmlURL, state: state) }
            private enum CodingKeys: String, CodingKey { case number, htmlURL = "html_url", state, body, pullRequest = "pull_request" }
        }
        struct PullRequestMarker: Decodable {}
        let items: [Item]
    }
}
