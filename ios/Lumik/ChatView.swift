import SwiftUI
import UniformTypeIdentifiers

/// Lumik as its own screen: the iPhone tab and the sheet opened from a group or PDF.
struct ChatView: View {
  var body: some View {
    NavigationStack {
      ChatThread().navigationTitle("Lumik")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
/// The conversation. Screens and the right-hand panel all show this same thread.
struct ChatThread: View {
  @State private var importBatch: PDFImportBatch?
  @Environment(AppStore.self) private var store
  @State private var proposal: Proposal?
  @State private var scanInbox: ScanGroup?
  @State private var preparingScan = false
  @State private var importingPDFs = false
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
              Text("Lumik is working…").font(.callout).foregroundStyle(.secondary)
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
        }.padding(16).padding(.top, 28).frame(maxWidth: 800).frame(maxWidth: .infinity)
      }.onChange(of: store.messages.count) {
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
    .overlay(alignment: .topTrailing) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    .task {
      await store.loadChatHistory()
      await loadProposals()
    }
    .sheet(item: $proposal) { ProposalReview(proposal: $0).fullSheet().actionFeedback() }
    .sheet(item: $scanInbox) { inbox in
      #if os(macOS)
        DesktopScanView(group: inbox) { store.attachScan($0) }.fullSheet()
      #else
        ScanCaptureView(group: inbox) { store.attachScan($0) }
      #endif
    }
    .sheet(item: $importBatch) { batch in
      PDFImportOptions(urls: batch.urls) { await importPDFs(.success(batch.urls)) }.fullSheet()
    }
    .fileImporter(
      isPresented: $importingPDFs, allowedContentTypes: [.pdf], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): importBatch = PDFImportBatch(urls: urls)
      case .failure(let error): if !isSilentCancellation(error) { store.error = error.localizedDescription }
      }
    }
  }
  private var header: some View {
    HStack(spacing: 8) {
      Spacer()
      Menu {
        Button("New conversation", systemImage: "square.and.pencil") {
          store.startNewConversation()
          Haptics.tap()
        }
        Button("Refresh pending changes", systemImage: "arrow.clockwise") {
          Task { await loadProposals() }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 32, height: 32)
          .contentShape(Circle())
      }
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .fixedSize()
      .accessibilityLabel("Lumik actions")
    }.padding(.horizontal, 8).padding(.vertical, 4)
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Color.buddyGreen)
      Text("Ask about your paperwork.").font(.system(.title, design: .rounded, weight: .bold))
      Text(
        "I can read your PDFs, add things up, find documents, file new scans into groups, and create custom charts, statistics, and filters for a group."
      ).foregroundStyle(.secondary)
      Button {
        Haptics.tap()
        store.composerDraft = store.contextGroup == nil
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
    let hasScans = !store.chatAttachments.isEmpty
    return VStack(alignment: .leading, spacing: 6) {
      ChatContextBar()
      if hasScans {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(store.chatAttachments) { ScanAttachmentChip(document: $0) }
          }.padding(.horizontal, 4)
        }.scrollIndicators(.hidden)
      }
      HStack(alignment: .bottom, spacing: 8) {
        Menu {
          #if os(iOS)
            Button("Scan document", systemImage: "doc.viewfinder") {
              Task { await openScanner() }
            }
          #else
            Button("Scan from Scanner", systemImage: "scanner") {
              Task { await openScanner() }
            }
          #endif
          Button("Import PDF", systemImage: "doc.badge.plus") {
            Haptics.tap()
            importingPDFs = true
          }
          Divider()
          Menu("Add group", systemImage: "folder.badge.plus") {
            ForEach(store.addableContextGroups) { candidate in
              Button(store.groupPath(candidate)) {
                Haptics.tap()
                store.addContextGroup(candidate)
              }
            }
          }.disabled(store.addableContextGroups.isEmpty)
        } label: {
          Group {
            if preparingScan {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "plus").font(.title3)
            }
          }.frame(width: 32, height: 32).contentShape(Rectangle())
        }.menuIndicator(.hidden).fixedSize().buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel("Add to chat")
          .accessibilityHint("Scan or import PDFs, or add a group")
          .disabled(preparingScan || store.sending)
        TextField(
          hasScans ? "Organize these PDFs" : "Ask Lumik…", text: $store.composerDraft, axis: .vertical
        ).textFieldStyle(.plain).lineLimit(1...6).padding(.vertical, 6)
        Button {
          store.composerDraft = ""
          Haptics.tap()
          Task { await store.send(text.isEmpty ? "Organize these PDFs." : text) }
        } label: {
          Image(systemName: "arrow.up").font(.headline).frame(width: 32, height: 32)
        }.buttonStyle(.borderedProminent).clipShape(Circle()).accessibilityLabel("Send")
          .disabled((text.isEmpty && !hasScans) || store.sending || store.readingAttachments)
      }
    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
      .padding(.horizontal, 12).padding(.bottom, 10).frame(maxWidth: 840)
  }
  /// Imported PDFs wait in the Inbox like scans, so Lumik can file them the same way.
  private func importPDFs(_ result: Result<[URL], Error>) async -> Bool {
    await store.perform("Uploading your PDFs…", success: "Uploaded. Reading your PDFs…") {
      let urls = try result.get()
      if urls.isEmpty { return }
      let inbox = try await store.prepareInbox()
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        store.attachScan(
          try await store.upload(
            Data(contentsOf: url), name: url.lastPathComponent, groupID: inbox.id))
      }
    }
  }
  private func openScanner() async {
    Haptics.tap()
    preparingScan = true
    defer { preparingScan = false }
    do {
      scanInbox = try await store.prepareInbox()
    } catch {
      if !isSilentCancellation(error) { store.error = error.localizedDescription; Haptics.failure() }
    }
  }
  func loadProposals() async {
    if store.isPreview { return }
    do { store.proposals = try await store.fetch([Proposal].self, "proposals") } catch {
      if !isSilentCancellation(error) { store.error = error.localizedDescription }
    }
  }
}
/// Says what Lumik is working on, so "this" and "these" are never a guess. The open group and PDF
/// join on their own; either can be removed, and the composer's add menu brings in more groups.
private struct ChatContextBar: View {
  @Environment(AppStore.self) private var store
  var body: some View {
    let document = store.contextDocument
    let group = store.contextGroup
    let extras = store.extraContextGroups
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        if let document {
          ContextChip(title: document.name, icon: "doc.text", isPrimary: true) {
            store.dismissedContextDocumentID = document.id
          }
        }
        if let group {
          ContextChip(
            title: group.name, icon: group.isInbox ? "tray.full" : "folder", isPrimary: document == nil
          ) { store.removeContextGroup(group) }
        }
        ForEach(extras) { extra in
          ContextChip(title: extra.name, icon: "folder") { store.removeContextGroup(extra) }
        }
        if document == nil && group == nil && extras.isEmpty {
          Label("All groups", systemImage: "square.stack.3d.up").font(.caption.weight(.medium))
            .foregroundStyle(.secondary).padding(.horizontal, 4)
            .accessibilityIdentifier("agent-context")
        }
      }.padding(.horizontal, 4)
    }.scrollIndicators(.hidden)
  }
}
private struct ContextChip: View {
  let title: String
  let icon: String
  /// Marks the chip that says what the chat is mainly about.
  var isPrimary = false
  let remove: () -> Void
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
      Group {
        if isPrimary {
          Text(title).accessibilityIdentifier("agent-context")
        } else {
          Text(title)
        }
      }.lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading).fixedSize()
      Button("Remove \(title) from this chat", systemImage: "xmark.circle.fill") {
        Haptics.tap()
        remove()
      }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
    }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.buddyGreen.opacity(0.12), in: Capsule())
  }
}
/// A scanned or imported PDF on its way to Lumik. Removing it only takes it off this message; it stays in the Inbox.
private struct ScanAttachmentChip: View {
  let document: ScanDocument
  @Environment(AppStore.self) private var store
  var body: some View {
    HStack(spacing: 6) {
      if document.status == "processing" {
        ProgressView().controlSize(.mini)
        Text("Reading…")
      } else {
        Image(systemName: document.status == "failed" ? "exclamationmark.triangle" : "doc.text")
        Text(document.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
      }
      Button("Remove PDF", systemImage: "xmark.circle.fill") {
        Haptics.tap()
        store.removeAttachment(document)
      }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
      .background(.quaternary, in: Capsule())
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
          if let review = proposal.mutation.object["review"] {
            OrganizeProposalPreview(review: review)
          } else {
            Text(proposal.mutation.pretty).font(.callout.monospaced()).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
          }
        }.padding(24)
      }.navigationTitle("Review change").toolbar {
        #if !os(macOS)
          ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        #endif
        ToolbarItem(placement: .destructiveAction) {
          Button("Reject", role: .destructive) {
            Haptics.tap()
            Task { await resolve(false) }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            Haptics.tap()
            confirm = true
          }
        }
      }
      .confirmationDialog("Apply this change?", isPresented: $confirm, titleVisibility: .visible) {
        Button(
          "Apply change",
          role: proposal.mutation.object["action"]?.string.hasPrefix("delete") == true
            ? .destructive : nil
        ) { Task { await resolve(true) } }
      }
    }
    #if os(macOS)
      // macOS sheets put a cancellation item in the bottom bar and don't show a navigation item.
      .overlay(alignment: .topTrailing) {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).padding(.top, 10)
          .padding(.trailing, 14)
      }
    #endif
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
        if approve, let group = store.selectedGroupID {
          await store.loadViews(group)
          await store.loadDocuments(group)
        }
      })
    {
      dismiss()
    }
  }
}
