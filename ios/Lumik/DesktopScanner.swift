#if os(macOS)
import SwiftUI
import ImageCaptureCore
import PDFKit
import UniformTypeIdentifiers

struct ScannedDocument: Identifiable {
  let id = UUID()
  let url: URL
  var pages: Int
  var revision = 0
  let incomplete: Bool
}

/// Image Capture delegates deliver callbacks on the main thread.
@MainActor @Observable
final class DesktopScanner: NSObject, @preconcurrency ICDeviceBrowserDelegate,
  @preconcurrency ICScannerDeviceDelegate {
  var devices: [ICScannerDevice] = []
  var selected: ICScannerDevice?
  var ready = false
  var running = false
  var scanning = false
  var documents: [ScannedDocument] = []
  var error: String?
  var status = "Looking for scanners…" { didSet { statusRevision &+= 1 } }
  private(set) var statusRevision = 0
  var dpi = 300
  var color = 2
  var duplex = true
  var correctWhiteBalance = true
  var autoRotateAndCrop = true
  var processing = false
  private var pendingPages: [URL] = []
  var pageCount = 0
  private let browser = ICDeviceBrowser()
  private(set) var current = PDFDocument()
  private var pageFailure = false
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lumik-\(UUID())", isDirectory: true)
  var feeder: ICScannerFunctionalUnitDocumentFeeder? {
    selected?.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder
  }
  var resolutions: [Int] { selected.map { Array($0.selectedFunctionalUnit.supportedResolutions) } ?? [] }

  func discover() {
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.remote.rawValue)!
    browser.start()
  }
  func connect(_ scanner: ICScannerDevice) {
    guard !running && !scanning && !processing else { return }
    ready = false
    selected?.requestCloseSession()
    selected = scanner
    scanner.delegate = self
    status = "Connecting to \(scanner.name ?? "scanner")…"
    scanner.requestOpenSession()
  }
  func start() {
    guard ready, feeder != nil, !scanning, !running, !processing else { return }
    running = true
    scanNext()
  }
  func scanNext() {
    guard running, !scanning, let scanner = selected, let feeder else { return }
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { fail(error); return }
    feeder.resolution = dpi
    feeder.pixelDataType = ICScannerPixelDataType(rawValue: UInt(color)) ?? .RGB
    let depth = color == 0 ? 1 : 8
    guard feeder.supportedBitDepths.contains(depth) else {
      fail(APIError(message: "This scanner does not support the selected color mode. Choose another mode in Scan Settings.")); return
    }
    feeder.bitDepth = ICScannerBitDepth(rawValue: UInt(depth))!
    feeder.duplexScanningEnabled = duplex && feeder.supportsDuplexScanning
    scanner.transferMode = .fileBased
    scanner.downloadsDirectory = directory
    scanner.documentUTI = UTType.tiff.identifier
    scanner.documentName = UUID().uuidString
    scanning = true
    status = "Scanning document \(documents.count + 1)…"
    scanner.requestScan()
  }
  func stop() {
    running = false
    if scanning {
      status = "Stopping… Keeping completed pages."
      selected?.cancelScan()
    } else { status = "Stopped. Scan more pages or choose Done to finish this document." }
  }
  @discardableResult
  func finishDocument() -> Bool {
    guard !scanning, !processing, current.pageCount > 0 else { return false }
    saveCurrent(incomplete: pageFailure)
    guard current.pageCount == 0 else { return false }
    pageCount = 0
    pageFailure = false
    status = "Document finished. Ready to upload or start a new document."
    return true
  }
  func pagesChanged() {
    guard !scanning, !processing else { return }
    pageCount = current.pageCount
    if pageCount == 0 { pageFailure = false }
  }

  func updateDocument(_ id: UUID, data: Data, pages: Int) -> Bool {
    guard let index = documents.firstIndex(where: { $0.id == id }) else { return false }
    do {
      try data.write(to: documents[index].url, options: .atomic)
      documents[index].pages = pages
      documents[index].revision += 1
      status = "Scanned pages updated."
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  private func saveCurrent(incomplete: Bool) {
    guard current.pageCount > 0 else { return }
    let url = directory.appendingPathComponent("Scan-\(UUID().uuidString).pdf")
    if current.write(to: url) {
      documents.append(ScannedDocument(url: url, pages: current.pageCount, incomplete: incomplete))
      current = PDFDocument()
    } else {
      running = false
      error = "Could not save the scanned PDF. Free some disk space and try again."
    }
  }
  private func fail(_ failure: Error) {
    running = false
    error = failure.localizedDescription
    status = "Scanning paused. Check the scanner, then start again."
  }
  func shutdown() {
    stop()
    selected?.requestCloseSession()
    browser.stop()
    try? FileManager.default.removeItem(at: directory)
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let scanner = device as? ICScannerDevice else { return }
    devices.append(scanner)
    if selected == nil { connect(scanner) }
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    devices.removeAll { $0 === device }
    didRemove(device)
  }
  func didRemove(_ device: ICDevice) {
    guard selected === device else { return }
    stop()
    pageFailure = pageCount > 0
    scanning = false
    ready = false
    selected = nil
    error = "Scanner disconnected. Completed pages have been kept. Reconnect and select the scanner again."
  }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    guard device === selected else { return }
    if let error { fail(error) }
  }
  func deviceDidBecomeReady(_ device: ICDevice) {
    guard let scanner = device as? ICScannerDevice, scanner === selected else { return }
    guard scanner.availableFunctionalUnitTypes.contains(NSNumber(value: ICScannerFunctionalUnitType.documentFeeder.rawValue)) else {
      fail(APIError(message: "This workflow requires an automatic document feeder. Use Image Capture to scan from a flatbed, then import the PDF.")); return
    }
    scanner.requestSelect(.documentFeeder)
  }
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    guard device === selected else { return }
    ready = false
    if scanning { pageFailure = pageCount > 0 }
    scanning = false
    stop()
    if let error { fail(error) }
  }
  func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
    guard scanner === selected else { return }
    if let error { fail(error); return }
    ready = scanner.hasOpenSession && functionalUnit is ICScannerFunctionalUnitDocumentFeeder
    if !resolutions.contains(dpi) { dpi = resolutions.min(by: { abs($0 - 300) < abs($1 - 300) }) ?? Int(functionalUnit.resolution) }
    duplex = feeder?.supportsDuplexScanning == true
    status = "Ready. Load one document’s pages into the feeder."
  }
  func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
    guard scanning, scanner === selected else { return }
    pendingPages.append(url)
    guard !processing else { return }
    processing = true
    Task {
      while !pendingPages.isEmpty {
        let url = pendingPages.removeFirst()
        let whiteBalance = correctWhiteBalance
        let geometry = autoRotateAndCrop
        status = "Correcting scanned page \(pageCount + 1)…"
        let data = await Task.detached(priority: .userInitiated) {
          ScanImageProcessor.process(url: url, whiteBalance: whiteBalance, geometry: geometry)
        }.value
        // Keep the original page if enhancement fails; never drop a scan.
        if let image = data.flatMap({ NSImage(data: $0) }) ?? NSImage(contentsOf: url) {
          appendPage(image)
        } else {
          pageFailure = true
          error = "A scanned page could not be read. This document is incomplete; rescan it before uploading."
          stop()
        }
        try? FileManager.default.removeItem(at: url)
      }
      processing = false
      if !scanning { status = "\(pageCount) pages in this document. Scan more pages or choose Done." }
    }
  }

  private func appendPage(_ image: NSImage) {
    // Preserve physical paper size rather than treating pixels as PDF points.
    if let bitmap = image.representations.first {
      image.size = NSSize(width: Double(bitmap.pixelsWide) * 72 / Double(dpi), height: Double(bitmap.pixelsHigh) * 72 / Double(dpi))
    }
    guard let page = PDFPage(image: image) else {
      pageFailure = true
      error = "Could not convert a scanned page to PDF. Rescan this document."
      stop()
      return
    }
    current.insert(page, at: current.pageCount)
    pageCount = current.pageCount
    status = "Scanned \(pageCount) sides…"
  }
  func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
    guard scanning, scanner === selected else { return }
    scanning = false
    let stopped = !running
    running = false
    pageFailure = pageFailure || stopped || error != nil
    if let error, !stopped { fail(error); return }
    if processing {
      status = "Finishing page corrections…"
      return
    }
    status = pageCount > 0
      ? "\(pageCount) pages in this document. Scan more pages or choose Done."
      : "No pages scanned. Load the feeder and start scanning."
  }
}
#endif
