#if os(macOS)
import SwiftUI
import PDFKit

/// Owns the batch and scanner session; individual documents have their own sheet.
struct DesktopScanView: View {
  let group: ScanGroup
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var scanner = DesktopScanner()
  @State private var capturing = false
  @State private var closing = false
  @State private var uploading = false
  @State private var progress: String?
  @State private var preview: ScannedDocument?
  @State private var deleting: ScannedDocument?
  @State private var confirmPartial = false
  @State private var notice: String?

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if scanner.documents.isEmpty {
          ContentUnavailableView {
            Label("Scan Documents", systemImage: "doc.viewfinder")
          } description: {
            Text("Scan each document as one multipage PDF, then save the batch to \(group.name).")
          }
        } else {
          List {
            Section("PDFs for \(group.name)") {
              ForEach(Array(scanner.documents.enumerated()), id: \.element.id) { index, document in
                ScannedDocumentRow(number: index + 1, document: document, disabled: uploading,
                  review: { preview = document }, discard: { deleting = document })
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .disabled(uploading)
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(spacing: 0) {
          HStack {
            Text("Scan Documents")
              .font(.title2.bold())
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(scanner.documents.isEmpty ? "Scan Document" : "Scan More", systemImage: "scanner") {
              capturing = true
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
            .disabled(uploading)
          }
          .padding(20)
          Divider()
        }
        .background(.bar)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        // Keep every batch action visible; macOS sheets can collapse a
        // confirmationAction toolbar group to its first button.
        VStack(spacing: 0) {
          Divider()
          HStack(spacing: 12) {
            Button("Close") {
              if scanner.documents.isEmpty { dismiss() } else { closing = true }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if !scanner.documents.isEmpty {
              Button(scanner.documents.count == 1 ? "Save PDF" : "Save \(scanner.documents.count) PDFs") {
                if scanner.documents.contains(where: \.incomplete) { confirmPartial = true }
                else { uploadBatch() }
              }
              .buttonStyle(.borderedProminent)
              .keyboardShortcut(.defaultAction)
            }
          }
          .controlSize(.large)
          .padding(20)
        }
        .background(.bar)
        .disabled(uploading)
      }
      .overlay(alignment: .top) {
        ScanStatusOverlay(message: progress ?? notice, working: uploading)
      }
      .sheet(isPresented: $capturing) { MultipageScanSheet(scanner: scanner).fullSheet() }
      .sheet(item: $preview) { document in
        if let data = try? Data(contentsOf: document.url) {
          ScanDocumentEditorSheet(data: data) { data, pages in
            let saved = scanner.updateDocument(document.id, data: data, pages: pages)
            if saved { notice = "Scanned pages updated." }
            return saved
          }.fullSheet()
        }
      }
      .confirmationDialog("Discard all scans that haven’t been saved?", isPresented: $closing, titleVisibility: .visible) {
        Button("Discard and Close", role: .destructive) { dismiss() }
      }
      .confirmationDialog("Save partial scans? Review them first to check for missing pages.", isPresented: $confirmPartial, titleVisibility: .visible) {
        Button("Save Anyway") { uploadBatch() }
      }
      .confirmationDialog("Discard this scanned document?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        Button("Discard", role: .destructive) {
          if let deleting {
            try? FileManager.default.removeItem(at: deleting.url)
            scanner.documents.removeAll { $0.id == deleting.id }
            notice = "Scan discarded."
          }
          deleting = nil
        }
      }
      .alert("Something needs attention", isPresented: Binding(get: { !capturing && scanner.error != nil }, set: { if !$0 { scanner.error = nil } })) {
        Button("OK") { scanner.error = nil }
      } message: { Text(scanner.error ?? "") }
    }
    .disabled(uploading)
    .interactiveDismissDisabled()
    .onAppear { scanner.discover() }
    .onDisappear { scanner.shutdown() }
    .task(id: notice) {
      guard notice != nil else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      notice = nil
    }
  }

  private func uploadBatch() {
    uploading = true
    let batch = scanner.documents
    Task {
      var failures = 0
      for (index, document) in batch.enumerated() {
        progress = "Saving PDF \(index + 1) of \(batch.count)…"
        do {
          // The upload endpoint automatically analyzes and names each PDF.
          try await store.upload(Data(contentsOf: document.url), name: "Scan.pdf", groupID: group.id)
          scanner.documents.removeAll { $0.id == document.id }
          try? FileManager.default.removeItem(at: document.url)
        } catch {
          failures += 1
          scanner.error = error.localizedDescription
        }
      }
      uploading = false
      progress = nil
      if failures == 0 {
        let message = "PDFs uploaded. Automatically analyzing and naming your documents."
        store.notice = message
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(4))
          if store.notice == message { store.notice = nil }
        }
        dismiss()
      } else {
        notice = "\(failures) PDFs could not be saved. Save again to retry."
      }
    }
  }
}

