#if os(macOS)
import SwiftUI
import ImageCaptureCore
import PDFKit
import UniformTypeIdentifiers
import OSLog

struct ScannedDocument: Identifiable {
  let id = UUID()
  let url: URL
  var pages: Int
  var revision = 0
  let incomplete: Bool
}

/// Owns the app's only device browser and is never stopped: once any
/// `ICDeviceBrowser` in the process has been stopped, browsers started later
/// report every device as removed and re-added about once a second.
@MainActor
private final class ScannerBrowser: NSObject, @preconcurrency ICDeviceBrowserDelegate {
  static let shared = ScannerBrowser()
  private let browser = ICDeviceBrowser()
  private var started = false
  private weak var owner: DesktopScanner?

  func attach(_ owner: DesktopScanner) {
    self.owner = owner
    guard started else {
      started = true
      browser.delegate = self
      browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.remote.rawValue)!
      browser.start()
      return
    }
    // Add events are not repeated, so hand over devices that are already known.
    for device in browser.devices ?? [] { owner.browserDidAdd(device) }
  }

  func detach(_ owner: DesktopScanner) {
    if self.owner === owner { self.owner = nil }
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    owner?.browserDidAdd(device)
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    owner?.browserDidRemove(device)
  }
}

/// Image Capture delegates deliver callbacks on the main thread.
@MainActor @Observable
final class DesktopScanner: NSObject, @preconcurrency ICScannerDeviceDelegate {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lumik", category: "DesktopScanner")
  private let diagnosticID = UUID().uuidString
  private var diagnosticSequence = 0

  /// Object identities correlate rediscovery without logging serial numbers or document paths.
  private func log(_ event: String, device: ICDevice? = nil, failure: Error? = nil) {
    diagnosticSequence += 1
    let target = device ?? selected
    let identity = target.map { String(describing: ObjectIdentifier($0)) } ?? "none"
    let selectedIdentity = selected.map { String(describing: ObjectIdentifier($0)) } ?? "none"
    let state = "instance=\(diagnosticID) seq=\(diagnosticSequence) event=\(event) device=\(identity) selected=\(selectedIdentity) open=\(target?.hasOpenSession ?? false) ready=\(ready) running=\(running) scanning=\(scanning) processing=\(processing) pages=\(pageCount) pending=\(pendingPages.count) devices=\(devices.count)"
    if let failure {
      let error = failure as NSError
      Self.logger.error("\(state, privacy: .public) errorDomain=\(error.domain, privacy: .public) errorCode=\(error.code) description=\(error.localizedDescription, privacy: .private)")
    } else {
      Self.logger.notice("\(state, privacy: .public)")
    }
  }

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
  var correctionCompleted = 0
  var correctionTotal = 0
  let liveFeed = ScanLiveFeed()
  private var pendingPages: [URL] = []
  var pageCount = 0
  private var discovering = false
  private var automaticallyConnect = true
  private(set) var connecting = false
  private var connectionError: String?

  func reconnect() {
    guard let device = selected ?? devices.first else { return }
    connect(device)
  }

  private func reportConnectionFailure(_ message: String) {
    connecting = false
    automaticallyConnect = false
    ready = false
    // Keep the first error until the user explicitly retries.
    if connectionError == nil {
      connectionError = message
      error = message
    }
    status = "Scanner unavailable. Choose Reconnect to try again."
  }
  private(set) var current = PDFDocument()
  private var pageFailure = false
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lumik-\(UUID())", isDirectory: true)
  var feeder: ICScannerFunctionalUnitDocumentFeeder? {
    selected?.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder
  }
  var resolutions: [Int] { selected.map { Array($0.selectedFunctionalUnit.supportedResolutions) } ?? [] }

