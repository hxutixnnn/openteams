import Testing
@testable import TeamsChat

struct TeamsMentionPickerTests {
    @Test func nameMatchingFindsLaterWordBoundaryAndFoldsAccents() {
        #expect(TeamsMentionCandidate.matches(name: "Madam Ada", fragment: "ada"))
        #expect(TeamsMentionCandidate.matches(name: "Áda Example", fragment: "ada"))
        #expect(TeamsMentionCandidate.matches(name: "A person", fragment: "person"))
        #expect(!TeamsMentionCandidate.matches(name: "Madam", fragment: "ada"))
    }
}
