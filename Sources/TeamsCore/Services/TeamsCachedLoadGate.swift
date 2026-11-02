#if DEBUG
import Foundation
import Observation

@MainActor @Observable public final class TeamsCachedLoadGate {
    public struct Request: Equatable, Sendable, Codable {
        public let id: UUID
        public let accountScope: String
        public let accountRevision: UUID
        public let generation: UUID
        public let chatID: String

        public init(accountScope: String, accountRevision: UUID, generation: UUID, chatID: String) {
            id = UUID()
            self.accountScope = accountScope
            self.accountRevision = accountRevision
            self.generation = generation
            self.chatID = chatID
        }
    }

    public struct Event: Codable, Sendable {
        public let runID: UUID
        public let sequence: Int
        public let uptime: TimeInterval
        public let name: String
        public let accountScope: String
        public let chatID: String?
        public let request: Request?
        public let holdPending: Bool
        public let status: Int?
    }

    public let runID = UUID()
    public private(set) var held: Request?
    public private(set) var armed = false
    public private(set) var traceError: String?
    public private(set) var events: [Event] = []
    private var owner: (scope: String, revision: UUID)?
    private var continuation: AsyncStream<Bool>.Continuation?
    private let traceURL: URL?

    public init(traceURL: URL? = nil) { self.traceURL = traceURL }

    public func arm(accountScope: String, accountRevision: UUID) {
        guard !armed, held == nil else { return }
        owner = (accountScope, accountRevision)
        armed = true
        record("armed", accountScope: accountScope)
    }

    public func wait(_ request: Request) async throws {
        try Task.checkCancellation()
        guard armed, held == nil, owner?.scope == request.accountScope,
              owner?.revision == request.accountRevision else { return }
        let stream = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        armed = false
        owner = nil
        held = request
        continuation = stream.continuation
        record("held_after_history_capture", request: request)
        try await withTaskCancellationHandler {
            var iterator = stream.stream.makeAsyncIterator()
            guard await iterator.next() == true else { throw CancellationError() }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in self.cancel(request, reason: "task_cancelled") }
        }
    }

    public func release(_ request: Request, accountScope: String, accountRevision: UUID) {
        guard held == request, request.accountScope == accountScope,
              request.accountRevision == accountRevision else { return }
        record("released", request: request)
        finish(released: true)
    }

    public func invalidate(reason: String) {
        if let held { cancel(held, reason: reason) }
        if armed { record(reason, accountScope: owner?.scope ?? "") }
        armed = false
        owner = nil
    }

    public func complete(_ request: Request, cancelled: Bool) {
        if held == request { cancel(request, reason: "load_ended") }
        record(cancelled ? "cached_preparation_cancelled" : "cached_preparation_completed", request: request)
    }

    public func post(account: String, chatID: String, status: Int? = nil, failed: Bool = false) {
        let scope = "fixture-tenant:" + account
        let matching = held.flatMap { $0.accountScope == scope && $0.chatID == chatID ? $0 : nil }
        record(failed ? "post_failed" : status == nil ? "post_attempt" : "post_result",
               accountScope: scope, chatID: chatID, request: matching, status: status)
    }

    private func cancel(_ request: Request, reason: String) {
        guard held == request else { return }
        record(reason, request: request)
        finish(released: false)
    }

    private func finish(released: Bool) {
        let pending = continuation
        continuation = nil
        held = nil
        pending?.yield(released)
        pending?.finish()
    }

    private func record(_ name: String, accountScope: String = "", chatID: String? = nil,
                        request: Request? = nil, status: Int? = nil) {
        let event = Event(runID: runID, sequence: events.count + 1, uptime: ProcessInfo.processInfo.systemUptime,
                          name: name, accountScope: request?.accountScope ?? accountScope,
                          chatID: request?.chatID ?? chatID, request: request,
                          holdPending: request != nil && held == request, status: status)
        events.append(event)
        guard let traceURL else { return }
        do {
            let data = try JSONEncoder().encode(event) + Data([10])
            if !FileManager.default.fileExists(atPath: traceURL.path) {
                guard FileManager.default.createFile(atPath: traceURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: traceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { traceError = "Fixture trace could not be saved." }
    }
}
#endif
