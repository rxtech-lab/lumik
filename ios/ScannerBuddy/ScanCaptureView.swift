#if os(iOS)
  import SwiftUI
  import VisionKit
  import PDFKit

  struct ScanCaptureView: View {
    let completion: (Result<Data, Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      if VNDocumentCameraViewController.isSupported {
        DocumentCamera(completion: completion, cancel: { dismiss() })
      } else {
        NavigationStack {
          ContentUnavailableView(
            "Camera scanning unavailable", systemImage: "camera",
            description: Text("Use a supported iPhone or iPad to scan, or import a PDF from Files.")
          ).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
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
          if let page = PDFPage(image: scan.imageOfPage(at: index)) {
            pdf.insert(page, at: pdf.pageCount)
          }
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
