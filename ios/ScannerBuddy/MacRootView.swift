#if os(macOS)
  import SwiftUI

  enum MacDestination: Hashable {
    case group(String)
    case buddy
    case account
  }
  struct MacRootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: MacDestination?
    @State private var creating = false
    @State private var query = ""
    var body: some View {
      NavigationSplitView {
        List(selection: $selection) {
          Section("Groups") {
            ForEach(
              store.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            ) { group in
              Label {
                Text(group.name).lineLimit(1)
              } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Color.buddyGreen)
              }.badge(group.documentCount).tag(MacDestination.group(group.id))
            }
          }
          Section("Workspace") {
            Label("Buddy", systemImage: "sparkles").tag(MacDestination.buddy)
            Label("Account", systemImage: "person.crop.circle").tag(MacDestination.account)
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
      }.frame(minWidth: 980, minHeight: 640)
        .task { await store.refresh() }
        .sheet(isPresented: $creating) { GroupEditor().fullSheet().actionFeedback() }
        .sheet(
          isPresented: Binding(
            get: { store.pendingImport != nil }, set: { if !$0 { store.pendingImport = nil } })
        ) { ImportDestinationView().fullSheet().actionFeedback() }
    }
    @ViewBuilder private var detail: some View {
      switch selection {
      case .buddy: ChatView()
      case .account: AccountView()
      case .group(let id):
        if let group = store.groups.first(where: { $0.id == id }) {
          NavigationStack { GroupDetailView(group: group) }.id(group.id)
        } else {
          placeholder
        }
      case nil: placeholder
      }
    }
    @ViewBuilder private var placeholder: some View {
      if store.groups.isEmpty && !store.loading {
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
