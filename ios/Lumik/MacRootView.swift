#if os(macOS)
  import SwiftUI

  enum MacDestination: Hashable {
    case group(String)
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
    var body: some View {
      NavigationSplitView {
        List(selection: $selection) {
          if let inbox = store.inbox, inbox.documentCount > 0 || selection == .group(inbox.id) {
            Section {
              Label("Inbox", systemImage: "tray.full").badge(inbox.documentCount)
                .tag(MacDestination.group(inbox.id))
            }
          }
          Section("Groups") {
            ForEach(store.sidebarGroups(matching: query)) { group in
              Label {
                Text(group.name).lineLimit(1)
              } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Color.buddyGreen)
              }.badge(group.documentCount)
                .contextMenu {
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
          }
          Section("Workspace") {
            Label("Account", systemImage: "person.crop.circle").tag(MacDestination.account)
            Label("Recycle Bin", systemImage: "trash").tag(MacDestination.recycleBin)
          }
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
        .sheet(isPresented: $creating) { GroupEditor().fullSheet().actionFeedback() }
        .sheet(item: $subgroupParent) { parent in
          GroupEditor(parent: parent).fullSheet().actionFeedback()
        }
        .sheet(
          isPresented: Binding(
            get: { store.pendingImport != nil }, set: { if !$0 { store.pendingImport = nil } })
        ) { ImportDestinationView().fullSheet().actionFeedback() }
    }
    @ViewBuilder private var detail: some View {
      switch selection {
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
