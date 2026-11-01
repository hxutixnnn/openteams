import Foundation

public enum TeamsSessionHandoff {
    private struct Payload: Decodable {
        let csaBaseURL: URL
        let accessToken: String
        let expiresAt: Double
        let messaging: MessagingPayload?
        let search: MessagingPayload?
        let directory: MessagingPayload?
        let directoryBaseURL: URL?
    }
    private struct MessagingPayload: Decodable {
        let baseURL: URL
        let accessToken: String
        let expiresAt: Double
    }
    private struct Claims: Decodable {
        let aud: String
        let oid: String
        let tid: String
        let name: String?
        let exp: Double
    }

    public static func decode(_ data: Data, at now: Date = Date()) throws -> TeamsWebSession {
        guard data.count <= 100_000,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TeamsWebClientError.invalidSession
        }
        let claims = try claims(in: payload.accessToken)
        guard ["https://chatsvcagg.teams.microsoft.com", "https://chatsvcagg.teams.microsoft.com/"].contains(claims.aud),
              UUID(uuidString: claims.oid) != nil, UUID(uuidString: claims.tid) != nil,
              claims.exp.isFinite, payload.expiresAt.isFinite else { throw TeamsWebClientError.invalidSession }
        var messaging: TeamsMessagingSession?
        if let value = payload.messaging {
            let chatClaims = try self.claims(in: value.accessToken)
            guard ["https://ic3.teams.office.com", "https://ic3.teams.office.com/",
                   "https://ic3-non-cae.teams.office.com", "https://ic3-non-cae.teams.office.com/"].contains(chatClaims.aud),
                  chatClaims.oid == claims.oid, chatClaims.tid == claims.tid,
                  chatClaims.exp.isFinite, value.expiresAt.isFinite else { throw TeamsWebClientError.invalidSession }
            messaging = TeamsMessagingSession(baseURL: value.baseURL, accessToken: value.accessToken,
                                              expiresAt: Date(timeIntervalSince1970: min(value.expiresAt, chatClaims.exp)))
            try messaging?.validate(at: now)
        }
        func optionalResource(_ value: MessagingPayload?, audience: String) throws -> (URL, String, Date)? {
            guard let value else { return nil }
            let resourceClaims = try self.claims(in: value.accessToken)
            guard resourceClaims.aud.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == audience.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  resourceClaims.oid == claims.oid, resourceClaims.tid == claims.tid,
                  value.expiresAt.isFinite, resourceClaims.exp.isFinite else { throw TeamsWebClientError.invalidSession }
            return (value.baseURL, value.accessToken, Date(timeIntervalSince1970: min(value.expiresAt, resourceClaims.exp)))
        }
        var search: TeamsSearchSession?
        if let (url, token, expires) = try optionalResource(payload.search, audience: "https://outlook.office.com") {
            search = TeamsSearchSession(baseURL: url, accessToken: token, expiresAt: expires, accountID: claims.oid, tenantID: claims.tid)
            try search?.validate(at: .distantPast)
            if expires <= now { search = nil }
        }
        var directory: TeamsDirectorySession?
        if let (url, token, expires) = try optionalResource(payload.directory, audience: "https://api.spaces.skype.com") {
            directory = TeamsDirectorySession(baseURL: url, accessToken: token, expiresAt: expires)
            try directory?.validate(at: .distantPast)
            if expires <= now { directory = nil }
        }
        if let route = payload.directoryBaseURL {
            try TeamsDirectorySession(baseURL: route, accessToken: "route-validation", expiresAt: .distantFuture).validate(at: now)
        }
        let session = TeamsWebSession(baseURL: payload.csaBaseURL, accessToken: payload.accessToken,
                                      expiresAt: Date(timeIntervalSince1970: min(payload.expiresAt, claims.exp)),
                                      accountID: claims.oid, tenantID: claims.tid, displayName: claims.name ?? "Teams account",
                                      messaging: messaging, searchSession: search, directory: directory, directoryBaseURL: payload.directoryBaseURL)
        try session.validate(at: now)
        return session
    }

    private static func claims(in token: String) throws -> Claims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw TeamsWebClientError.invalidSession }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let raw = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(Claims.self, from: raw) else {
            throw TeamsWebClientError.invalidSession
        }
        return claims
    }
}
