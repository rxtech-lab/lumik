import SwiftUI

/// Buddy as its own screen: the iPhone tab and the sheet opened from a group or PDF.
struct ChatView: View {
  var body: some View {
    NavigationStack {
      ChatThread().navigationTitle("Buddy")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
/// The conversation. Screens and the right-hand panel all show this same thread.
struct ChatThread: View {
  @Environment(AppStore.self) private var store
  @State private var proposal: Proposal?
  private var contextGroup: ScanGroup? { store.groups.first { $0.id == store.selectedGroupID } }
  var body: some View {
    @Bindable var store = store
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if store.messages.isEmpty { welcome }
          ForEach(store.messages) { message in
            ChatBubble(message: message).id(message.id)
          }
          if store.sending {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text("Buddy is working…").font(.callout).foregroundStyle(.secondary)
            }
          }
          ForEach(store.proposals) { p in
            Button {
              Haptics.tap()
              proposal = p
            } label: {
              HStack {
                Image(systemName: "checklist")
                VStack(alignment: .leading) {
                  Text(p.title).font(.headline).lineLimit(2)
                  Text("Review change").font(.caption)
                }
                Spacer()
                Image(systemName: "chevron.right")
              }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain)
          }
          Color.clear.frame(height: 1).id("bottom")
        }.padding(16).frame(maxWidth: 800).frame(maxWidth: .infinity)
      }.onChange(of: store.messages.count) {
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    .task { await loadProposals() }
    .sheet(item: $proposal) { ProposalReview(proposal: $0).fullSheet().actionFeedback() }
  }
  /// Says what Buddy is looking at, so "this" and "these" are never a guess.
  private var header: some View {
    HStack(spacing: 8) {
      Group {
        if let document = store.openDocument {
          Label(document.name, systemImage: "doc.text")
        } else if let contextGroup {
          Label(contextGroup.name, systemImage: "folder")
        } else {
          Label("All groups", systemImage: "square.stack.3d.up")
        }
      }.font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        .truncationMode(.middle).accessibilityIdentifier("agent-context")
      Spacer()
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
      }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Buddy actions")
    }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Color.buddyGreen)
      Text("Ask about your paperwork.").font(.system(.title, design: .rounded, weight: .bold))
      Text(
        "I can read your PDFs, add things up, find documents, and create custom charts, statistics, and filters for a group."
      ).foregroundStyle(.secondary)
      Button {
        Haptics.tap()
        store.composerDraft = contextGroup == nil
          ? "Help me create a custom statistics view for one of my groups."
          : "Create a custom statistics view for this group with useful totals and charts."
      } label: {
        Text("Try “Create a statistics view with totals and charts for this group”")
          .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding()
          .background(Color.buddyGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
      }.buttonStyle(.plain)
        .accessibilityHint("Adds a suggested request to your message")
    }.padding(.vertical, 16)
  }
  private var composer: some View {
    @Bindable var store = store
    let text = store.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    return HStack(alignment: .bottom, spacing: 8) {
      TextField("Ask Buddy…", text: $store.composerDraft, axis: .vertical).textFieldStyle(.plain)
        .lineLimit(1...6).padding(10)
      Button {
        store.composerDraft = ""
        Haptics.tap()
        Task { await store.send(text) }
      } label: {
        Image(systemName: "arrow.up").font(.headline).frame(width: 32, height: 32)
      }.buttonStyle(.borderedProminent).clipShape(Circle()).accessibilityLabel("Send")
        .disabled(text.isEmpty || store.sending)
    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
      .padding(.horizontal, 12).padding(.bottom, 10).frame(maxWidth: 840)
  }
  func loadProposals() async {
    if store.isPreview { return }
    do { store.proposals = try await store.fetch([Proposal].self, "proposals") } catch {
      store.error = error.localizedDescription
    }
  }
}
private struct ChatBubble: View {
  let message: ChatMessage
  private var isUser: Bool { message.role == "user" }
  /// Replies use Markdown for emphasis; anything that doesn't parse shows as written.
  private var content: AttributedString {
    (try? AttributedString(
      markdown: message.content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(message.content)
  }
  var body: some View {
    HStack {
      if isUser { Spacer(minLength: 32) }
      VStack(alignment: .leading, spacing: 8) {
        Text(content).textSelection(.enabled)
        if !message.activity.isEmpty {
          DisclosureGroup("Show how I worked this out") {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(Array(message.activity.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 2) {
                  Text(step.tool).font(.caption.weight(.semibold))
                  if let detail = step.detail {
                    Text(detail).font(.caption2.monospaced()).textSelection(.enabled)
                  }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
          }.font(.caption).foregroundStyle(.secondary)
        }
      }.padding(12).background(
        isUser ? Color.buddyGreen.opacity(0.10) : Color.secondary.opacity(0.07),
        in: RoundedRectangle(cornerRadius: 18))
      if !isUser { Spacer(minLength: 16) }
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
          if let groupID = proposal.mutation.object["groupId"]?.stringValue,
            let view = proposal.mutation.object["view"]
          {
            ViewProposalPreview(groupID: groupID, view: view)
          }
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
        if approve, let group = store.selectedGroupID { await store.loadViews(group) }
      })
    {
      dismiss()
    }
  }
}
