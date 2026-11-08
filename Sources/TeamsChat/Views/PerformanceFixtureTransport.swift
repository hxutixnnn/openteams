#if DEBUG
import Foundation
import TeamsCore

actor PerformanceFixtureTransport: HTTPTransport {
    enum SendOutcome: String, Sendable {
        case accepted
        case uncertainAccepted = "uncertain-accepted"
        case uncertainAbsent = "uncertain-absent"
    }
    private let sendOutcome: SendOutcome
    private var holdReply: Bool
    private var holdSend: Bool
    private let closedChat: Bool
    private var replyWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var replyRequests = 0
    private let sendDelay: Double
    private let sendObservationURL: URL?
    private(set) var sendAttempts = 0
    private(set) var acceptedSends = 0
    private let allowsSend: Bool
    private var sentMessages: [String: [TeamsWebMessage]] = [:]
    private var nextSentID: Int64 = 1_800_000_010_000
    private let gate: TeamsCachedLoadGate?
    init(allowsSend: Bool, gate: TeamsCachedLoadGate? = nil, sendOutcome: SendOutcome = .accepted,
         sendDelay: Double = 0, sendObservationURL: URL? = nil,
         holdReply: Bool = false, holdSend: Bool = false, closedChat: Bool = false) {
        self.holdReply = holdReply
        self.holdSend = holdSend
        self.closedChat = closedChat
        self.sendOutcome = sendOutcome
        self.sendDelay = sendDelay.isFinite ? min(60, max(0, sendDelay)) : 0
        self.sendObservationURL = sendObservationURL
        self.allowsSend = allowsSend
        self.gate = gate
    }
    func releaseReply() {
        holdReply = false
        let waiters = replyWaiters
        replyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func releaseSend() {
        holdSend = false
        let waiters = sendWaiters
        sendWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func recordObservation() throws { try recordSend(phase: "ready", account: "", chat: "") }

    func reserveSendIDs(_ messages: [TeamsWebMessage]) {
        for message in messages {
            if let id = Int64(message.id) { nextSentID = max(nextSentID, id) }
        }
    }
    private var newest = 100
    func cachedMessages(count: Int, account: String) -> [TeamsWebMessage] {
        (81...(80 + count)).map { index in
            TeamsWebMessage(id: String(1_800_000_000_000 + index),
                content: "<p><strong>Fictional cached message \(index) · \(account)</strong> Xin chào 👋 <a href=\"https://example.com/fixture\">Reference</a></p><ol><li>First item</li><li><em>Second item</em></li></ol>",
                messageType: "RichText/Html", imDisplayName: "Alex Example", from: .string("8:orgid:" + account),
                originalArrivalTime: String(1_800_000_000_000 + index), version: "1")
        }
    }
    private struct MessageTarget: Hashable {
        let account: String
        let chat: String
        let id: String
    }
    private var deleted: Set<MessageTarget> = []
    private var edits: [MessageTarget: TeamsWebMessage] = [:]
    private var likedAccounts: Set<String> = []

    func append() { newest += 1 }

    private func message(_ index: Int, account: String, chat: String = "fixture-one") -> TeamsWebMessage {
        let id = String(1_800_000_000_000 + index)
        let target = MessageTarget(account: account, chat: chat, id: id)
        let edited = edits[target]
        if deleted.contains(target) {
            return TeamsWebMessage(id: id, content: edited?.content ?? "Fictional message \(index)",
                messageType: edited?.messageType ?? "Text", imDisplayName: "Alex Example",
                from: .string("8:orgid:fixture-a"), originalArrivalTime: id,
                composeTime: "2026-11-01T00:00:00Z", version: edited == nil ? "2" : "3",
                properties: .object(["deletetime": .number(1)]))
        }
        if let edited { return edited }
        var properties: [String: TeamsWebJSONValue] = [:]
        if index == 50, likedAccounts.contains(account) {
            properties["emotions"] = .array([.object([
                "key": .string("like"), "users": .array([.object(["mri": .string("8:orgid:" + account)])])
            ])])
        }
        let content: String
        if index == 99 {
            content = #"""
            <blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="1800000000050"><strong itemprop="mri" itemid="8:orgid:ada">Ada Example</strong><span itemprop="time" itemid="1800000000050"></span><p itemprop="preview">Context-only message 50</p></blockquote><p>Fictional message 99</p>
            """#
        } else {
            content = index == 50 ? "Context-only message 50 · \(account)" : "Fictional message \(index)"
        }
        return TeamsWebMessage(id: id, content: content, messageType: index == 99 ? "RichText/Html" : "Text",
            imDisplayName: index == 50 ? "Ada Example" : "Alex Example", from: .string(index == 50 ? "8:orgid:ada" : "8:orgid:fixture-a"),
            originalArrivalTime: id, composeTime: "2026-11-01T00:00:00Z", version: "1",
            properties: properties.isEmpty ? nil : .object(properties))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == "teams.cloud.microsoft" else { throw URLError(.badURL) }
        let account: String
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer fictional-only-fixture-a": account = "fixture-a"
        case "Bearer fictional-only-fixture-b": account = "fixture-b"
        default: throw URLError(.userAuthenticationRequired)
        }
        let chatID = url.pathComponents.dropLast().last ?? ""
        let isSend = request.httpMethod == "POST" && ["fixture-one", "fixture-two"].contains(chatID)
            && url.path == "/api/chatsvc/fixture/v1/users/ME/conversations/" + chatID + "/messages"
        if isSend, allowsSend {
            sendAttempts += 1
            try recordSend(phase: "sending", account: account, chat: chatID)
            await gate?.post(account: account, chatID: chatID)
        }
        if request.httpMethod == "GET", url.path == "/api/csa/fixture/api/v1/chats/fixture-one/messages/1800000000050" {
            replyRequests += 1
            try recordSend(phase: "preparing-reply", account: account, chat: "fixture-one")
            if holdReply { await withCheckedContinuation { replyWaiters.append($0) } }
        }
        do {
            if isSend, allowsSend, holdSend { await withCheckedContinuation { sendWaiters.append($0) } }
            if isSend, allowsSend, sendDelay > 0 { try await Task.sleep(for: .seconds(sendDelay)) }
            let result = try response(for: request, url: url, account: account)
            if isSend, allowsSend { try recordSend(phase: "completed", account: account, chat: chatID) }
            if isSend { await gate?.post(account: account, chatID: chatID, status: result.1.statusCode) }
            return result
        } catch {
            if isSend, allowsSend { try recordSend(phase: "failed", account: account, chat: chatID) }
            if isSend { await gate?.post(account: account, chatID: chatID, failed: true) }
            throw error
        }
    }

    private func recordSend(phase: String, account: String, chat: String) throws {
        guard let sendObservationURL else { return }
        let observation: [String: TeamsWebJSONValue] = [
            "attempts": .number(Decimal(sendAttempts)), "accepted": .number(Decimal(acceptedSends)),
            "replyRequests": .number(Decimal(replyRequests)),
            "outcome": .string(sendOutcome.rawValue), "phase": .string(phase),
            "account": .string(account), "chat": .string(chat)
        ]
        try JSONEncoder().encode(observation).write(to: sendObservationURL, options: .atomic)
    }

    private func response(for request: URLRequest, url: URL, account: String) throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let components = url.pathComponents
        let contextMessagePath = "/api/chatsvc/fixture/v1/users/ME/conversations/fixture-one/messages/"
        let data: Data
        var status = 200
        var headers: [String: String] = [:]
        if method == "GET", url.path.hasSuffix("/chats") {
            let members: [TeamsWebMember] = [.init(mri: "8:orgid:fixture-a", displayName: "Alex Example"), .init(mri: "8:orgid:ada", displayName: "Ada Example")]
            data = try JSONEncoder().encode(TeamsWebChatPage(items: [
                .init(id: "fixture-one", title: "Fictional project", isDisabled: closedChat, members: members),
                .init(id: "fixture-two", title: "Fictional planning", members: members)
            ]))
        } else if method == "GET", url.path.hasSuffix("/conversationFolders") {
            data = try JSONEncoder().encode(TeamsConversationFolders(conversationFolders: [], conversationFolderOrder: [], isPartialResponse: false))
        } else if method == "GET", url.path == contextMessagePath + "epochTimeStamp/1800000000050" {
            let original = message(50, account: account)
            data = try JSONEncoder().encode(["messages": TeamsWebJSONValue.array([.object([
                "id": .string(original.id), "content": .string(original.content ?? ""),
                "messagetype": .string("Text"), "imdisplayname": .string("Ada Example"),
                "from": .string("8:orgid:ada"), "originalarrivaltime": .string(original.id),
                "composetime": .string("2026-11-01T00:00:00Z"), "version": .string("1"),
                "properties": original.properties ?? .object([:])
            ])])])
        } else if method == "GET", url.path == "/api/csa/fixture/api/v1/chats/fixture-one/messages/1800000000050" {
            data = try JSONEncoder().encode(message(50, account: account))
        } else if (method == "PUT" || method == "DELETE"), url.path == contextMessagePath + "1800000000050/properties",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "name", value: "emotions")] {
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
            guard case let .object(emotion)? = body["emotions"], emotion["key"]?.stringValue == "like" else { throw URLError(.badServerResponse) }
            if method == "PUT" { likedAccounts.insert(account) }
            else { likedAccounts.remove(account) }
            data = Data("{}".utf8)
        } else if method == "POST", allowsSend,
                  let chatID = components.dropLast().last, ["fixture-one", "fixture-two"].contains(chatID),
                  url.path == "/api/chatsvc/fixture/v1/users/ME/conversations/" + chatID + "/messages" {
            let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
            guard body["from"]?.stringValue == "8:orgid:" + account,
                  body["conversationid"]?.stringValue == chatID,
                  let content = body["content"]?.stringValue else { throw URLError(.badServerResponse) }
            if sendOutcome == .uncertainAbsent { throw URLError(.timedOut) }
            nextSentID += 1
            let id = String(nextSentID)
            sentMessages[account + ":" + chatID, default: []].append(TeamsWebMessage(id: id, content: content,
                messageType: body["messagetype"]?.stringValue, imDisplayName: account, from: .string("8:orgid:" + account),
                originalArrivalTime: id, composeTime: body["composetime"]?.stringValue,
                properties: body["properties"], clientMessageId: body["clientmessageid"]?.stringValue))
            acceptedSends += 1
            if sendOutcome == .uncertainAccepted { throw URLError(.timedOut) }
            status = 201
            headers["Location"] = url.absoluteString + "/" + id
            data = try JSONEncoder().encode(["OriginalArrivalTime": id])
        } else if method == "GET", url.path.hasSuffix("/messages"),
                  let chat = components.dropLast().last, ["fixture-one", "fixture-two"].contains(chat) {
            let older = request.value(forHTTPHeaderField: "x-ms-messageToken") == "older"
            var messages = (older ? 61...80 : 81...newest).map { message($0, account: account, chat: chat) }
            if !older, let chatID = components.dropLast().last { messages += sentMessages[account + ":" + chatID] ?? [] }
            data = try JSONEncoder().encode(TeamsWebMessagePage(messages: messages, messageToken: older ? nil : "older"))
        } else if let position = components.firstIndex(of: "messages"), components.count == position + 2,
                  let chat = components.prefix(position).last, ["fixture-one", "fixture-two"].contains(chat),
                  let index = Int(components[position + 1]), (61...200).contains(index - 1_800_000_000_000),
                  (method == "GET" && url.path == "/api/csa/fixture/api/v1/chats/\(chat)/messages/\(index)") ||
                  (["PUT", "DELETE"].contains(method) && url.path == "/api/chatsvc/fixture/v1/users/ME/conversations/\(chat)/messages/\(index)") {
            let id = components[position + 1]
            let target = MessageTarget(account: account, chat: chat, id: id)
            if method == "DELETE" { deleted.insert(target) }
            if method == "PUT" {
                let body = try JSONDecoder().decode([String: TeamsWebJSONValue].self, from: request.httpBody ?? Data())
                edits[target] = TeamsWebMessage(id: id, content: body["content"]?.stringValue,
                    messageType: body["messagetype"]?.stringValue, imDisplayName: "Alex Example",
                    from: .string("8:orgid:fixture-a"), originalArrivalTime: id,
                    composeTime: "2026-11-01T00:00:00Z", version: "2", properties: body["properties"])
            }
            data = method == "GET" ? try JSONEncoder().encode(message(index - 1_800_000_000_000, account: account, chat: chat)) : Data("{}".utf8)
        } else if method == "PUT", url.path.hasSuffix("/properties"), !components.contains("messages") {
            data = Data("{}".utf8)
        } else {
            status = 404
            data = Data("{}".utf8)
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

#endif
