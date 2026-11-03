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
  @State private var fillingForm: FilledForm?
  @State private var signingAction: FormAction?
  @State private var layoutTemplate: FormLayoutRequest?
  @State private var loadedVersionID: String?
  private var hasForm: Bool {
    store.workspace?.document.id == document.id && store.workspace?.currentTemplate != nil
  }
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
      // Uploading or choosing another version changes the PDF on screen.
      .onChange(of: store.workspace?.currentVersion?.id) {
        guard store.workspace?.document.id == document.id, let version = store.workspace?.currentVersion,
          version.id != loadedVersionID
        else { return }
        Task { await loadVersion(version) }
      }
      .onChange(of: store.requestedFormDocumentID) {
        guard store.requestedFormDocumentID == document.id else { return }
        store.requestedFormDocumentID = nil
        openForm()
      }
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
      .formActions($signingAction)
      .sheet(item: $fillingForm) { form in
        FormFillView(form: form).wideSheet().actionFeedback()
      }
      .sheet(
        item: $layoutTemplate,
        // Fields were just placed on a PDF that had none, so carry on to filling them in.
        onDismiss: {
          if store.workspace?.currentTemplate?.fieldCount ?? 0 > 0 { fillingForm = store.workspace?.latestDraft }
        }
      ) { request in
        FormLayoutEditor(request: request).wideSheet().actionFeedback()
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
  /// Reads the PDF the first time. After that the saved form opens straight away.
  private var formButton: some View {
    Button(hasForm ? "Open form" : "Create form", systemImage: hasForm ? "list.clipboard.fill" : "list.clipboard") {
      openForm()
    }
    .labelStyle(.titleAndIcon)
    .disabled(!isPDFLoaded || store.busy != nil)
    .accessibilityIdentifier("document-form")
  }
  private func openForm(regenerate: Bool = false) {
      guard case .loaded(let pdf) = preview, store.busy == nil else { return }
      Haptics.tap()
      if let template = store.workspace?.currentTemplate, hasForm, !regenerate, template.fieldCount == 0 {
        layoutTemplate = FormLayoutRequest(template: template, pdf: pdf.data)
        return
      }
      if let draft = store.workspace?.latestDraft, hasForm, !regenerate {
        fillingForm = draft
        return
      }
      Task {
        var opened: FilledForm?
        let succeeded = await store.perform(
          regenerate ? "Regenerating form…" : hasForm ? "Opening form…" : "Reading this PDF and building its form…",
          success: hasForm ? "Form ready" : "Form created"
        ) { opened = try await store.openOrCreateForm(document, pdf: pdf.data, regenerate: regenerate) }
        guard succeeded, let opened else { return }
        // Nothing fillable was found, so the person places the fields themselves.
        if let template = store.workspace?.currentTemplate, template.fieldCount == 0 {
          layoutTemplate = FormLayoutRequest(template: template, pdf: pdf.data)
        } else {
          fillingForm = opened
        }
      }
  }
  private var isPDFLoaded: Bool { if case .loaded = preview { true } else { false } }
  private var signingDrafts: [FilledForm] {
    guard let workspace = store.workspace, workspace.document.id == document.id else { return [] }
    return workspace.forms.filter { $0.isDraft && $0.versionId == workspace.currentVersion?.id }
  }
  @ViewBuilder private var signingButton: some View {
    if signingDrafts.count == 1, let draft = signingDrafts.first {
      Button("Add to signing request", systemImage: "signature") {
        signingAction = .addToSigning([draft])
      }.disabled(store.busy != nil)
    } else if signingDrafts.count > 1 {
      Menu("Add to signing request", systemImage: "signature") {
        ForEach(signingDrafts) { draft in
          Button(draft.title) { signingAction = .addToSigning([draft]) }
        }
      }.disabled(store.busy != nil)
    }
  }
  private var actionsMenu: some View {
    Menu {
      Section {
        formButton
        if hasForm {
          Button("Regenerate form", systemImage: "arrow.clockwise") { openForm(regenerate: true) }
            .disabled(!isPDFLoaded || isProcessing || store.busy != nil)
        }
        signingButton
      }
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
              let data = try await store.currentPDF(of: document)
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
  /// One API read brings the page's versions and forms too; the PDF itself comes straight from storage.
  private func loadPDF() async {
    preview = .loading
    store.loadingDocumentID = document.id
    defer {
      if store.loadingDocumentID == document.id { store.loadingDocumentID = nil }
    }
    do {
      let workspace = try await store.loadWorkspace(document)
      guard !Task.isCancelled else { return }
      document = workspace.document
      guard let version = workspace.currentVersion else {
        preview = .failed("This document has no PDF.")
        return
      }
      await loadVersion(version)
    } catch {
      if !isSilentCancellation(error) { preview = .failed(error.localizedDescription) }
    }
  }
  private func loadVersion(_ version: DocumentVersion) async {
    loadedVersionID = version.id
    preview = .loading
    store.suggestedFormDocumentID = nil
    do {
      let data = try await store.downloadPDF(url: version.pdfUrl, path: version.pdfPath)
      guard !Task.isCancelled else { return }
      if let pdf = LoadedPDF(data: data) {
        preview = .loaded(pdf)
        store.suggestedFormDocumentID = pdf.seemsLikeForm ? document.id : nil
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
  @State private var formAction: FormAction?
  @State private var layoutRequest: FormLayoutRequest?
  @State private var versionAction: VersionAction?
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
      }
      if document.status != "processing", fields.isEmpty || showsFormAction {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Text(showsFormAction
              ? "Extract document details or fill in this PDF as a form."
              : "Fill your group’s fields and rename this PDF automatically.")
              .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
              Button { extract() } label: {
                Label("Extract details", systemImage: "sparkles").frame(maxWidth: .infinity)
              }.buttonStyle(.borderedProminent)
              if showsFormAction {
                Button {
                  store.requestedFormDocumentID = document.id
                } label: {
                  Label(hasForm ? "Open form" : "Create form", systemImage: "list.clipboard")
                    .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                  .accessibilityIdentifier("sidebar-document-form")
              }
            }.controlSize(.large).disabled(store.busy != nil || store.loadingDocumentID == document.id)
          }.padding(.vertical, 4)
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
      if store.workspace?.document.id == document.id, let workspace = store.workspace {
        DocumentFormsSection(workspace: workspace, action: $formAction, layout: $layoutRequest)
        DocumentVersionsSection(workspace: workspace, action: $versionAction)
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
      .formActions($formAction)
      .versionActions($versionAction, document: document)
      .sheet(item: $layoutRequest) { request in
        FormLayoutEditor(request: request).wideSheet().actionFeedback()
      }
  }
  private var hasForm: Bool {
    store.workspace?.document.id == document.id && store.workspace?.currentTemplate != nil
  }
  private var showsFormAction: Bool { hasForm || store.suggestedFormDocumentID == document.id }
  private func extract() { Haptics.tap(); Task { await store.extract(document) } }
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
  let seemsLikeForm: Bool
  init?(data: Data) {
    guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
      return nil
    }
    let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
    let text = pages.prefix(10).compactMap(\.string).joined(separator: " ").lowercased()
    let prompts = ["signature", "date of birth", "applicant", "please complete", "please fill", "checkbox"]
    seemsLikeForm = pages.contains { $0.annotations.contains { $0.widgetFieldType != nil } }
      || prompts.filter { text.contains($0) }.count >= 2
      || (text.contains("____") && prompts.contains { text.contains($0) })
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
/// Holds the bytes on screen, so a redraw only replaces the document when they actually change.
private actor FormPreviewRenderer {
  static let shared = FormPreviewRenderer()
  func render(data: Data, sections: [FormSection], values: [String: JSONValue], changed: Set<String>) throws -> (pdf: Data, boxes: [FormPlacement]) {
    try Task.checkCancellation()
    let pdf = try FormRenderer.render(base: data, sections: sections, values: values)
    return (pdf, try FormRenderer.drawnBoxes(base: data, sections: sections, fieldIDs: changed))
  }
}
/// A filled PDF, with the sections and answers it was drawn from.
struct FilledRevision: Sendable {
  let pdf: Data
  let sections: [FormSection]
  let values: [String: JSONValue]
}
@MainActor
final class PDFPreviewState {
  var data: Data?
  var sections: [FormSection] = []
  var values: [String: JSONValue] = [:]
  private var renderTask: Task<Void, Never>?
  private var revision = 0

  func start(data: Data, first: FilledRevision?) {
    self.data = data
    sections = first?.sections ?? []
    values = first?.values ?? [:]
  }

  func update(_ view: PDFView, data: Data, sections: [FormSection], values: [String: JSONValue]) {
    guard self.data != data || self.sections != sections || self.values != values else { return }
    let changed = Set(sections.flatMap(\.fields).filter { self.values[$0.id] != values[$0.id] }.map(\.id))
    self.data = data
    self.sections = sections
    self.values = values
    revision += 1
    let requestedRevision = revision
    renderTask?.cancel()
    renderTask = Task { [weak self, weak view] in
      do {
        try await Task.sleep(for: .milliseconds(250))
        let rendered = sections.isEmpty ? (pdf: data, boxes: []) : try await FormPreviewRenderer.shared.render(
          data: data, sections: sections, values: values, changed: changed)
        try Task.checkCancellation()
        guard let self, self.revision == requestedRevision, let view else { return }
        view.transition(to: rendered.pdf, filling: rendered.boxes)
      } catch is CancellationError {
        // A newer edit superseded this preview.
      } catch {
        // Keep the last successful preview; saving reports rendering failures separately.
      }
    }
  }
}
#if os(iOS)
  struct PDFPreview: UIViewRepresentable {
    let data: Data
    var sections: [FormSection] = []
    var values: [String: JSONValue] = [:]
    /// What to show straight away, instead of the plain PDF followed by a redraw.
    var first: FilledRevision?
    func makeCoordinator() -> PDFPreviewState { PDFPreviewState() }
    func makeUIView(context: Context) -> PDFView {
      let view = PDFView()
      view.document = PDFDocument(data: first?.pdf ?? data)
      context.coordinator.start(data: data, first: first)
      view.displayMode = .singlePageContinuous
      view.autoScales = true
      view.backgroundColor = .secondarySystemBackground
      view.pageBreakMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
      return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
      context.coordinator.update(uiView, data: data, sections: sections, values: values)
    }
  }
#else
  struct PDFPreview: NSViewRepresentable {
    let data: Data
    var sections: [FormSection] = []
    var values: [String: JSONValue] = [:]
    /// What to show straight away, instead of the plain PDF followed by a redraw.
    var first: FilledRevision?
    func makeCoordinator() -> PDFPreviewState { PDFPreviewState() }
    func makeNSView(context: Context) -> PDFView {
      let view = PDFView()
      view.document = PDFDocument(data: first?.pdf ?? data)
      context.coordinator.start(data: data, first: first)
      view.displayMode = .singlePageContinuous
      view.autoScales = true
      view.backgroundColor = .underPageBackgroundColor
      view.pageBreakMargins = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
      return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
      context.coordinator.update(nsView, data: data, sections: sections, values: values)
    }
  }
#endif
