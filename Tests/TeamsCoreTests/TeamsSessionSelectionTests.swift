import Foundation
import Testing
@testable import TeamsCore

struct TeamsSessionSelectionTests {
    private func session(_ csa: TimeInterval, _ chat: TimeInterval, account: String = "a") -> TeamsWebSession {
        .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/csa/amer")!, accessToken: "token",
              expiresAt: Date(timeIntervalSince1970: csa), accountID: account, tenantID: "tenant", displayName: "Test",
              messaging: .init(baseURL: URL(string: "https://teams.cloud.microsoft/api/chatsvc/amer")!,
                               accessToken: "chat", expiresAt: Date(timeIntervalSince1970: chat)))
    }

    @Test func rejectsBrowserRollbackForEitherResource() {
        let renewed = session(200, 200)
        #expect(!TeamsSessionSelection.shouldAcceptBrowser(session(100, 100), replacing: renewed, allowAccountSwitch: true))
        #expect(!TeamsSessionSelection.shouldAcceptBrowser(session(300, 100), replacing: renewed, allowAccountSwitch: true))
        #expect(!TeamsSessionSelection.shouldAcceptBrowser(session(200, 200), replacing: renewed, allowAccountSwitch: true))
        #expect(TeamsSessionSelection.shouldAcceptBrowser(session(300, 200), replacing: renewed, allowAccountSwitch: false))
    }

    @Test func accountSwitchRequiresExplicitSignIn() {
        let current = session(200, 200)
        let other = session(100, 100, account: "other")
        #expect(!TeamsSessionSelection.shouldAcceptBrowser(other, replacing: current, allowAccountSwitch: false))
        #expect(TeamsSessionSelection.shouldAcceptBrowser(other, replacing: current, allowAccountSwitch: true))
        #expect(TeamsSessionSelection.shouldAcceptBrowser(other, replacing: nil, allowAccountSwitch: false))
    }
}
