import Foundation

/// Prevent an older WebKit snapshot from replacing a renewed native session.
public enum TeamsSessionSelection {
    public static func shouldAcceptBrowser(_ candidate: TeamsWebSession, replacing current: TeamsWebSession?,
                                           allowAccountSwitch: Bool) -> Bool {
        guard let current else { return true }
        guard candidate.accountID == current.accountID && candidate.tenantID == current.tenantID else {
            return allowAccountSwitch
        }
        guard let newMessaging = candidate.messaging, let oldMessaging = current.messaging else { return false }
        guard candidate.expiresAt >= current.expiresAt, newMessaging.expiresAt >= oldMessaging.expiresAt else { return false }
        if candidate.expiresAt > current.expiresAt || newMessaging.expiresAt > oldMessaging.expiresAt { return true }
        let sameTokens = candidate.accessToken == current.accessToken && newMessaging.accessToken == oldMessaging.accessToken
        return sameTokens && ((candidate.directoryBaseURL != nil && current.directoryBaseURL == nil) ||
                              (candidate.searchSession?.expiresAt ?? .distantPast) > (current.searchSession?.expiresAt ?? .distantPast) ||
                              (candidate.directory?.expiresAt ?? .distantPast) > (current.directory?.expiresAt ?? .distantPast))
    }
}
