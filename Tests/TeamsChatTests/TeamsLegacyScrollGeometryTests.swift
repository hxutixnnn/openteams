import AppKit
import Testing
@testable import TeamsChat

struct TeamsLegacyScrollGeometryTests {
    @Test func bottomDistanceHandlesFlippedAndUnflippedDocuments() {
        let document = CGRect(x: 0, y: 20, width: 300, height: 1000)
        #expect(TeamsLegacyScrollGeometry.isAtBottom(document: document, visible: CGRect(x: 0, y: 820, width: 300, height: 200), flipped: true))
        #expect(!TeamsLegacyScrollGeometry.isAtBottom(document: document, visible: CGRect(x: 0, y: 700, width: 300, height: 200), flipped: true))
        #expect(TeamsLegacyScrollGeometry.isAtBottom(document: document, visible: CGRect(x: 0, y: 20, width: 300, height: 200), flipped: false))
        #expect(!TeamsLegacyScrollGeometry.isAtBottom(document: document, visible: CGRect(x: 0, y: 100, width: 300, height: 200), flipped: false))
        #expect(TeamsLegacyScrollGeometry.isAtBottom(document: document, visible: CGRect(x: 0, y: 0, width: 300, height: 200), flipped: false))
    }
    @Test func noMovementGrowthWaitsForInputAndMovementCancelsIt() {
        var still = TeamsLegacyGrowthDecision()
        #expect(still.observe(wasBottom: true, isBottom: false, grew: true, moved: false, inputActive: true) == .deferFollow)
        let followed = still.finishInput(), followedAgain = still.finishInput()
        #expect(followed && !followedAgain)
        var moving = TeamsLegacyGrowthDecision()
        #expect(moving.observe(wasBottom: true, isBottom: false, grew: true, moved: false, inputActive: true) == .deferFollow)
        #expect(moving.observe(wasBottom: false, isBottom: false, grew: false, moved: true, inputActive: true) == .update)
        let followedAfterMovement = moving.finishInput()
        #expect(!followedAfterMovement)
    }

}
