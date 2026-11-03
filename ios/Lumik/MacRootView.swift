#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  enum MacDestination: Hashable {
    case group(String)
    case signing
    case account
    case recycleBin
  }
  struct MacRootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: MacDestination?
    @State private var creating = false
    @State private var subgroupParent: ScanGroup?
    @State private var query = ""
    @State private var groupToDelete: ScanGroup?
    @State private var scanGroup: ScanGroup?
    @State private var uploadGroup: ScanGroup?
    @State private var importing = false
    @State private var importBatch: PDFImportBatch?
    private func groupRow(_ row: GroupTreeRow) -> some View {
      let group = row.group
      return Label {
        Text(group.name).lineLimit(1)
      } icon: {
        Image(systemName: "folder.fill").foregroundStyle(Color.buddyGreen)
      }.badge(group.documentCount)
        .padding(.leading, CGFloat(row.depth) * 16)
        .draggable("lumik-group:" + group.id)
        .dropDestination(for: String.self) { items, _ in move(items, to: group.id) }
        .contextMenu {
          Button("New group", systemImage: "folder.badge.plus") { creating = true }
          Button("Upload form / PDF", systemImage: "square.and.arrow.up") {
            uploadGroup = group
            importing = true
          }
          Button("Scan form", systemImage: "scanner") { scanGroup = group }
          if group.parentId != nil {
            Button("Move to top level", systemImage: "arrow.uturn.backward") {
              _ = move(["lumik-group:" + group.id], to: nil)
            }
          }
          Divider()
          Button("New subgroup", systemImage: "folder.badge.plus") {
            Haptics.tap()
            subgroupParent = group
          }
          Button("Delete group", systemImage: "trash", role: .destructive) {
            groupToDelete = group
          }
        }
        .tag(MacDestination.group(group.id))
    }
    private var pendingSigningCount: Int { store.signingRequests.filter { $0.isPending }.count }
    private var filteredGroups: [GroupTreeRow] {
      store.groupTree.filter { query.isEmpty || $0.group.name.localizedCaseInsensitiveContains(query) }
    }
    private var groupsSection: some View {
      Section("Groups") {
        Label("Top-level groups", systemImage: "folder")
          .dropDestination(for: String.self) { items, _ in move(items, to: nil) }
        ForEach(filteredGroups) { row in
          groupRow(row)
        }
      }
    }
    var body: some View {
      NavigationSplitView {
        List(selection: $selection) {
          if let inbox = store.inbox, inbox.documentCount > 0 || selection == .group(inbox.id) {
            Section {
              Label("Inbox", systemImage: "tray.full").badge(inbox.documentCount)
                .tag(MacDestination.group(inbox.id))
            }
          }
          groupsSection
          Section("Workspace") {
            Label("Signing", systemImage: "signature")
              .badge(pendingSigningCount)
              .tag(MacDestination.signing)
            Label("Account", systemImage: "person.crop.circle").tag(MacDestination.account)
            Label("Recycle Bin", systemImage: "trash").tag(MacDestination.recycleBin)
          }
        }.contextMenu {
          Button("New group", systemImage: "folder.badge.plus") { creating = true }
        }.navigationTitle("Library")
          .searchable(text: $query, placement: .sidebar, prompt: "Find a group")
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Menu {
                Button("New group", systemImage: "folder.badge.plus") { creating = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
              } label: {
                Image(systemName: "plus.circle.fill")
              }.accessibilityLabel("Group actions")
            }
          }
          .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 460)
      } detail: {
        detail
      }.agentPanel()
        .frame(minWidth: 1180, minHeight: 640)
        .task { await store.refresh() }
        .onChange(of: store.groups) {
          if case .group(let id) = selection, !store.groups.contains(where: { $0.id == id }) {
            selection = nil
          }
        }
        .confirmGroupDeletion($groupToDelete)
        .sheet(item: $scanGroup) { DesktopScanView(group: $0).fullSheet().actionFeedback() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
          switch result {
          case .success(let urls): importBatch = PDFImportBatch(urls: urls)
          case .failure(let error): if !isSilentCancellation(error) { store.error = error.localizedDescription }
          }
        }
        .sheet(item: $importBatch) { batch in
          PDFImportOptions(urls: batch.urls) {
            guard let group = uploadGroup else { return false }
            return await store.perform("Uploading PDFs…", success: "PDFs saved") {
              for url in batch.urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.upload(Data(contentsOf: url), name: url.lastPathComponent, groupID: group.id)
              }
            }
          }.fullSheet().actionFeedback()
        }
        .sheet(isPresented: $creating) { GroupEditor().fullSheet().actionFeedback() }
        .sheet(item: $subgroupParent) { parent in
          GroupEditor(parent: parent).fullSheet().actionFeedback()
        }
        .sheet(
          isPresented: Binding(
            get: { store.pendingImport != nil }, set: { if !$0 { store.pendingImport = nil } })
        ) { ImportDestinationView().fullSheet().actionFeedback() }
    }
    private func move(_ items: [String], to parentID: String?) -> Bool {
      guard items.count == 1, let payload = items.first, payload.hasPrefix("lumik-group:") else { return false }
      let id = String(payload.dropFirst("lumik-group:".count))
      guard let group = store.groups.first(where: { $0.id == id }), !group.isInbox,
        group.parentId != parentID else { return false }
      var ancestor = parentID
      var visited = Set<String>()
      while let current = ancestor {
        guard current != id, visited.insert(current).inserted,
          let parent = store.groups.first(where: { $0.id == current }), !parent.isInbox else { return false }
        ancestor = parent.parentId
      }
      Task {
        await store.perform("Moving group…", success: "Group moved") {
          let body = try JSONSerialization.data(withJSONObject: ["parentId": parentID as Any? ?? NSNull()])
          let _: ScanGroup = try await store.fetch(ScanGroup.self, "groups/\(id)/move", method: "POST", body: body)
          await store.refresh()
        }
      }
      return true
    }
    @ViewBuilder private var detail: some View {
      switch selection {
      case .signing: NavigationStack { SigningRequestsView() }
      case .account: AccountView()
      case .recycleBin: RecycleBinView()
      case .group(let id):
        if let group = store.groups.first(where: { $0.id == id }) {
          NavigationStack { GroupDetailView(group: group) }.id(group.id)
        } else {
          NavigationStack { placeholder }
        }
      case nil: NavigationStack { placeholder }
      }
    }
    private var placeholder: some View {
      placeholderContent.toolbar { ToolbarItem(placement: .primaryAction) { AgentToolbarButton() } }
    }
    @ViewBuilder private var placeholderContent: some View {
      if store.groupTree.isEmpty && !store.loading {
        ContentUnavailableView(
          "Start with a group", systemImage: "folder.badge.plus",
          description: Text(
            "Keep receipts, invoices, or forms together. Give each group its own extraction template."
          ))
      } else {
        ContentUnavailableView(
          "Everything in its place", systemImage: "tray.2",
          description: Text("Choose a group to browse your documents."))
      }
    }
  }
#endif
