import Foundation
import Observation
import SwiftUI
import TeamsCore

struct TeamsMentionCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    static func matches(name: String, fragment: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let fragment = fragment.replacingOccurrences(of: "\u{00a0}", with: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if fragment.isEmpty { return true }
        var cursor = folded.startIndex
        while cursor < folded.endIndex, let range = folded.range(of: fragment, range: cursor..<folded.endIndex) {
            if range.lowerBound == folded.startIndex || !folded[folded.index(before: range.lowerBound)].isLetter { return true }
            cursor = folded.index(after: range.lowerBound)
        }
        return false
    }
}

@MainActor @Observable final class TeamsMentionPickerState {
    private(set) var candidates: [TeamsMentionCandidate] = []
    private(set) var selected = 0
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var choose: ((Int) -> Void)?
    func isOwned(by owner: UUID) -> Bool { self.owner == owner && !candidates.isEmpty }
    func show(owner: UUID, candidates: [TeamsMentionCandidate], choose: @escaping (Int) -> Void) {
        if self.owner != owner || self.candidates != candidates { selected = 0 }
        self.owner = owner; self.candidates = candidates; self.choose = choose
    }
    func clear(owner: UUID) { guard self.owner == owner else { return }; self.owner = nil; candidates = []; selected = 0; choose = nil }
    func move(_ delta: Int, owner: UUID) {
        guard self.owner == owner, !candidates.isEmpty else { return }
        selected = (selected + delta + candidates.count) % candidates.count
    }
    func select(_ index: Int) { guard candidates.indices.contains(index) else { return }; choose?(index) }
}

struct TeamsMentionSuggestions: View {
    let picker: TeamsMentionPickerState
    var body: some View {
        if !picker.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Known members").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 3)
                ForEach(Array(picker.candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button { picker.select(index) } label: {
                        HStack {
                            Text(candidate.name)
                            if picker.candidates.filter({ $0.name == candidate.name }).count > 1 {
                                Text("Member \(index + 1)").foregroundStyle(.secondary).font(.caption)
                            }
                            Spacer()
                        }.contentShape(Rectangle()).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(index == picker.selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel(candidate.name + ", member \(index + 1)")
                }
            }
            .padding(5)
            .frame(maxWidth: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(TeamsSurface.border))
        }
    }
}
