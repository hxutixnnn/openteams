import SwiftUI
import TeamsCore

struct TeamsNewChatView: View {
    var store: TeamsReaderStore
    let account: String
    let accountRevision: UUID
    let ownsPresentation: () -> Bool
    let connect: () -> Void
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    @ViewState<String> private var title = ""
    @ViewState<[TeamsDirectoryPerson]> private var results = []
    @ViewState<[TeamsDirectoryPerson]> private var selected = []
    @ViewState<String?> private var error = nil
    @ViewState<Bool> private var busy = false
    @ViewState<Bool> private var searched = false
    @ViewState<Bool> private var outcomeUnknown = false
    @ViewState<TeamsReaderStore.CreationReview?> private var presentedReview = nil
    @ViewState<Bool> private var reviewWasPresent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat").font(.headline)
            HStack {
                TextField("Find people", text: $query).textFieldStyle(.plain).padding(7).modifier(TeamsControlSurface()).onSubmit(search)
                Button("Search", action: search).disabled(busy || !store.connected || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !selected.isEmpty {
                Text("To: " + selected.map(\.title).joined(separator: ", ")).font(.callout)
                Button("Clear recipients") { selected = [] }.buttonStyle(.link)
            }
            List(results) { person in
                Button {
                    if !selected.contains(where: { $0.id == person.id }) { selected.append(person) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(person.title)
                        if let address = person.userPrincipalName ?? person.email { Text(address).font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain).disabled(person.mri == nil || selected.contains(where: { $0.id == person.id }))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(TeamsSurface.nested, in: RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TeamsSurface.nestedRadius, style: .continuous).strokeBorder(TeamsSurface.border, lineWidth: TeamsSurface.borderWidth))
            .frame(minHeight: 170)
            .overlay {
                if results.isEmpty && !busy {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.magnifyingglass")
                        Text(searched && error == nil ? "No people found" : "Search for people")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            if selected.count > 1 { TextField("Group name (optional)", text: $title).textFieldStyle(.plain).padding(7).modifier(TeamsControlSurface()) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !store.connected {
                HStack { Text("Reconnect to continue. Your recipients and group name are kept here.").font(.caption); Button("Reconnect", action: connect) }
            }
            if reviewWasPresent {
                if let review = presentedReview, review.state == .known, let id = review.threadID {
                    Text(review.status == 207 ? "The chat was created, but some participants may not have been added. Review its participants." : "The chat was created. Review its participants in the chat.")
                        .font(.caption).foregroundStyle(.orange)
                    HStack {
                        Button("Open chat") {
                            guard ownsPresentation(), !reviewChanged else { return }
                            store.ensureKnownCreationVisible(); created(id)
                        }.disabled(reviewChanged)
                        Button("Refresh chat details") {
                            guard ownsPresentation(), !reviewChanged else { return }
                            Task {
                                do {
                                    try await store.refreshKnownCreation(id, expectedAccount: account, expectedRevision: accountRevision)
                                    guard ownsPresentation() else { return }
                                    error = "Chat details refreshed. The member list may be incomplete."
                                } catch {
                                    guard ownsPresentation() else { return }
                                    self.error = error.localizedDescription
                                }
                            }
                        }.disabled(busy || !store.connected || reviewChanged)
                    }
                } else {
                    Text("A previous creation may have succeeded. Check your chats before allowing another attempt.").font(.caption).foregroundStyle(.orange)
                }
                if reviewChanged {
                    Text("The previous operation changed. Close and reopen this dialog to review its latest status.").font(.caption).foregroundStyle(.secondary)
                }
                if store.creationNeedsReview {
                    Button("I reviewed this; allow another attempt") {
                        guard ownsPresentation(), !reviewChanged else { return }
                        let id = presentedReview?.operationID
                        Task {
                            guard ownsPresentation() else { return }
                            let cleared = await store.acknowledgeChatCreationReview(expectedID: id, expectedAccount: account, expectedRevision: accountRevision, isCurrent: { ownsPresentation() })
                            guard ownsPresentation() else { return }
                            if cleared { outcomeUnknown = false; reviewWasPresent = false; presentedReview = nil }
                            else { error = "This creation is still in progress or its review changed. Reopen the dialog to check." }
                        }
                    }.disabled(store.isCreatingChat || reviewChanged)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create chat", action: create).buttonStyle(.borderedProminent)
                    .disabled(busy || !store.connected || selected.isEmpty || outcomeUnknown || store.creationNeedsReview)
            }
        }.padding(20)
        .modifier(TeamsInsetPanel())
        .background(TeamsSurface.window)
        .buttonBorderShape(.roundedRectangle(radius: TeamsSurface.controlRadius)).frame(width: 480, height: 420)
            .onAppear { presentedReview = store.creationReview; reviewWasPresent = store.creationReview != nil || store.creationNeedsReview }
    }

    private var reviewChanged: Bool {
        presentedReview?.operationID != store.creationReview?.operationID || presentedReview?.state != store.creationReview?.state
    }

    private func search() {
        guard !busy, ownsPresentation() else { return }
        let term = query
        busy = true; error = nil
        Task {
            guard ownsPresentation() else { return }
            do {
                let people = try await store.findPeople(term, expectedAccount: account, expectedRevision: accountRevision)
                guard ownsPresentation() else { return }
                if term == query { results = people; searched = true }
            } catch {
                guard ownsPresentation() else { return }
                self.error = error.localizedDescription
            }
            if ownsPresentation() { busy = false }
        }
    }

    private func create() {
        guard !busy, !outcomeUnknown, ownsPresentation() else { return }
        busy = true; error = nil
        let people = selected, capturedTitle = title
        Task {
            guard ownsPresentation() else { return }
            do {
                let result = try await store.createChat(with: people, title: capturedTitle, expectedAccount: account, expectedRevision: accountRevision, isCurrent: { ownsPresentation() })
                guard ownsPresentation() else { return }
                if result.status == 201 { store.ensureKnownCreationVisible(); created(result.threadID) }
                else { presentedReview = store.creationReview; reviewWasPresent = true; error = nil }
            } catch {
                guard ownsPresentation() else { return }
                if (error as? TeamsConversationError) == .creationOutcomeUnknown { outcomeUnknown = true; presentedReview = store.creationReview; reviewWasPresent = true }
                self.error = error.localizedDescription
            }
            if ownsPresentation() { busy = false }
        }
    }
}
