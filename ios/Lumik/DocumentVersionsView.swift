import SwiftUI

enum VersionAction: Hashable, Identifiable {
  case upload
  case preview(DocumentVersion)
  case setCurrent(DocumentVersion)
  case download(DocumentVersion)
  case delete(DocumentVersion)
  var id: Self { self }
}
/// A PDF's versions. The current one is what the app shows, exports, and reads.
struct DocumentVersionsSection: View {
  let workspace: DocumentWorkspace
  @Binding var action: VersionAction?
  private var isBusy: Bool { workspace.document.status == "processing" }
  var body: some View {
    Section {
      ForEach(workspace.versions) { version in
        Button {
          action = .preview(version)
        } label: {
          row(version).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(version) }
      }
      Button("Upload new version", systemImage: "arrow.up.doc") { action = .upload }.disabled(isBusy)
    } header: {
      Text("Versions")
    } footer: {
      Text("Filled and signed forms stay with the version they were made from.")
    }
  }
  private func row(_ version: DocumentVersion) -> some View {
    HStack(spacing: 12) {
      Text("\(version.number)").font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(version.isCurrent ? Color.buddyGreen : .secondary).frame(width: 28, height: 28)
        .background(
          (version.isCurrent ? Color.buddyGreen : Color.secondary).opacity(0.12),
          in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(version.name).lineLimit(1).truncationMode(.middle)
        Text("\(FilledForm.dayText(version.createdAt)) · \(Int64(version.size).formatted(.byteCount(style: .file)))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      if version.isCurrent {
        Text("Current").font(.caption.weight(.medium)).foregroundStyle(Color.buddyGreen)
      }
    }.accessibilityElement(children: .combine)
  }
  @ViewBuilder private func menu(_ version: DocumentVersion) -> some View {
    Button("Preview", systemImage: "doc.text.magnifyingglass") { action = .preview(version) }
    if !version.isCurrent {
      Button("Set as current version", systemImage: "checkmark.circle") { action = .setCurrent(version) }
        .disabled(isBusy)
    }
    Button("Download PDF", systemImage: "square.and.arrow.down") { action = .download(version) }
    if !version.isCurrent {
      Divider()
      Button("Delete version", systemImage: "trash", role: .destructive) { action = .delete(version) }
    }
  }
}
/// Lives on the whole form rather than its section, where these modifiers would attach to every row.
private struct VersionActionHost: ViewModifier {
  @Binding var action: VersionAction?
  let document: ScanDocument
  @Environment(AppStore.self) private var store
  @State private var importing = false
  @State private var newVersion: PDFImportBatch?
  @State private var previewing: DocumentVersion?
  @State private var deleting: DocumentVersion?
  @State private var exportFile: ExportFile?
  @State private var exportName = ""
  @State private var exporting = false
  func body(content: Content) -> some View {
    content
      .onChange(of: action) {
        guard let action else { return }
        self.action = nil
        Haptics.tap()
        run(action)
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
        switch result {
        case .success(let url): newVersion = PDFImportBatch(urls: [url])
        case .failure(let error): if !isSilentCancellation(error) { store.error = error.localizedDescription }
        }
      }
      .sheet(item: $newVersion) { batch in
        UploadVersionView(document: document, url: batch.urls[0]).fullSheet().actionFeedback()
      }
      .sheet(item: $previewing) { version in
        VersionPreviewView(version: version, document: document).wideSheet().actionFeedback()
      }
      .confirmationDialog(
        "Delete version \(deleting?.number ?? 0)?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible, presenting: deleting
      ) { version in
        Button("Delete version", role: .destructive) {
          Task {
            await store.perform("Deleting version…", success: "Version deleted") {
              try await store.deleteVersion(version, of: document)
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("This permanently removes this version’s PDF and its form.")
      }
      .fileExporter(isPresented: $exporting, document: exportFile, contentType: .pdf, defaultFilename: exportName) { result in
        if case .failure(let error) = result, !isSilentCancellation(error) {
          store.error = error.localizedDescription
        }
      }
  }
  private func run(_ action: VersionAction) {
    switch action {
    case .upload: importing = true
    case .preview(let version): previewing = version
    case .delete(let version): deleting = version
    case .setCurrent(let version):
      Task {
        await store.perform("Switching version…", success: "Version \(version.number) is now current") {
          try await store.setCurrentVersion(version, of: document)
        }
      }
    case .download(let version):
      Task {
        await store.perform("Getting your PDF…", success: "PDF ready") {
          exportFile = ExportFile(data: try await store.downloadPDF(url: version.pdfUrl, path: version.pdfPath), type: .pdf)
          exportName = version.name
          exporting = true
        }
      }
    }
  }
}
extension View {
  func versionActions(_ action: Binding<VersionAction?>, document: ScanDocument) -> some View {
    modifier(VersionActionHost(action: action, document: document))
  }
}
private struct UploadVersionView: View {
  let document: ScanDocument
  let url: URL
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var makeCurrent = true
  var body: some View {
    NavigationStack {
      Form {
        Section("New version") {
          LabeledContent("File", value: url.lastPathComponent)
          LabeledContent("Of", value: document.name)
        }
        Section {
          Toggle("Make this the current version", isOn: $makeCurrent)
        } footer: {
          Text("The current version is the one shown and exported. Lumik reads it the first time it becomes current. Earlier versions, and forms filled from them, stay as they are.")
        }
      }.formStyle(.grouped).navigationTitle("Upload Version")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Upload") { upload() }.disabled(store.busy != nil)
          }
        }
    }
  }
  private func upload() {
    Task {
      if await store.perform("Preparing \(url.lastPathComponent)…", success: "Version uploaded", {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.starts(with: Data("%PDF-".utf8)) else {
          throw APIError(message: "Only PDF documents are supported.")
        }
        try await store.uploadVersion(data, name: url.lastPathComponent, of: document, makeCurrent: makeCurrent)
      }) {
        dismiss()
      }
    }
  }
}
private struct VersionPreviewView: View {
  let version: DocumentVersion
  let document: ScanDocument
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var data: Data?
  @State private var problem: String?
  var body: some View {
    NavigationStack {
      Group {
        if let data {
          PDFPreview(data: data)
        } else if let problem {
          ContentUnavailableView("Couldn’t load this version", systemImage: "doc.questionmark", description: Text(problem))
        } else {
          ResourceLoadingView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Version \(version.number)")
      .navigationSubtitle(version.name)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
        if !version.isCurrent {
          ToolbarItem(placement: .confirmationAction) {
            Button("Set as Current") {
              Task {
                if await store.perform("Switching version…", success: "Version \(version.number) is now current", {
                  try await store.setCurrentVersion(version, of: document)
                }) {
                  dismiss()
                }
              }
            }.disabled(document.status == "processing" || store.busy != nil)
          }
        }
      }
      .task {
        do { data = try await store.downloadPDF(url: version.pdfUrl, path: version.pdfPath) }
        catch { if !isSilentCancellation(error) { problem = error.localizedDescription } }
      }
    }
  }
}
