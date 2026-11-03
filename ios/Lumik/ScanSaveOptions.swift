import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Only used for newly captured image scans, never imported searchable PDFs.
enum ScanExport {
  static func prepare(_ data: Data, dpi: Int) throws -> Data {
    guard dpi > 0 else { return data }
    guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider) else {
      throw APIError(message: "The scan could not be read.")
    }
    let result = NSMutableData()
    guard let consumer = CGDataConsumer(data: result),
          let output = CGContext(consumer: consumer, mediaBox: nil, nil) else {
      throw APIError(message: "The PDF could not be prepared.")
    }
    for index in 1...source.numberOfPages {
      try autoreleasepool {
        guard let page = source.page(at: index) else { throw APIError(message: "A scanned page is missing.") }
        var box = page.getBoxRect(.mediaBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        if rotated { box.size = CGSize(width: box.height, height: box.width) }
        box.origin = .zero
        let scale = CGFloat(dpi) / 72
        let width = max(1, Int(ceil(box.width * scale)))
        let height = max(1, Int(ceil(box.height * scale)))
        guard width <= 20000, height <= 20000, width * height <= 80_000_000,
          let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
          throw APIError(message: "This page is too large. Choose Original or a lower resolution.")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // PDF drawing transforms do not upscale pages to larger destination rectangles.
        // Apply the pixel scale explicitly, then normalize rotation/origin in PDF points.
        bitmap.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        bitmap.concatenate(page.getDrawingTransform(.mediaBox,
          rect: box, rotate: 0, preserveAspectRatio: true))
        bitmap.drawPDFPage(page)
        let jpeg = NSMutableData()
        guard let image = bitmap.makeImage(),
          let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
          throw APIError(message: "A page could not be compressed.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
          let provider = CGDataProvider(data: jpeg),
          let encoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
          throw APIError(message: "A page could not be compressed.")
        }
        output.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
        output.draw(encoded, in: box)
        output.endPDFPage()
      }
    }
    output.closePDF()
    return result.length < data.count ? result as Data : data
  }
}

struct ScanSaveOptions: View {
  let count: Int
  let save: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var dpi = 0

  var body: some View {
    NavigationStack {
      Form {
        PDFProcessingPicker()
        Section("PDF Resolution") {
          Picker("Resolution", selection: $dpi) {
            Text("Original").tag(0)
            Text("150 DPI — Small").tag(150)
            Text("200 DPI — Balanced").tag(200)
            Text("300 DPI — High Quality").tag(300)
          }
          Text("Applies to all \(count) PDFs in this batch. Your scans stay unchanged until saved. If compression is larger, the original is used.")
            .font(.footnote).foregroundStyle(.secondary)
          Text("Higher resolution cannot restore detail missing from the scan.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Save PDFs")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Haptics.tap(); dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Haptics.tap(); dismiss(); save(dpi) }
        }
      }
    }
  }
}
