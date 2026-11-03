import PDFKit
import SwiftUI

struct DocumentDetailView: View {
  @State var document: ScanDocument
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var preview = PDFLoadState.loading
  @State private var reading = false
  @State private var editing = false
  @State private var renaming: DocumentRename?
  @State private var deleting = false
  @State private var moving: ScanDocument?
  @State private var exporting = false
  @State private var exportFile: ExportFile?
  /// Mac and iPad read the PDF beside an inspector; iPhone leads with a page you tap to open.
  private var isRegular: Bool {
    #if os(macOS)
      true
    #else
      sizeClass != .compact
    #endif
  }
  private var pageCount: Int? { if case .loaded(let pdf) = preview { pdf.pageCount } else { nil } }
  private var isProcessing: Bool { document.status == "processing" }
  private var isLoading: Bool { if case .loading = preview { true } else { false } }
  var body: some View {
    ZStack {
      if isLoading {
        ResourceLoadingView().background(Color.pdfCanvas).transition(.opacity)
      } else if isRegular {
        pdfPane
      } else {
        DocumentDetailsForm(document: document, pageCount: pageCount) { pageHero }
      }
    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isLoading)
      .navigationTitle(document.name)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .task(id: document.id) { await loadPDF() }
      .onChange(of: store.documents) {
        if let updated = store.documents.first(where: { $0.id == document.id }) {
          document = updated
        }
      }
      // Lumik and the right-hand details follow whichever PDF is on screen.
      .onChange(of: document, initial: true) {
        store.openDocument = document
        if isLoading { store.loadingDocumentID = document.id }
      }
      .onChange(of: pageCount, initial: true) { store.openDocumentPages = pageCount }
      .onAppear {
        store.openDocument = document
        if isRegular { store.agentPanelVisible = true }
      }
      .onDisappear { if store.openDocument?.id == document.id { store.openDocument = nil } }
      .toolbar {
        if isRegular {
          ToolbarItem(placement: .primaryAction) {
            Button("Document details", systemImage: "sidebar.right") {
              Haptics.tap()
              store.agentPanelTab = .details
              store.agentPanelVisible = true
            }.accessibilityIdentifier("document-details-toggle")
          }
        }
        ToolbarItem(placement: .primaryAction) { AgentToolbarButton() }
        ToolbarItem(placement: .primaryAction) { actionsMenu }
      }
      .sheet(isPresented: $reading) {
        if case .loaded(let pdf) = preview {
          NavigationStack {
            PDFPreview(data: pdf.data).ignoresSafeArea(edges: .bottom)
              .navigationTitle(document.name)
              #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
              #endif
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button(role: .close) { reading = false }
                }
              }
          }.fullSheet()
        }
      }
      .sheet(isPresented: $editing) {
        DocumentEditor(document: document) { document = $0 }.fullSheet().actionFeedback()
      }
      .sheet(item: $renaming) { RenameDocumentView(request: $0).fullSheet().actionFeedback() }
      .sheet(
        item: $moving,
        // A PDF moved from here no longer belongs to the list behind it.
        onDismiss: { if !store.documents.contains(where: { $0.id == document.id }) { dismiss() } }
      ) {
        MoveDocumentView(document: $0).fullSheet().actionFeedback()
      }
      .sheet(
        isPresented: $deleting,
        onDismiss: { if !store.documents.contains(where: { $0.id == document.id }) { dismiss() } }
      ) {
        DeleteView(
          title: document.name, message: "This permanently removes the PDF and its extracted data."
        ) {
          try await store.deleteDocument(document)
        }.fullSheet().actionFeedback()
      }
      .fileExporter(
        isPresented: $exporting, document: exportFile, contentType: .pdf,
        defaultFilename: document.name
      ) { result in
        if case .failure(let error) = result { if !isSilentCancellation(error) { store.error = error.localizedDescription } }
      }
  }
  private var actionsMenu: some View {
    Menu {
      Section {
        Button(
          document.status == "ready" ? "Extract again" : "Extract details",
          systemImage: "sparkles"
        ) { Task { await store.extract(document) } }.disabled(isProcessing)
        Button("Edit details", systemImage: "pencil") {
          editing = true
          Haptics.tap()
        }.disabled(isProcessing)
      }
      Section {
        Button("Rename", systemImage: "character.cursor.ibeam") {
          renaming = DocumentRename(document: document)
          Haptics.tap()
        }.disabled(isProcessing)
        Button("Rename with AI", systemImage: "sparkles") {
          renaming = DocumentRename(document: document, suggestsName: true)
          Haptics.tap()
        }.disabled(isProcessing)
      }
      Section {
        MoveDocumentButtons(store: store, document: document, moving: $moving) { dismiss() }
      }
      Section {
        Button("Save PDF", systemImage: "square.and.arrow.up") {
          Task {
            await store.perform("Preparing PDF…", success: "PDF ready") {
              let data = try await store.request("documents/\(document.id)/pdf")
              exportFile = ExportFile(data: data, type: .pdf)
              exporting = true
            }
          }
        }
      }
      Section {
        Button("Delete document", systemImage: "trash", role: .destructive) {
          deleting = true
          Haptics.tap()
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }.menuIndicator(.hidden).accessibilityLabel("Document actions")
  }
  // MARK: PDF
  @ViewBuilder private var pdfPane: some View {
    switch preview {
    case .loaded(let pdf): PDFPreview(data: pdf.data)
    case .loading:
      ResourceLoadingView()
        .background(Color.pdfCanvas)
    case .failed(let message):
      previewFailure(message).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pdfCanvas)
    }
  }
  private func previewFailure(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn’t load the PDF", systemImage: "doc.questionmark")
    } description: {
      Text(message)
    } actions: {
      Button("Try again") { Task { await loadPDF() } }
    }
  }
  @ViewBuilder private var pageHero: some View {
    switch preview {
    case .loaded(let pdf):
      Button {
        reading = true
        Haptics.tap()
      } label: {
        pdf.firstPage.resizable().scaledToFit().frame(maxHeight: 340)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
          .overlay(alignment: .bottomTrailing) {
            Text(pdf.pageCount == 1 ? "1 page" : "\(pdf.pageCount) pages")
              .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
              .background(.thinMaterial, in: Capsule()).padding(10)
          }
      }.buttonStyle(.plain).accessibilityLabel("Open PDF").frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    case .loading:
      ResourceLoadingView().frame(minHeight: 360)
    case .failed(let message):
      previewFailure(message)
    }
  }
  private func loadPDF() async {
    preview = .loading
    store.loadingDocumentID = document.id
    defer {
      if store.loadingDocumentID == document.id { store.loadingDocumentID = nil }
    }
    do {
      let data = try await store.request("documents/\(document.id)/pdf")
      guard !Task.isCancelled else { return }
      if let pdf = LoadedPDF(data: data) {
        preview = .loaded(pdf)
      } else {
        preview = .failed("This file appears to be damaged.")
      }
    } catch {
      if !isSilentCancellation(error) { preview = .failed(error.localizedDescription) }
    }
  }
}
/// The PDF's fields and metadata: under the page on iPhone, in the right-hand panel elsewhere.
struct DocumentDetailsForm<Hero: View>: View {
  let document: ScanDocument
  let pageCount: Int?
  @ViewBuilder var hero: Hero
  @Environment(AppStore.self) private var store
  private var fields: [String: JSONValue] { document.data?.object ?? [:] }
  var body: some View {
    Form {
      if !(hero is EmptyView) {
        Section { hero }.listRowBackground(Color.clear)
      }
      if document.status == "processing" {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("AI analysis in progress · Reading PDF content, extracting your group’s fields, and generating a filename. This continues in the background.")
              .foregroundStyle(.secondary)
          }
        }
      } else if document.status == "failed" {
        Section {
          Label(document.error ?? "Couldn’t read this PDF.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Button("Try again", systemImage: "arrow.clockwise") { extract() }
        }
      } else if fields.isEmpty {
        Section {
          Text("Fill your group’s fields and rename this PDF automatically.")
            .foregroundStyle(.secondary)
          Button("Extract details", systemImage: "sparkles") { extract() }
            .buttonStyle(.borderedProminent)
        }
      }
      if !fields.isEmpty {
        Section("Extracted details") {
          ForEach(fields.keys.sorted(), id: \.self) { key in
            DetailRow(label: key.fieldLabel, value: fields[key]?.displayText ?? "—")
          }
        }
      }
      if let additional = document.additional {
        Section("Also in this PDF") {
          AdditionalDetailsView(spec: additional.spec).id(additional.spec)
        }
      }
      Section("Document") {
        DetailRow(label: "Name", value: document.name)
        if document.originalName != document.name {
          DetailRow(label: "Original name", value: document.originalName)
        }
        LabeledContent("Status") {
          Label(document.statusText, systemImage: document.statusIcon)
            .foregroundStyle(document.statusColor)
        }
        if let pageCount {
          LabeledContent("Pages", value: pageCount.formatted())
        }
        LabeledContent(
          "Size", value: document.sizeText)
        LabeledContent("Added", value: document.addedText)
      }
    }.formStyle(.grouped)
  }
  private func extract() { Task { await store.extract(document) } }
}
extension DocumentDetailsForm where Hero == EmptyView {
  init(document: ScanDocument, pageCount: Int?) {
    self.init(document: document, pageCount: pageCount) { EmptyView() }
  }
}
private struct AdditionalDetailsView: View {
  let spec: JSONValue
  @State private var state: JSONRenderState
  init(spec: JSONValue) {
    self.spec = spec
    _state = State(initialValue: JSONRenderState(spec.object["state"] ?? .object([:])))
  }
  var body: some View { JSONRenderView(spec: spec, state: state) }
}
private enum PDFLoadState {
  case loading
  case loaded(LoadedPDF)
  case failed(String)
}
private struct LoadedPDF {
  let data: Data
  let pageCount: Int
  let firstPage: Image
  init?(data: Data) {
    guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
      return nil
    }
    self.data = data
    pageCount = document.pageCount
    let thumbnail = page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
    #if os(macOS)
      firstPage = Image(nsImage: thumbnail)
    #else
      firstPage = Image(uiImage: thumbnail)
    #endif
  }
}
/// Short values sit opposite their label like Settings; long ones get the full width.
private struct DetailRow: View {
  let label: String
  let value: String
  var body: some View {
    if value.count > 28 || value.contains("\n") {
      VStack(alignment: .leading, spacing: 4) {
        Text(label).foregroundStyle(.secondary).font(.subheadline)
        Text(value).textSelection(.enabled)
      }
    } else {
      LabeledContent(label) { Text(value).textSelection(.enabled) }
    }
  }
}
extension String {
  fileprivate var fieldLabel: String { replacingOccurrences(of: "_", with: " ").capitalized }
  fileprivate var withoutPDFExtension: String {
    lowercased().hasSuffix(".pdf") ? String(dropLast(4)) : self
  }
}
extension JSONValue {
  fileprivate var displayText: String {
    switch self {
    case .string(let value): value.isEmpty ? "—" : value
    case .number(let value): value.formatted()
    case .bool(let value): value ? "Yes" : "No"
    case .null: "—"
    case .array(let values):
      values.map(\.displayText).joined(
        separator: values.allSatisfy { $0.object.isEmpty && $0.array.isEmpty } ? ", " : "\n\n")
    case .object(let values):
      values.keys.sorted().map { "\($0.fieldLabel): \(values[$0]?.displayText ?? "—")" }
        .joined(separator: "\n")
    }
  }
}
extension ScanDocument {
  var statusText: String {
    switch status {
    case "uploaded": "Not extracted"
    case "processing": "Reading"
    default: status.capitalized
    }
  }
  var statusIcon: String {
    switch status {
    case "ready": "checkmark.circle.fill"
    case "processing": "clock"
    case "failed": "exclamationmark.triangle.fill"
    default: "circle.dashed"
    }
  }
  var statusColor: Color {
    switch status {
    case "ready": .buddyGreen
    case "failed": .red
    default: .secondary
    }
  }
  private var addedDate: Date? {
    try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(createdAt)
  }
  fileprivate var addedText: String {
    addedDate?.formatted(date: .abbreviated, time: .shortened) ?? createdAt
  }
  var addedDayText: String { addedDate?.formatted(date: .abbreviated, time: .omitted) ?? createdAt }
  var sizeText: String { Int64(size).formatted(.byteCount(style: .file)) }
}
extension Color {
  fileprivate static var pdfCanvas: Color {
    #if os(macOS)
      Color(nsColor: .underPageBackgroundColor)
    #else
      Color(uiColor: .secondarySystemBackground)
    #endif
  }
}
struct DocumentRename: Identifiable {
  let document: ScanDocument
  var suggestsName = false
  var id: String { document.id }
}
/// AI only fills in the field, so a suggested name is always reviewed before it is saved.
struct RenameDocumentView: View {
  let request: DocumentRename
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  init(request: DocumentRename) {
    self.request = request
    _name = State(initialValue: request.document.name.withoutPDFExtension)
  }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSave: Bool {
    store.busy == nil && !trimmedName.isEmpty
      && trimmedName != request.document.name.withoutPDFExtension
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("PDF name") {
          HStack {
            TextField("Filename", text: $name).labelsHidden().disabled(store.busy != nil)
            Text(".pdf").foregroundStyle(.secondary)
          }
        }
        Section {
          Button("Suggest a name with AI", systemImage: "sparkles") { suggest() }
            .disabled(store.busy != nil)
        } footer: {
          Text("Reads this PDF and follows the naming of your group’s recent documents.")
        }
      }.formStyle(.grouped).navigationTitle("Rename PDF").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              if await store.perform(
                "Renaming PDF…", success: "Renamed",
                { try await store.renameDocument(request.document, to: trimmedName) })
              {
                dismiss()
              }
            }
          }.disabled(!canSave)
        }
      }
      .onAppear { if request.suggestsName { suggest() } }
    }
  }
  private func suggest() {
    Task {
      await store.perform("Reading this PDF…", success: "Name suggested") {
        name = try await store.suggestDocumentName(request.document).withoutPDFExtension
      }
    }
  }
}
struct DocumentEditor: View {
  let document: ScanDocument
  let saved: (ScanDocument) -> Void
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var value: JSONValue
  @State private var raw = false
  init(document: ScanDocument, saved: @escaping (ScanDocument) -> Void) {
    self.document = document
    self.saved = saved
    _name = State(initialValue: document.name)
    _value = State(initialValue: document.data ?? .object([:]))
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("PDF name") { TextField("Filename", text: $name) }
        Section("Extracted fields") {
          ForEach(value.object.keys.sorted(), id: \.self) { key in
            if case .string = value.object[key] {
              TextField(
                key,
                text: Binding(
                  get: { value.object[key]?.string ?? "" },
                  set: {
                    var o = value.object
                    o[key] = .string($0)
                    value = .object(o)
                  }))
            } else {
              LabeledContent(key, value: value.object[key]?.pretty ?? "null")
            }
          }
          Button("Edit all fields as JSON", systemImage: "curlybraces") { raw = true }
        }
      }.formStyle(.grouped).navigationTitle("Edit document").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              if await store.perform(
                "Saving document…", success: "Document saved",
                {
                  let body = JSONValue.object(["name": .string(name), "data": value])
                  let result = try await store.fetch(
                    ScanDocument.self, "documents/\(document.id)", method: "PATCH",
                    body: JSONEncoder().encode(body))
                  saved(result)
                  await store.loadDocuments(document.groupId)
                })
              {
                dismiss()
              }
            }
          }.disabled(name.isEmpty)
        }
      }
      .sheet(isPresented: $raw) {
        JSONEditor(title: "Extracted data", value: value) { value = $0 }.fullSheet()
      }
    }
  }
}
#if os(iOS)
  struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
      let view = PDFView()
      view.document = PDFDocument(data: data)
      view.displayMode = .singlePageContinuous
      view.autoScales = true
      view.backgroundColor = .secondarySystemBackground
      view.pageBreakMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
      return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
  }
#else
  struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
      let view = PDFView()
      view.document = PDFDocument(data: data)
      view.displayMode = .singlePageContinuous
      view.autoScales = true
      view.backgroundColor = .underPageBackgroundColor
      view.pageBreakMargins = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
      return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
  }
#endif