private struct MultipageScanSheet: View {
  @Bindable var scanner: DesktopScanner
  @Environment(\.dismiss) private var dismiss
  @State private var settings = false
  @State private var statusVisible = false
  private var busy: Bool { scanner.running || scanner.scanning || scanner.processing }
  private var configuration: String {
    "\(scanner.color == 2 ? "Color" : scanner.color == 1 ? "Grayscale" : "Black & white") · \(scanner.dpi) DPI · \(scanner.duplex ? "Two-sided" : "One-sided")"
  }
  private var state: (label: String, color: Color) {
    if scanner.processing && !scanner.scanning { return ("Correcting pages", .blue) }
    if busy { return ("Scanning", .blue) }
    if scanner.ready { return ("Ready", .green) }
    return (scanner.devices.isEmpty ? "Looking for scanners" : "Not ready", .orange)
  }

  var body: some View {
    NavigationStack {
      Group {
        if scanner.pageCount > 0 {
          ScanPageEditor(document: scanner.current, pageCount: scanner.pageCount,
            editable: !busy, changed: { scanner.pagesChanged() })
        } else {
          Form {
            Section { deviceRow; settingsRow }
            Section {
              Text("Load the pages of one document into the feeder. Scan More adds pages to this PDF. Close finishes the document and returns to your batch.")
                .foregroundStyle(.secondary)
            }
          }.formStyle(.grouped)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Document \(scanner.documents.count + 1)")
      .navigationSubtitle(scanner.pageCount == 0 ? "Multipage scan" : "\(scanner.pageCount) pages")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            if scanner.pageCount == 0 || scanner.finishDocument() { dismiss() }
          }.disabled(busy)
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Scan Settings", systemImage: "slider.horizontal.3") { settings = true }
            .disabled(!scanner.ready || busy)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if busy {
            Button("Stop Scanning") { scanner.stop() }.disabled(!scanner.running)
          } else {
            Button(scanner.pageCount == 0 ? "Start Scanning" : "Scan More") { scanner.start() }
              .keyboardShortcut(.defaultAction)
              .disabled(!scanner.ready)
          }
        }
      }
      .overlay(alignment: .top) {
        ScanStatusOverlay(message: busy || statusVisible ? scanner.status : nil, working: busy)
      }
      .sheet(isPresented: $settings) { ScannerSettings(scanner: scanner).fullSheet() }
      .alert("Scanner needs attention", isPresented: Binding(get: { scanner.error != nil }, set: { if !$0 { scanner.error = nil } })) {
        Button("OK") { scanner.error = nil }
      } message: { Text(scanner.error ?? "") }
    }
    .interactiveDismissDisabled()
    .task(id: scanner.statusRevision) {
      statusVisible = true
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      statusVisible = false
    }
  }

  private var deviceRow: some View {
    HStack(spacing: 12) {
      Image(systemName: "scanner")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 42, height: 42)
        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 2) {
        Text(scanner.selected?.name ?? "No Scanner").font(.headline)
        HStack(spacing: 6) {
          Circle().fill(state.color).frame(width: 7, height: 7)
          Text(state.label).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if scanner.devices.count > 1 || (scanner.selected == nil && !scanner.devices.isEmpty) {
        Picker("Device", selection: Binding(
          get: { scanner.selected?.uuidString ?? "" },
          set: { id in if let device = scanner.devices.first(where: { $0.uuidString == id }) { scanner.connect(device) } }
        )) {
          ForEach(scanner.devices, id: \.uuidString) { device in
            Text(device.name ?? "Scanner").tag(device.uuidString ?? "")
          }
        }
        .labelsHidden().fixedSize()
        .disabled(busy)
      }
    }
    .padding(.vertical, 2)
  }

  private var settingsRow: some View {
    Button { settings = true } label: {
      LabeledContent("Scan Settings") {
        HStack(spacing: 6) {
          Text(configuration)
          Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!scanner.ready || busy)
    .accessibilityLabel("Scan Settings")
    .accessibilityValue(configuration)
  }

}

private struct ScanStatusOverlay: View {
  let message: String?
  var working = false
  var body: some View {
    if let message {
      HStack(spacing: 8) {
        if working { ProgressView().controlSize(.small) }
        Text(message)
      }
      .font(.callout.weight(.medium))
      .padding(.horizontal, 14).padding(.vertical, 9)
      .glassEffect(.regular, in: .capsule)
      .padding(8)
      .allowsHitTesting(false)
    }
  }
}

private struct ScannedDocumentRow: View {
  let number: Int
  let document: ScannedDocument
  let disabled: Bool
  let review: () -> Void
  let discard: () -> Void
  @State private var thumbnail: NSImage?

  var body: some View {
    HStack(spacing: 12) {
      Button(action: review) {
        HStack(spacing: 12) {
          Group {
            if let thumbnail {
              Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
              Rectangle().fill(.quaternary)
            }
          }
          .frame(width: 34, height: 44)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
          VStack(alignment: .leading, spacing: 2) {
            Text("Document \(number)")
            if document.incomplete {
              Label("Partial scan. Review for missing pages.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
            } else {
              Text("\(document.pages) \(document.pages == 1 ? "side" : "sides")")
                .font(.subheadline).foregroundStyle(.secondary)
            }
          }
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Review Document \(number)")
      Menu {
        Button("Review PDF", systemImage: "doc.text.magnifyingglass", action: review)
        Button("Discard", systemImage: "trash", role: .destructive, action: discard)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Scan actions")
      .disabled(disabled)
    }
    .task(id: document.revision) {
      thumbnail = PDFDocument(url: document.url)?.page(at: 0)?.thumbnail(of: CGSize(width: 68, height: 88), for: .mediaBox)
    }
  }
}

private struct ScannerSettings: View {
  @Bindable var scanner: DesktopScanner
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Picker("Color mode", selection: $scanner.color) {
          Text("Color").tag(2)
          Text("Grayscale").tag(1)
          Text("Black & white").tag(0)
        }
        Picker("Resolution", selection: $scanner.dpi) {
          ForEach(scanner.resolutions, id: \.self) { Text("\($0) DPI").tag($0) }
        }
        Section("Page Corrections") {
          Toggle("Correct white balance", isOn: $scanner.correctWhiteBalance)
            .toggleStyle(.checkbox)
          Toggle("Automatically rotate and crop", isOn: $scanner.autoRotateAndCrop)
            .toggleStyle(.checkbox)
          Text("Correct paper color, straighten page edges, and turn readable text upright using on-device processing. Pages stay unchanged when detection is uncertain. Applies to new scans.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Toggle("Scan both sides automatically", isOn: $scanner.duplex)
          .disabled(scanner.feeder?.supportsDuplexScanning != true)
        if scanner.feeder?.supportsDuplexScanning != true {
          Text("The scanner’s driver does not report duplex support.").foregroundStyle(.secondary)
        }
        Text("Higher resolutions produce larger PDFs. Each uploaded PDF must be under 20 MB. Paper size follows the scanner’s current feeder setting.").font(.footnote).foregroundStyle(.secondary)
      }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Scan Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}

#endif