  func discover() {
    guard !discovering else { return }
    discovering = true
    log("discovery.start")
    ScannerBrowser.shared.attach(self)
  }
  func connect(_ scanner: ICScannerDevice) {
    log("connect.request", device: scanner)
    guard discovering, !connecting, !running, !scanning, !processing else { return }
    guard devices.contains(where: { $0 === scanner }) else { return }
    if selected === scanner && ready { return }
    if error == connectionError { error = nil }
    connectionError = nil
    connecting = true
    ready = false
    let previous = selected
    selected = nil
    previous?.delegate = nil
    if previous !== scanner {
      log("session.closeRequested", device: previous)
      previous?.requestCloseSession()
    }
    selected = scanner
    scanner.delegate = self
    status = "Connecting to \(scanner.name ?? "scanner")…"
    log("session.openRequested", device: scanner)
    if scanner.hasOpenSession { deviceDidBecomeReady(scanner) }
    else { scanner.requestOpenSession() }
  }
  func start() {
    log("scan.startRequested")
    guard ready, feeder != nil, !scanning, !running, !processing else { return }
    correctionCompleted = 0
    correctionTotal = 0
    liveFeed.reset()
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
    log("scan.request dpi=\(dpi) color=\(color) duplex=\(feeder.duplexScanningEnabled)", device: scanner)
    scanner.requestScan()
  }
  func stop() {
    log("scan.stopRequested")
    running = false
    if scanning {
      status = "Stopping… Keeping completed pages."
      log("scan.cancelRequested")
      selected?.cancelScan()
    } else { status = "Stopped. Scan more pages or choose Done to finish this document." }
  }
  @discardableResult
  func finishDocument() -> Bool {
    guard !scanning, !processing, current.pageCount > 0 else { return false }
    saveCurrent(incomplete: pageFailure)
    guard current.pageCount == 0 else { return false }
    liveFeed.reset()
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
    log("failure", failure: failure)
    running = false
    error = failure.localizedDescription
    status = "Scanning paused. Check the scanner, then start again."
  }
  func shutdown() {
    guard discovering else { return }
    discovering = false
    connecting = false
    log("shutdown")
    stop()
    // A newer scanner instance may already own this device; leave its session alone.
    if let selected, selected.delegate === self {
      log("session.closeRequested")
      selected.requestCloseSession()
      selected.delegate = nil
    }
    selected = nil
    ready = false
    ScannerBrowser.shared.detach(self)
    devices.removeAll()
    log("discovery.detach")
    try? FileManager.default.removeItem(at: directory)
  }
  fileprivate func browserDidAdd(_ device: ICDevice) {
    log("browser.didAdd", device: device)
    guard discovering, let scanner = device as? ICScannerDevice else { return }
    if !devices.contains(where: { $0 === scanner }) { devices.append(scanner) }
    if selected == nil && automaticallyConnect {
      log("connect.automaticAfterDiscovery", device: scanner)
      connect(scanner)
    }
  }
  fileprivate func browserDidRemove(_ device: ICDevice) {
    log("browser.didRemove", device: device)
    devices.removeAll { $0 === device }
    didRemove(device)
  }
  func didRemove(_ device: ICDevice) {
    log("device.didRemove", device: device)
    guard discovering, selected === device else { return }
    stop()
    pageFailure = pageFailure || pageCount > 0 || processing
    scanning = false
    ready = false
    device.delegate = nil
    selected = nil
    devices.removeAll { $0 === device }
    log("disconnect.alert", device: device)
    reportConnectionFailure("Scanner disconnected. Completed pages have been kept. Choose Reconnect when the scanner is available.")
  }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    log("session.didOpen", device: device, failure: error)
    guard discovering, device === selected else { return }
    if let error { reportConnectionFailure(error.localizedDescription) }
  }
  func deviceDidBecomeReady(_ device: ICDevice) {
    log("device.didBecomeReady", device: device)
    guard discovering, connectionError == nil, let scanner = device as? ICScannerDevice, scanner === selected else { return }
    guard scanner.availableFunctionalUnitTypes.contains(NSNumber(value: ICScannerFunctionalUnitType.documentFeeder.rawValue)) else {
      reportConnectionFailure("This workflow requires an automatic document feeder. Use Image Capture to scan from a flatbed, then import the PDF."); return
    }
    log("feeder.selectRequested", device: scanner)
    scanner.requestSelect(.documentFeeder)
  }
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    log("session.didClose", device: device, failure: error)
    guard discovering, device === selected else { return }
    ready = false
    if scanning { pageFailure = pageCount > 0 }
    scanning = false
    stop()
    reportConnectionFailure(error?.localizedDescription ?? "Scanner session closed. Choose Reconnect to try again.")
  }
  func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
    log("feeder.didSelect", device: scanner, failure: error)
    guard discovering, connectionError == nil, scanner === selected else { return }
    if let error { reportConnectionFailure(error.localizedDescription); return }
    ready = scanner.hasOpenSession && functionalUnit is ICScannerFunctionalUnitDocumentFeeder
    guard ready else { return }
    connecting = false
    if self.error == connectionError { self.error = nil }
    connectionError = nil
    if !resolutions.contains(dpi) { dpi = resolutions.min(by: { abs($0 - 300) < abs($1 - 300) }) ?? Int(functionalUnit.resolution) }
    duplex = feeder?.supportsDuplexScanning == true
    status = "Ready. Load one document’s pages into the feeder."
  }
  func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
    log("scan.didReceivePage", device: scanner)
    guard scanning, scanner === selected else { return }
    correctionTotal += 1
    pendingPages.append(url)
    guard !processing else { return }
    processing = true
    Task {
      while !pendingPages.isEmpty {
        let url = pendingPages.removeFirst()
        let whiteBalance = correctWhiteBalance
        let geometry = autoRotateAndCrop
        let page = pageCount + 1
        let feed = liveFeed
        status = "Correcting scanned page \(pageCount + 1)…"
        let data = await Task.detached(priority: .userInitiated) {
          ScanImageProcessor.process(url: url, page: page, whiteBalance: whiteBalance, geometry: geometry) { frame in
            // The main queue is FIFO, so frames stay in pipeline order.
            DispatchQueue.main.async { MainActor.assumeIsolated { feed.enqueue(frame) } }
          }
        }.value
        // Keep the original page if enhancement fails; never drop a scan.
        if let image = data.flatMap({ NSImage(data: $0) }) ?? NSImage(contentsOf: url) {
          appendPage(image)
        } else {
          pageFailure = true
          error = "A scanned page could not be read. This document is incomplete; rescan it before uploading."
          stop()
        }
        correctionCompleted += 1
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
    log("scan.didComplete", device: scanner, failure: error)
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
