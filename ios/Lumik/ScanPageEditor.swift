import SwiftUI
import PDFKit

/// The same page editor is used for the open scan and finished PDFs.
struct ScanPageEditor: View {
  let document: PDFDocument
  let pageCount: Int
  var editable = true
  var allowsEmpty = true
  let changed: () -> Void
  @State private var selected = 0
  @State private var revision = 0
  @State private var deleting: Int?
  @State private var status: String?
  @State private var dragScope = UUID().uuidString

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(0..<pageCount, id: \.self) { index in
            if let page = document.page(at: index) {
              thumbnail(page, index: index)
            }
          }
        }.padding(10)
      }
      .frame(width: 100)
      .background(.quaternary.opacity(0.3))
      Divider()
      if let page = document.page(at: min(selected, max(0, pageCount - 1))) {
        ScanSinglePagePreview(page: page).id("\(selected)-\(revision)-\(pageCount)")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView("No Pages", systemImage: "doc",
          description: Text("Scan more pages to continue."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .confirmationDialog("Delete page \((deleting ?? 0) + 1)?", isPresented: Binding(
      get: { deleting != nil }, set: { if !$0 { deleting = nil } }
    ), titleVisibility: .visible) {
      Button("Delete Page", role: .destructive) {
        guard editable, let index = deleting, index < document.pageCount,
          allowsEmpty || document.pageCount > 1 else { return }
        document.removePage(at: index)
        if selected > index { selected -= 1 }
        selected = min(selected, max(0, document.pageCount - 1))
        deleting = nil
        didEdit("Page deleted.")
      }
    }
    .overlay(alignment: .top) {
      if let status {
        Text(status).padding(12).glassEffect(.regular, in: .capsule)
          .padding().allowsHitTesting(false)
      }
    }
    .task(id: revision) {
      guard status != nil else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      status = nil
    }
  }

  private func thumbnail(_ page: PDFPage, index: Int) -> some View {
    VStack(spacing: 4) {
      Button {
        selected = index
        Haptics.tap()
      } label: {
        VStack(spacing: 4) {
          #if os(macOS)
          Image(nsImage: page.thumbnail(of: CGSize(width: 144, height: 190), for: .mediaBox))
            .resizable().scaledToFit()
          #else
          Image(uiImage: page.thumbnail(of: CGSize(width: 144, height: 190), for: .mediaBox))
            .resizable().scaledToFit()
          #endif
          Text("\(index + 1)").font(.caption)
        }
        .padding(4)
        .frame(width: 72)
        .background(selected == index ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
          .stroke(selected == index ? Color.accentColor : Color.clear, lineWidth: 2))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Preview page \(index + 1)")
      Menu {
        Button("Delete Page", systemImage: "trash", role: .destructive) {
          Haptics.tap()
          deleting = index
        }.disabled(!allowsEmpty && pageCount == 1)
        Button("Move Up", systemImage: "arrow.up") { move(index, to: index - 1) }
          .disabled(index == 0)
        Button("Move Down", systemImage: "arrow.down") { move(index, to: index + 1) }
          .disabled(index == pageCount - 1)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .disabled(!editable)
      .accessibilityLabel("Actions for page \(index + 1)")
    }
    .onDrag {
      NSItemProvider(object: (editable ? "\(dragScope):\(revision):\(index)" : "") as NSString)
    }
    .dropDestination(for: String.self) { items, _ in
      guard editable, let item = items.first else { return false }
      let parts = item.split(separator: ":")
      guard parts.count == 3, String(parts[0]) == dragScope,
        Int(parts[1]) == revision, let source = Int(parts[2]),
        source != index else { return false }
      move(source, to: index)
      return true
    }
  }

  private func move(_ source: Int, to destination: Int) {
    guard editable, source >= 0, destination >= 0,
      destination < document.pageCount, let page = document.page(at: source) else { return }
    let selectedPage = document.page(at: selected)
    document.removePage(at: source)
    document.insert(page, at: destination)
    if let selectedPage { selected = document.index(for: selectedPage) }
    didEdit("Page moved to position \(destination + 1).")
  }

  private func didEdit(_ message: String) {
    revision += 1
    status = message
    changed()
    Haptics.success()
  }
}

struct ScanDocumentEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var document: PDFDocument
  @State private var pageCount: Int
  @State private var saveFailed = false
  let save: (Data, Int) -> Bool

  init(data: Data, save: @escaping (Data, Int) -> Bool) {
    let pdf = PDFDocument(data: data) ?? PDFDocument()
    _document = State(initialValue: pdf)
    _pageCount = State(initialValue: pdf.pageCount)
    self.save = save
  }

  var body: some View {
    NavigationStack {
      ScanPageEditor(document: document, pageCount: pageCount, allowsEmpty: false) {
        pageCount = document.pageCount
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Edit Scanned Pages")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { Haptics.tap(); dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            guard let data = document.dataRepresentation(), save(data, pageCount) else {
              saveFailed = true
              Haptics.failure()
              return
            }
            Haptics.success()
            dismiss()
          }.disabled(pageCount == 0)
        }
      }
    }
    .interactiveDismissDisabled()
    .alert("Could Not Save Pages", isPresented: $saveFailed) {
      Button("OK") {}
    } message: {
      Text("Your edits are still here. Try saving again.")
    }
  }
}

#if os(macOS)
private struct ScanSinglePagePreview: NSViewRepresentable {
  let page: PDFPage
  func makeNSView(context: Context) -> PDFView { makePreview(page) }
  func updateNSView(_ view: PDFView, context: Context) {}
}
#else
private struct ScanSinglePagePreview: UIViewRepresentable {
  let page: PDFPage
  func makeUIView(context: Context) -> PDFView { makePreview(page) }
  func updateUIView(_ view: PDFView, context: Context) {}
}
#endif

@MainActor private func makePreview(_ page: PDFPage) -> PDFView {
  let view = PDFView()
  let pdf = PDFDocument()
  if let copy = page.copy() as? PDFPage { pdf.insert(copy, at: 0) }
  view.document = pdf
  view.autoScales = true
  view.displayMode = .singlePage
  return view
}
