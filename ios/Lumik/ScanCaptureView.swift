#if os(iOS)
  import SwiftUI
  import VisionKit
  import PDFKit

  struct ScanCaptureView: View {
    let group: ScanGroup
    /// Set when scanning for Lumik, which takes each PDF and closes this when they are all sent.
    var onUploaded: (@MainActor (ScanDocument) -> Void)? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var camera = false
    @State private var current = PDFDocument()
    @State private var pageCount = 0
    @State private var documents: [Data] = []
    @State private var error: String?
    @State private var closing = false
    @State private var uploading = false
    @State private var saveOptions = false
    @State private var status: String?
    @State private var editing: Int?


    var body: some View {
      NavigationStack {
        List {
          if pageCount > 0 {
            Section("Current Document") {
              ScanPageEditor(document: current, pageCount: pageCount, editable: !uploading) {
                pageCount = current.pageCount
              }
              .frame(height: 400)
              Text("\(pageCount) pages")
              Text("Scan More adds pages to this document.")
                .foregroundStyle(.secondary)
            }
          }
          if !documents.isEmpty {
            Section("Finished Documents") {
              ForEach(documents.indices, id: \.self) { index in
                Button {
                  Haptics.tap()
                  editing = index
                } label: {
                  HStack {
                    if let page = PDFDocument(data: documents[index])?.page(at: 0) {
                      Image(uiImage: page.thumbnail(of: CGSize(width: 80, height: 110), for: .mediaBox))
                        .resizable().scaledToFit().frame(width: 40, height: 55)
                    }
                    LabeledContent("Document \(index + 1)",
                      value: "\(PDFDocument(data: documents[index])?.pageCount ?? 0) pages")
                  }
                }.disabled(uploading)
              }
            }
          }
          if pageCount == 0 && documents.isEmpty {
            ContentUnavailableView("Scan a Document", systemImage: "doc.viewfinder",
              description: Text("Capture multiple pages for one PDF, then choose Done to finish."))
          }
        }
        .navigationTitle("Scan Documents")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
              Haptics.tap()
              if pageCount == 0 && documents.isEmpty { dismiss() }
              else { closing = true }
            }.disabled(uploading)
          }
          ToolbarItem(placement: .confirmationAction) {
            if pageCount > 0 {
              Menu("Done") {
                Button("Finish") { finishDocument() }
                Button("Finish and Start New Document") {
                  if finishDocument() { camera = true }
                }
              }.disabled(uploading)
            }
          }
          ToolbarItemGroup(placement: .bottomBar) {
            Button(pageCount == 0 ? "Start Document Scanning" : "Scan More") {
              Haptics.tap()
              camera = true
            }.disabled(uploading || !VNDocumentCameraViewController.isSupported)
            Spacer()
            Button("Upload \(documents.count) PDFs") { Haptics.tap(); saveOptions = true }
              .disabled(uploading || documents.isEmpty || pageCount > 0)
          }
        }
        .overlay(alignment: .top) {
          if let status {
            HStack {
              if uploading { ProgressView() }
              Text(status)
            }
            .padding().glassEffect(.regular, in: .capsule).padding()
            .allowsHitTesting(false)
          }
        }
        .sheet(isPresented: $saveOptions) {
          ScanSaveOptions(count: documents.count) { dpi in upload(dpi: dpi) }
        }
        .sheet(isPresented: $camera) {
          DocumentCamera(completion: { result in
            camera = false
            switch result {
            case .success(let data):
              guard let scanned = PDFDocument(data: data) else { return }
              for index in 0..<scanned.pageCount {
                if let page = scanned.page(at: index) { current.insert(page, at: current.pageCount) }
              }
              pageCount = current.pageCount
            case .failure(let failure):
              if !isSilentCancellation(failure) {
                error = failure.localizedDescription
                Haptics.failure()
              }
            }
          }, cancel: { camera = false }).ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
          if let index = editing, documents.indices.contains(index) {
            ScanDocumentEditorSheet(data: documents[index]) { data, _ in
              documents[index] = data
              return true
            }
          }
        }
        .confirmationDialog("Discard scans that haven’t been uploaded?", isPresented: $closing) {
          Button("Discard and Close", role: .destructive) { Haptics.tap(); dismiss() }
        }
        .alert("Scan needs attention", isPresented: Binding(
          get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
          Button("OK") { error = nil }
        } message: { Text(error ?? "") }
      }
      .interactiveDismissDisabled()
    }

    @discardableResult
    private func finishDocument() -> Bool {
      guard pageCount > 0, let data = current.dataRepresentation() else {
        error = "The scan could not be converted to PDF."
        Haptics.failure()
        return false
      }
      documents.append(data)
      current = PDFDocument()
      pageCount = 0
      Haptics.success()
      return true
    }

    private func upload(dpi: Int) {
      Haptics.tap()
      uploading = true
      Task {
        let total = documents.count
        do {
          while let data = documents.first {
            status = "Uploading \(total - documents.count + 1) of \(total)…"
            let prepared = try await Task.detached { try ScanExport.prepare(data, dpi: dpi) }.value
            let uploaded = try await store.upload(prepared, name: "Scan.pdf", groupID: group.id) { message in
              status = message
            }
            onUploaded?(uploaded)
            documents.removeFirst()
          }
          status = "Uploaded. Reading and naming your PDFs."
          Haptics.success()
          if onUploaded != nil {
            uploading = false
            dismiss()
            return
          }
        } catch {
          if !isSilentCancellation(error) { self.error = error.localizedDescription }
          status = nil
          if !isSilentCancellation(error) { Haptics.failure() }
        }
        uploading = false
        try? await Task.sleep(for: .seconds(3))
        status = nil
      }
    }
  }

  struct DocumentCamera: UIViewControllerRepresentable {
    let completion: (Result<Data, Error>) -> Void
    let cancel: () -> Void
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
      let controller = VNDocumentCameraViewController()
      controller.delegate = context.coordinator
      return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, cancel: cancel) }
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
      let completion: (Result<Data, Error>) -> Void
      let cancel: () -> Void
      init(completion: @escaping (Result<Data, Error>) -> Void, cancel: @escaping () -> Void) {
        self.completion = completion
        self.cancel = cancel
      }
      func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        cancel()
      }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: Error
      ) { completion(.failure(error)) }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
      ) {
        let pdf = PDFDocument()
        for index in 0..<scan.pageCount {
          let image = scan.imageOfPage(at: index)
          // Camera captures have no paper DPI; use a consistent 300-DPI baseline.
          let bounds = CGRect(x: 0, y: 0, width: image.size.width * image.scale * 72 / 300,
            height: image.size.height * image.scale * 72 / 300)
          let pageData = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            image.draw(in: bounds)
          }
          guard let page = PDFDocument(data: pageData)?.page(at: 0) else {
            completion(.failure(APIError(message: "A scanned page could not be converted. Please scan these pages again.")))
            return
          }
          pdf.insert(page, at: pdf.pageCount)
        }
        guard let data = pdf.dataRepresentation(), pdf.pageCount > 0 else {
          completion(.failure(APIError(message: "The scan could not be converted to PDF.")))
          return
        }
        Haptics.success()
        completion(.success(data))
      }
    }
  }
#endif
