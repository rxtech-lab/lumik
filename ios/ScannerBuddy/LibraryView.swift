import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @Environment(AppStore.self) private var store
  @State private var selection: String?
  @State private var creating = false
  @State private var query = ""
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
        if store.groups.isEmpty {
          if !store.loading {
            ContentUnavailableView(
              "Start with a group", systemImage: "folder.badge.plus",
              description: Text(
                "Keep receipts, invoices, or forms together. Give each group its own extraction template."
              )
            ).listRowBackground(Color.clear).listRowSeparator(.hidden)
          }
        } else {
          Section("Your groups") {
            ForEach(
              store.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            ) { group in
              NavigationLink(value: group.id) {
                HStack(spacing: 14) {
                  Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.buddyGreen)
                    .frame(width: 48, height: 48).background(
                      Color.buddyGreen.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.headline)
                    Text(
                      "\(group.documentCount) documents · \(group.schema.object["properties"]?.object.count ?? 0) fields"
                    ).font(.caption).foregroundStyle(.secondary)
                  }
                }.padding(.vertical, 5)
              }
            }
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
      if let group = store.groups.first(where: { $0.id == selection }) {
        GroupDetailView(group: group).id(group.id)
      } else {
        ContentUnavailableView(
          "Everything in its place", systemImage: "tray.2",
          description: Text("Choose a group to browse your documents."))
      }
    }.task { await store.refresh() }
      .sheet(isPresented: $creating) { GroupEditor().fullSheet().actionFeedback() }
      .sheet(
        isPresented: Binding(
          get: { store.pendingImport != nil }, set: { if !$0 { store.pendingImport = nil } })
      ) { ImportDestinationView().fullSheet().actionFeedback() }
  }
}
struct GroupDetailView: View {
  let group: ScanGroup
  @Environment(AppStore.self) private var store
  @State private var editing = false
  @State private var deleting = false
  @State private var importing = false
  @State private var scanning = false
  @State private var exportData: ExportFile?
  @State private var exporting = false
  @State private var showHP = false
  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Label(
            "\(group.schema.object["properties"]?.object.count ?? 0) extraction fields",
            systemImage: "list.bullet.rectangle"
          ).font(.subheadline.weight(.medium)).foregroundStyle(Color.buddyGreen)
          if !group.instructions.isEmpty {
            Text(group.instructions).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
          }
        }.padding(.vertical, 8)
      }
      Section("Documents") {
        ForEach(store.documents) { document in
          NavigationLink {
            DocumentDetailView(document: document)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.richtext").font(.title).foregroundStyle(Color.buddyGreen)
              VStack(alignment: .leading, spacing: 5) {
                Text(document.name).lineLimit(2)
                Text(document.status.capitalized).font(.caption).foregroundStyle(
                  document.status == "failed" ? .red : .secondary)
              }
              Spacer()
              Text(
                ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file)
              ).font(.caption2).foregroundStyle(.tertiary)
            }.padding(.vertical, 6)
          }
        }
        if store.documents.isEmpty && !store.loading {
          #if os(iOS)
            ContentUnavailableView(
              "Ready for your first document", systemImage: "doc.viewfinder",
              description: Text("Scan multiple pages or import an existing PDF using the add menu.")
            ).frame(maxWidth: .infinity)
          #else
            ContentUnavailableView(
              "Ready for your first document", systemImage: "doc.viewfinder",
              description: Text("Import an existing PDF using the actions menu.")
            ).frame(maxWidth: .infinity)
          #endif
        }
      }
    }.navigationTitle(group.name)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            #if os(iOS)
              Button("Scan document", systemImage: "doc.viewfinder") {
                Haptics.tap()
                scanning = true
              }
            #endif
            Button("Import PDF", systemImage: "doc.badge.plus") {
              Haptics.tap()
              importing = true
            }
            Button("Import from HP", systemImage: "printer") {
              Haptics.tap()
              showHP = true
            }
            Divider()
            Button("Edit group", systemImage: "slider.horizontal.3") {
              editing = true
              Haptics.tap()
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
            Button("Delete group", systemImage: "trash", role: .destructive) {
              deleting = true
              Haptics.tap()
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }.task { await store.loadDocuments(group.id) }.refreshable {
        await store.loadDocuments(group.id)
      }
      .sheet(isPresented: $editing) { GroupEditor(group: group).fullSheet().actionFeedback() }
      .sheet(isPresented: $deleting) {
        DeleteView(
          title: group.name, message: "This deletes the group and all its PDFs from your account."
        ) {
          _ = try await store.request("groups/\(group.id)", method: "DELETE")
          await store.refresh()
        }.fullSheet().actionFeedback()
      }
      .sheet(isPresented: $showHP) {
        HPImportView {
          showHP = false
          importing = true
        }.fullSheet()
      }
      .fileImporter(
        isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true
      ) { result in
        Task {
          await store.perform("Uploading your PDFs…", success: "Uploaded. Reading your PDFs…") {
            for url in try result.get() {
              let access = url.startAccessingSecurityScopedResource()
              defer { if access { url.stopAccessingSecurityScopedResource() } }
              try await store.upload(
                Data(contentsOf: url), name: url.lastPathComponent, groupID: group.id)
            }
          }
        }
      }
      .fileExporter(
        isPresented: $exporting, document: exportData, contentType: .zip,
        defaultFilename: group.name
      ) { result in
        if case .failure(let error) = result { store.error = error.localizedDescription }
      }
      #if os(iOS)
        .sheet(isPresented: $scanning) {
          ScanCaptureView { result in
            scanning = false
            switch result {
            case .success(let data):
              Task {
                await store.perform("Uploading your scan…", success: "Uploaded. Reading your scan…") {
                  try await store.upload(data, name: "Scan.pdf", groupID: group.id)
                }
              }
            case .failure(let error): store.error = error.localizedDescription
            }
          }.ignoresSafeArea()
        }
      #endif
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
        Button("Delete permanently", role: .destructive) {
          Haptics.tap()
          confirming = true
        }.buttonStyle(.borderedProminent).tint(.red)
        Spacer()
      }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Delete").toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
}
struct HPImportView: View {
  let choose: () -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "printer.fill").font(.system(size: 48)).foregroundStyle(Color.buddyGreen)
        Text("From scanner to sorted.").font(.largeTitle.bold())
        Text(
          "Scan your pages with the HP app, save them as a single PDF to Files, then import that PDF here. You can also use Open in Scanner Buddy from another app."
        )
        Text(
          "Direct HP device control is not connected. PDF import works with any scanner that exports PDF."
        ).font(.footnote).foregroundStyle(.secondary)
        Button("Choose PDF", action: choose).buttonStyle(.borderedProminent)
        Spacer()
      }.padding(32).navigationTitle("HP scanner").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      }
    }
  }
}
struct ImportDestinationView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List(store.groups) { group in
        Button(group.name) {
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
        }
      }.overlay {
        if store.groups.isEmpty {
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
