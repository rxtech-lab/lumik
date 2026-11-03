import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @Environment(AppStore.self) private var store
  @State private var selection: String?
  @State private var creating = false
  @State private var subgroupParent: ScanGroup?
  @State private var query = ""
  @State private var groupToDelete: ScanGroup?
  @State private var showingRecycleBin = false
  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Text("A home for\nyour paperwork.").font(
              .system(.largeTitle, design: .rounded, weight: .bold))
            Text("Scan it. Sort it. Find it.").foregroundStyle(.secondary)
          }.padding(.vertical, 16).listRowBackground(Color.clear)
        }
        if store.groupTree.isEmpty && (store.inbox?.documentCount ?? 0) == 0 {
          if !store.loading {
            ContentUnavailableView(
              "Start with a group", systemImage: "folder.badge.plus",
              description: Text(
                "Keep receipts, invoices, or forms together. Give each group its own extraction template."
              )
            ).listRowBackground(Color.clear).listRowSeparator(.hidden)
          }
        } else {
          if let inbox = store.inbox, inbox.documentCount > 0 {
            Section {
              NavigationLink(value: inbox.id) {
                Label("Inbox", systemImage: "tray.full").badge(inbox.documentCount)
              }
            }
          }
          Section("Your groups") {
            ForEach(store.sidebarGroups(matching: query)) { group in
              NavigationLink(value: group.id) {
                HStack(spacing: 14) {
                  Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.buddyGreen)
                    .frame(width: 48, height: 48).background(
                      Color.buddyGreen.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.headline)
                    Text(store.groupSummary(group)).font(.caption).foregroundStyle(.secondary)
                  }
                }.padding(.vertical, 5)
              }
              .contextMenu {
                Button("New subgroup", systemImage: "folder.badge.plus") {
                  Haptics.tap()
                  subgroupParent = group
                }
                Button("Delete group", systemImage: "trash", role: .destructive) {
                  Haptics.tap()
                  groupToDelete = group
                }
              }
              .swipeActions(allowsFullSwipe: false) {
                SwipeDeleteButton {
                  Haptics.tap()
                  groupToDelete = group
                }
              }
            }
          }
        }
        Section {
          Button("Recycle Bin", systemImage: "trash") {
            Haptics.tap()
            showingRecycleBin = true
          }
        }
      }.navigationTitle("Library").searchable(text: $query, prompt: "Find a group")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button("New group", systemImage: "folder.badge.plus") {
                Haptics.tap()
                creating = true
              }
              Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            } label: {
              Image(systemName: "plus.circle.fill").font(.title3)
            }.accessibilityLabel("Group actions")
          }
        }
        .refreshable { await store.refresh() }
    } detail: {
      NavigationStack {
        if let group = store.groups.first(where: { $0.id == selection }) {
          GroupDetailView(group: group).id(group.id)
        } else {
          ContentUnavailableView(
            "Everything in its place", systemImage: "tray.2",
            description: Text("Choose a group to browse your documents.")
          ).toolbar { ToolbarItem(placement: .primaryAction) { AgentToolbarButton() } }
        }
      }.agentPanel()
    }.task { await store.refresh() }
      .onChange(of: store.groups) {
        if let selection, !store.groups.contains(where: { $0.id == selection }) {
          self.selection = nil
        }
      }
      .confirmGroupDeletion($groupToDelete)
      .sheet(item: Binding(get: { store.groupSuggestions.first }, set: { value in
        if value == nil && !store.groupSuggestions.isEmpty { store.groupSuggestions.removeFirst() }
      })) { suggestion in
        PDFGroupSuggestionView(suggestion: suggestion).fullSheet().actionFeedback()
      }
      .sheet(isPresented: $showingRecycleBin) {
        RecycleBinView(showsClose: true).fullSheet().actionFeedback()
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
}
struct GroupDetailView: View {
  @State private var importBatch: PDFImportBatch?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let group: ScanGroup
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var editing = false
  @State private var moving: ScanDocument?
  @State private var groupToDelete: ScanGroup?
  @State private var documentToDelete: ScanDocument?
  @State private var renaming: DocumentRename?
  @State private var importing = false
  @State private var scanning = false
  @State private var exportData: ExportFile?
  @State private var exporting = false
  @State private var filter: GroupView?
  private var statistics: [GroupView] { store.views.filter { $0.kind == "statistic" } }
  private var filters: [GroupView] { store.views.filter { $0.kind == "filter" } }
  private var subgroups: [ScanGroup] { store.subgroups(of: group.id) }
  private var subtitle: String {
    let parent = store.groups.first { $0.id == group.parentId }
    return parent.map { "In \($0.name) · \(group.documentCountText)" } ?? group.documentCountText
  }
  private var filterMenu: some View {
    Menu {
      ForEach(filters) { view in
        Button(view.title, systemImage: "line.3.horizontal.decrease") {
          Haptics.tap()
          filter = view
        }
      }
      Button("New filter with Lumik", systemImage: "sparkles") {
        store.askBuddy("Create a filter for this group that lets me choose ")
      }
      if store.documentFilter != nil {
        Divider()
        Button("Show all documents", systemImage: "xmark.circle") {
          Haptics.tap()
          store.documentFilter = nil
        }
      }
    } label: {
      Image(
        systemName: store.documentFilter == nil
          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
    }.accessibilityLabel("Filters")
  }
  @ViewBuilder private func documentActions(_ document: ScanDocument) -> some View {
    Button("Rename", systemImage: "character.cursor.ibeam") {
      Haptics.tap()
      renaming = DocumentRename(document: document)
    }.disabled(document.status == "processing")
    Button("Rename with AI", systemImage: "sparkles") {
      Haptics.tap()
      renaming = DocumentRename(document: document, suggestsName: true)
    }.disabled(document.status == "processing")
    Divider()
    MoveDocumentButtons(store: store, document: document, moving: $moving)
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) {
      Haptics.tap()
      documentToDelete = document
    }
  }
  private func activeFilterRow(_ active: DocumentFilter) -> some View {
    HStack {
      Label(active.title, systemImage: "line.3.horizontal.decrease").lineLimit(1)
      Spacer()
      Text("\(store.visibleDocuments.count) of \(store.documents.count)").font(.caption)
        .foregroundStyle(.secondary)
      Button("Clear filter", systemImage: "xmark.circle.fill") {
        Haptics.tap()
        store.documentFilter = nil
      }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
    }
  }
  private var noMatchingDocuments: some View {
    ContentUnavailableView(
      "No matching documents", systemImage: "line.3.horizontal.decrease.circle",
      description: Text("Try different values, or show all documents from the filter menu."))
  }
  #if os(macOS)
    /// Tiles for what the group offers, then its documents in a sortable table that takes the rest.
    private var content: some View {
      VStack(spacing: 0) {
        MacGroupOverview(
          fieldCount: group.schema.object["properties"]?.object.count ?? 0,
          instructions: group.instructions, statistics: statistics, subgroups: subgroups,
          showsFields: !group.isInbox
        ) {
          editing = true
          Haptics.tap()
        }
        if let active = store.documentFilter {
          activeFilterRow(active).padding(.horizontal, 20).padding(.bottom, 12)
        }
        if store.documents.isEmpty {
          Group {
            if !store.loading {
              ContentUnavailableView(
                "Ready for your first document", systemImage: "doc.viewfinder",
                description: Text("Scan from a connected scanner or import PDFs using the actions menu."))
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleDocuments.isEmpty {
          noMatchingDocuments.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          MacDocumentTable(documents: store.visibleDocuments) { documentActions($0) }
        }
      }
    }
  #else
    private var content: some View {
    List {
      if group.isInbox {
        Section { Text(group.instructions).foregroundStyle(.secondary) }
      } else {
        Section {
          Button {
            editing = true
            Haptics.tap()
          } label: {
            HStack {
              Label {
                Text("Extraction fields")
              } icon: {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.buddyGreen)
              }
              Spacer()
              Text((group.schema.object["properties"]?.object.count ?? 0).formatted())
                .foregroundStyle(.secondary)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityHint("Edit group")
        } footer: {
          if !group.instructions.isEmpty {
            Text(group.instructions).lineLimit(3)
          }
        }
      }
      if !subgroups.isEmpty {
        Section("Subgroups") {
          ForEach(subgroups) { subgroup in
            NavigationLink {
              GroupDetailView(group: subgroup)
            } label: {
              LabeledContent {
                Text(subgroup.documentCount.formatted())
              } label: {
                Label {
                  Text(subgroup.name)
                } icon: {
                  Image(systemName: "folder.fill").foregroundStyle(Color.buddyGreen)
                }
              }
            }
          }
        }
      }
      if !statistics.isEmpty {
        Section("Statistics") {
          ForEach(statistics) { view in
            NavigationLink {
              StatisticDetailView(view: view)
            } label: {
              Label(view.title, systemImage: "chart.bar.xaxis")
            }
          }
        }
      }
      if let active = store.documentFilter {
        Section { activeFilterRow(active) }
      }
      if store.documents.isEmpty {
        if !store.loading {
          ContentUnavailableView(
            "Ready for your first document", systemImage: "doc.viewfinder",
            description: Text("Scan multiple pages or import an existing PDF using the actions menu.")
          ).frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
      } else if store.visibleDocuments.isEmpty {
        noMatchingDocuments.frame(maxWidth: .infinity).listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      } else {
        Section("Documents") {
          ForEach(store.visibleDocuments) { document in
            NavigationLink {
              DocumentDetailView(document: document)
            } label: {
              DocumentRow(document: document)
            }
            .contextMenu { documentActions(document) }
            .swipeActions(allowsFullSwipe: false) {
              SwipeDeleteButton {
                Haptics.tap()
                documentToDelete = document
              }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    }
  #endif
  var body: some View {
    ZStack {
      if store.loading {
        ResourceLoadingView(title: "Loading documents", subtitle: "Getting your library ready…")
          .transition(.opacity)
      } else {
        content.transition(.opacity)
      }
    }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.loading)
      .navigationTitle(group.name)
      .navigationSubtitle(subtitle)
      .toolbar {
        ToolbarItem(placement: .primaryAction) { AgentToolbarButton() }
        ToolbarItem(placement: .primaryAction) { filterMenu }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            #if os(iOS)
              Button("Scan document", systemImage: "doc.viewfinder") {
                Haptics.tap()
                scanning = true
              }
            #else
              Button("Scan from Scanner", systemImage: "scanner") { scanning = true }
            #endif
            Button("Import PDF", systemImage: "doc.badge.plus") {
              Haptics.tap()
              importing = true
            }
            Divider()
            Button("Organize with Lumik", systemImage: "sparkles") {
              store.askBuddy(
                group.isInbox
                  ? "Organize the documents in my Inbox."
                  : "Organize the documents in this group into subgroups.")
            }
            if !group.isInbox {
              Button("Edit group", systemImage: "slider.horizontal.3") {
                editing = true
                Haptics.tap()
              }
            }
            Button("Export ZIP", systemImage: "square.and.arrow.up") {
              Task {
                await store.perform("Preparing your archive…", success: "Archive ready") {
                  let data = try await store.request("groups/\(group.id)/export")
                  exportData = ExportFile(data: data, type: .zip)
                  exporting = true
                }
              }
            }
            #if os(macOS)
              Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.loadDocuments(group.id) }
              }
            #endif
            if !group.isInbox {
              Button("Delete group", systemImage: "trash", role: .destructive) {
                groupToDelete = group
                Haptics.tap()
              }
            }
          } label: {
            Image(systemName: "ellipsis")
          }.menuIndicator(.hidden).accessibilityLabel("Document actions")
        }
      }.task {
        await store.loadDocuments(group.id)
        await store.loadViews(group.id)
      }.refreshable {
        await store.loadDocuments(group.id)
        await store.loadViews(group.id)
      }
      .sheet(item: $filter) { FilterSheet(view: $0).fullSheet().actionFeedback() }
      .sheet(isPresented: $editing) { GroupEditor(group: group).fullSheet().actionFeedback() }
      .sheet(item: $moving) { MoveDocumentView(document: $0).fullSheet().actionFeedback() }
      // A subgroup opened from its parent has to leave when it is deleted.
      .onChange(of: store.groups) {
        if !store.groups.contains(where: { $0.id == group.id }) { dismiss() }
      }
      .confirmGroupDeletion($groupToDelete)
      .sheet(item: $renaming) { RenameDocumentView(request: $0).fullSheet().actionFeedback() }
      .sheet(item: $documentToDelete) { document in
        DeleteView(
          title: document.name, message: "This permanently removes the PDF and its extracted data."
        ) {
          try await store.deleteDocument(document)
        }.fullSheet().actionFeedback()
      }
      .sheet(item: $importBatch) { batch in
        PDFImportOptions(urls: batch.urls) {
          await store.perform("Processing and uploading PDFs…", success: "PDFs saved") {
            for url in batch.urls {
              let access = url.startAccessingSecurityScopedResource()
              defer { if access { url.stopAccessingSecurityScopedResource() } }
              try await store.upload(Data(contentsOf: url), name: url.lastPathComponent, groupID: group.id)
            }
          }
        }.fullSheet()
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
        switch result {
        case .success(let urls): importBatch = PDFImportBatch(urls: urls)
        case .failure(let error): if !isSilentCancellation(error) { store.error = error.localizedDescription }
        }
      }
      .fileExporter(
        isPresented: $exporting, document: exportData, contentType: .zip,
        defaultFilename: group.name
      ) { result in
        if case .failure(let error) = result { if !isSilentCancellation(error) { store.error = error.localizedDescription } }
      }
      #if os(macOS)
        .sheet(isPresented: $scanning) {
          DesktopScanView(group: group).fullSheet()
        }
      #else
        .sheet(isPresented: $scanning) {
          ScanCaptureView(group: group)
        }
      #endif
  }
}
/// A destructive role would animate the row away before the user has confirmed.
struct SwipeDeleteButton: View {
  let action: () -> Void
  var body: some View {
    Button("Delete", systemImage: "trash", action: action).tint(.red)
  }
}
private struct GroupDeletionConfirmation: ViewModifier {
  @Binding var group: ScanGroup?
  @Environment(AppStore.self) private var store
  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Move “\(group?.name ?? "")” to the Recycle Bin?",
      isPresented: Binding(get: { group != nil }, set: { if !$0 { group = nil } }),
      titleVisibility: .visible, presenting: group
    ) { group in
      Button("Move to Recycle Bin", role: .destructive) {
        Task {
          await store.perform("Moving to Recycle Bin…", success: "Moved to Recycle Bin") {
            try await store.deleteGroup(group)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { group in
      Text(
        store.subgroups(of: group.id).isEmpty
          ? "You can restore it for 30 days. After that, the group and all its PDFs are permanently deleted."
          : "Its subgroups move with it. You can restore them for 30 days. After that, they and all their PDFs are permanently deleted."
      )
    }
  }
}
extension View {
  func confirmGroupDeletion(_ group: Binding<ScanGroup?>) -> some View {
    modifier(GroupDeletionConfirmation(group: group))
  }
}
struct RecycleBinView: View {
  var showsClose = false
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var loaded = false
  @State private var groupToPurge: DeletedGroup?
  var body: some View {
    NavigationStack {
      List {
        if !store.deletedGroups.isEmpty {
          Section {
            ForEach(store.deletedGroups) { group in
              row(group)
                .contextMenu {
                  Button("Restore", systemImage: "arrow.uturn.backward") { restore(group) }
                  Divider()
                  Button("Delete permanently", systemImage: "trash", role: .destructive) {
                    Haptics.tap()
                    groupToPurge = group
                  }
                }
                .swipeActions(allowsFullSwipe: false) {
                  SwipeDeleteButton {
                    Haptics.tap()
                    groupToPurge = group
                  }
                }
            }
          } footer: {
            Text("Groups are permanently deleted 30 days after they’re moved here.")
          }
        }
      }
      #if os(iOS)
        .listStyle(.insetGrouped)
      #else
        .listStyle(.inset)
      #endif
      .overlay {
        if store.deletedGroups.isEmpty {
          if loaded {
            ContentUnavailableView(
              "Recycle Bin is empty", systemImage: "trash",
              description: Text("Deleted groups stay here for 30 days."))
          } else {
            ProgressView()
          }
        }
      }
      .navigationTitle("Recycle Bin")
      .toolbar {
        if showsClose {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
          }
        }
      }
      .task {
        await store.loadDeletedGroups()
        loaded = true
      }
      .refreshable { await store.loadDeletedGroups() }
      .confirmationDialog(
        "Permanently delete “\(groupToPurge?.name ?? "")”?",
        isPresented: Binding(get: { groupToPurge != nil }, set: { if !$0 { groupToPurge = nil } }),
        titleVisibility: .visible, presenting: groupToPurge
      ) { group in
        Button("Delete permanently", role: .destructive) {
          Task {
            await store.perform("Deleting…", success: "Deleted") { try await store.purgeGroup(group) }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("This deletes the group and all its PDFs. This can’t be undone.")
      }
    }
  }
  private func row(_ group: DeletedGroup) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.fill").font(.title3).foregroundStyle(.secondary)
        .frame(width: 40, height: 40)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name).lineLimit(2)
        Text(
          "\(group.documentCount == 1 ? "1 document" : "\(group.documentCount) documents") · \(group.daysLeft == 1 ? "1 day left" : "\(group.daysLeft) days left")"
        ).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Restore") { restore(group) }.buttonStyle(.bordered)
    }.padding(.vertical, 2)
  }
  private func restore(_ group: DeletedGroup) {
    Task {
      await store.perform("Restoring…", success: "Restored \(group.name)") {
        try await store.restoreGroup(group)
      }
    }
  }
}
/// Quiet when a PDF is ready; its status only takes over the second line when it needs attention.
private struct DocumentRow: View {
  let document: ScanDocument
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(Color.buddyGreen)
        .frame(width: 40, height: 40)
        .background(
          Color.buddyGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(document.name).lineLimit(2).truncationMode(.middle)
        Group {
          switch document.status {
          case "ready":
            Text("\(document.addedDayText) · \(document.sizeText)").foregroundStyle(.secondary)
          case "processing":
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("Reading…").foregroundStyle(.secondary)
            }
          default:
            Label(document.statusText, systemImage: document.statusIcon)
              .foregroundStyle(document.statusColor)
          }
        }.font(.subheadline)
      }
    }.padding(.vertical, 2)
  }
}
struct DeleteView: View {
  let title: String
  let message: String
  let action: () async throws -> Void
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var confirming = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer()
        Image(systemName: "trash").font(.system(size: 48)).foregroundStyle(.red)
        Text("Delete \(title)?").font(.title2.bold()).multilineTextAlignment(.center)
        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Spacer()
      }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Delete").toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          #if os(macOS)
            ToolbarItem(placement: .confirmationAction) { deleteButton }
          #else
            ToolbarItem(placement: .bottomBar) { deleteButton }
          #endif
        }
        .confirmationDialog(
          "This cannot be undone.", isPresented: $confirming, titleVisibility: .visible
        ) {
          Button("Delete permanently", role: .destructive) {
            Task { if await store.perform("Deleting…", success: "Deleted", action) { dismiss() } }
          }
        }
    }
  }

  private var deleteButton: some View {
    Button("Delete permanently", role: .destructive) {
      Haptics.tap()
      confirming = true
    }.buttonStyle(.borderedProminent).tint(.red)
  }
}
struct ImportDestinationView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        PDFProcessingPicker()
        ForEach(store.groupTree) { row in
        let group = row.group
        Button {
          Task {
            guard let url = store.pendingImport else { return }
            if await store.perform(
              "Importing PDF…", success: "Imported. Reading your PDF…",
              {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.upload(
                  Data(contentsOf: url), name: url.lastPathComponent, groupID: group.id)
              })
            {
              store.pendingImport = nil
              dismiss()
            }
          }
        } label: {
          Text(group.name).padding(.leading, CGFloat(min(row.depth, 6)) * 18)
        }
        }
      }.overlay {
        if store.groupTree.isEmpty {
          ContentUnavailableView(
            "Create a group first", systemImage: "folder.badge.plus",
            description: Text("Close this sheet, create a group, then open your PDF again."))
        }
      }.navigationTitle("Import into group").toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.pendingImport = nil
            dismiss()
          }
        }
      }
    }
  }
}
struct ExportFile: FileDocument {
  static var readableContentTypes: [UTType] { [.zip, .pdf] }
  var data: Data
  var type: UTType
  init(data: Data, type: UTType) {
    self.data = data
    self.type = type
  }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
    type = configuration.contentType
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct PDFGroupSuggestion: Identifiable {
  var id: String { document.id }
  let document: ScanDocument
  let group: ScanGroup
  let reason: String
}

struct PDFGroupSuggestionView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let suggestion: PDFGroupSuggestion
  @State private var saving = false
  private var destination: String {
    var names = [suggestion.group.name]
    var parent = suggestion.group.parentId
    var visited = Set([suggestion.group.id])
    while let id = parent, visited.insert(id).inserted,
      let group = store.groups.first(where: { $0.id == id }) {
      names.insert(group.name, at: 0)
      parent = group.parentId
    }
    return names.joined(separator: " / ")
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Suggested destination") {
          LabeledContent("PDF", value: suggestion.document.name)
          LabeledContent("Group", value: destination)
          Text(suggestion.reason).foregroundStyle(.secondary)
        }
        if !store.movePreservesDetails(suggestion.document, to: suggestion.group) {
          Text("Moving will extract the destination group's fields and update the filename.")
        }
      }
      .navigationTitle("Move to a better match?")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Skip") { Haptics.tap(); dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Confirm") {
            Haptics.tap()
            saving = true
            Task {
              let success = await store.perform("Moving PDF…", success: "PDF moved") {
                try await store.moveDocument(suggestion.document, to: suggestion.group.id)
              }
              saving = false
              if success { dismiss() }
            }
          }.disabled(saving)
        }
      }
    }.interactiveDismissDisabled(saving)
  }
}
