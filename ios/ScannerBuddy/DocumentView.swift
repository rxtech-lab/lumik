import PDFKit
import SwiftUI

struct DocumentDetailView: View {
  @State var document: ScanDocument
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @State private var preview = PDFLoadState.loading
  @State private var showsInspector = true
  @State private var reading = false
  @State private var editing = false
  @State private var deleting = false
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
  private var fields: [String: JSONValue] { document.data?.object ?? [:] }
  private var isProcessing: Bool { document.status == "processing" }
  var body: some View {
    Group {
      if isRegular {
        pdfPane.inspector(isPresented: $showsInspector) {
          details.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
      } else {
        details
      }
    }.navigationTitle(document.name)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .task(id: document.id) { await loadPDF() }
      .onChange(of: store.documents) {
        if let updated = store.documents.first(where: { $0.id == document.id }) {
          document = updated
        }
      }
      .toolbar {
        if isRegular {
          ToolbarItem(placement: .primaryAction) {
            Button("Details", systemImage: "sidebar.trailing") {
              showsInspector.toggle()
              Haptics.tap()
            }
          }
        }
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
      .sheet(
        isPresented: $deleting,
        onDismiss: { if !store.documents.contains(where: { $0.id == document.id }) { dismiss() } }
      ) {
        DeleteView(
          title: document.name, message: "This permanently removes the PDF and its extracted data."
        ) {
          _ = try await store.request("documents/\(document.id)", method: "DELETE")
          await store.loadDocuments(document.groupId)
          await store.refresh()
        }.fullSheet().actionFeedback()
      }
      .fileExporter(
        isPresented: $exporting, document: exportFile, contentType: .pdf,
        defaultFilename: document.name
      ) { result in
        if case .failure(let error) = result { store.error = error.localizedDescription }
      }
  }
  private var actionsMenu: some View {
    Menu {
      Section {
        Button(
          document.status == "ready" ? "Extract again" : "Extract details",
          systemImage: "sparkles"
        ) { extract() }.disabled(isProcessing)
        Button("Edit details", systemImage: "pencil") {
          editing = true
          Haptics.tap()
        }.disabled(isProcessing)
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
      ProgressView("Loading PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
      ProgressView("Loading PDF…").frame(maxWidth: .infinity, minHeight: 240)
    case .failed(let message):
      previewFailure(message)
    }
  }
  // MARK: Details
  private var details: some View {
    Form {
      if !isRegular {
        Section { pageHero }.listRowBackground(Color.clear)
      }
      if isProcessing {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Reading this PDF to fill your group’s fields and rename it…")
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
      Section("Document") {
        DetailRow(label: "Name", value: document.name)
        if document.originalName != document.name {
          DetailRow(label: "Original name", value: document.originalName)
        }
        LabeledContent("Status") {
          Label(document.statusText, systemImage: document.statusIcon)
            .foregroundStyle(document.statusColor)
        }
        if case .loaded(let pdf) = preview {
          LabeledContent("Pages", value: pdf.pageCount.formatted())
        }
        LabeledContent(
          "Size", value: Int64(document.size).formatted(.byteCount(style: .file)))
        LabeledContent("Added", value: document.addedText)
      }
    }.formStyle(.grouped)
  }
  private func extract() {
    Task {
      await store.perform(
        "Reading and organizing your document…", success: "Details extracted"
      ) {
        document = try await store.fetch(
          ScanDocument.self, "documents/\(document.id)/process", method: "POST")
        await store.loadDocuments(document.groupId)
      }
    }
  }
  private func loadPDF() async {
    preview = .loading
    do {
      let data = try await store.request("documents/\(document.id)/pdf")
      if let pdf = LoadedPDF(data: data) {
        preview = .loaded(pdf)
      } else {
        preview = .failed("This file appears to be damaged.")
      }
    } catch {
      if !Task.isCancelled { preview = .failed(error.localizedDescription) }
    }
  }
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
  fileprivate var statusText: String {
    switch status {
    case "uploaded": "Not extracted"
    case "processing": "Reading"
    default: status.capitalized
    }
  }
  fileprivate var statusIcon: String {
    switch status {
    case "ready": "checkmark.circle.fill"
    case "processing": "clock"
    case "failed": "exclamationmark.triangle.fill"
    default: "circle.dashed"
    }
  }
  fileprivate var statusColor: Color {
    switch status {
    case "ready": .buddyGreen
    case "failed": .red
    default: .secondary
    }
  }
  fileprivate var addedText: String {
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    guard let date = try? style.parse(createdAt) else { return createdAt }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
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
