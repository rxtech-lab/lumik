import SwiftUI

struct ChatView: View {
  @Environment(AppStore.self) private var store
  @State private var composer = ""
  @State private var proposal: Proposal?
  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            if store.messages.isEmpty {
              VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(
                  Color.buddyGreen)
                Text("Less paperwork.\nMore peace of mind.").font(
                  .system(.largeTitle, design: .rounded, weight: .bold))
                Text(
                  "Ask me to organize your groups, find document details, or design a new extraction template."
                ).foregroundStyle(.secondary)
                Text(
                  "Try “Create a group for travel receipts with vendor, date, currency, and total.”"
                ).font(.callout).padding().background(
                  Color.buddyGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
              }.padding(.vertical, 32)
            }
            ForEach(store.messages) { message in
              HStack {
                if message.role == "user" { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                  Text(message.role == "user" ? "You" : "Buddy").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Text(message.content).textSelection(.enabled)
                }.padding(16).background(
                  message.role == "user"
                    ? Color.buddyGreen.opacity(0.10) : Color.secondary.opacity(0.07),
                  in: RoundedRectangle(cornerRadius: 20))
                if message.role != "user" { Spacer(minLength: 20) }
              }.id(message.id)
            }
            ForEach(store.proposals) { p in
              Button {
                Haptics.tap()
                proposal = p
              } label: {
                HStack {
                  Image(systemName: "checklist")
                  VStack(alignment: .leading) {
                    Text(p.title).font(.headline)
                    Text("Review change").font(.caption)
                  }
                  Spacer()
                  Image(systemName: "chevron.right")
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
              }.buttonStyle(.plain)
            }
            Color.clear.frame(height: 1).id("bottom")
          }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }.onChange(of: store.messages.count) {
          withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
      }.safeAreaInset(edge: .bottom) {
        HStack(alignment: .bottom, spacing: 12) {
          TextField("Ask Buddy…", text: $composer, axis: .vertical).textFieldStyle(.plain)
            .lineLimit(1...6).padding(12)
          Button {
            let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
            composer = ""
            Haptics.tap()
            Task { await store.send(text) }
          } label: {
            Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44)
          }.buttonStyle(.borderedProminent).clipShape(Circle()).disabled(
            composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy != nil)
        }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28)).padding(
          .horizontal, 20
        ).padding(.bottom, 12).frame(maxWidth: 840)
      }.navigationTitle("Buddy")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button("New conversation", systemImage: "square.and.pencil") {
                store.messages = []
                Haptics.tap()
              }
              Button("Refresh pending changes", systemImage: "arrow.clockwise") {
                Task { await loadProposals() }
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }
        .task { await loadProposals() }
        .sheet(item: $proposal) { ProposalReview(proposal: $0).fullSheet().actionFeedback() }
    }
  }
  func loadProposals() async {
    if store.isPreview { return }
    do { store.proposals = try await store.fetch([Proposal].self, "proposals") } catch {
      store.error = error.localizedDescription
    }
  }
}
struct ProposalReview: View {
  let proposal: Proposal
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var confirm = false
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Label("Your approval is needed", systemImage: "hand.raised").foregroundStyle(
            Color.buddyGreen)
          Text(proposal.title).font(.title.bold())
          Text("Review the exact change below. Applying it will update your account.")
            .foregroundStyle(.secondary)
          Text(proposal.mutation.pretty).font(.callout.monospaced()).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
          Button("Apply change") {
            Haptics.tap()
            confirm = true
          }.buttonStyle(.borderedProminent)
          Button("Reject change", role: .destructive) { Task { await resolve(false) } }
        }.padding(24)
      }.navigationTitle("Review change").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
      .confirmationDialog("Apply this change?", isPresented: $confirm, titleVisibility: .visible) {
        Button(
          "Apply change",
          role: proposal.mutation.object["action"]?.string.hasPrefix("delete") == true
            ? .destructive : nil
        ) { Task { await resolve(true) } }
      }
    }
  }
  func resolve(_ approve: Bool) async {
    if await store.perform(
      approve ? "Applying change…" : "Rejecting change…",
      success: approve ? "Change applied" : "Change rejected",
      {
        _ = try await store.request(
          "proposals/\(proposal.id)", method: "POST",
          body: JSONEncoder().encode(["approve": approve]))
        store.proposals.removeAll { $0.id == proposal.id }
        await store.refresh()
      })
    {
      dismiss()
    }
  }
}
