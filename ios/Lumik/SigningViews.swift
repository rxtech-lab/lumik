import PDFKit
import SwiftUI

/// Every signing request: what's waiting, then what's finished.
struct SigningRequestsView: View {
  @Environment(AppStore.self) private var store
  @State private var loaded = false
  @State private var deleting: SigningRequest?
  @State private var opened: OpenedRequest?
  private struct OpenedRequest: Identifiable {
    let id: String
  }
  private var pending: [SigningRequest] { store.signingRequests.filter(\.isPending) }
  private var completed: [SigningRequest] { store.signingRequests.filter { !$0.isPending } }
  var body: some View {
    requestList
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay {
      if store.signingRequests.isEmpty {
        if loaded {
          ContentUnavailableView(
            "Nothing to sign", systemImage: "signature",
            description: Text("Fill in a form, then choose Add to signing request from its menu."))
        } else {
          ProgressView()
        }
      }
    }
    .navigationTitle("Signing")
    .toolbar { ToolbarItem(placement: .primaryAction) { AgentToolbarButton() } }
    .task {
      if !store.hasLoadedSigningRequests { await store.loadSigningRequests() }
      loaded = true
    }
    .refreshable { await store.loadSigningRequests() }
    .sheet(item: $opened) { SigningRequestSheet(requestID: $0.id).wideSheet().actionFeedback() }
    .deleteSigningRequestDialog($deleting)
  }
  @ViewBuilder private var requestList: some View {
    #if os(macOS)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          desktopSection("Waiting for you", pending)
          desktopSection("Completed", completed)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    #else
      List {
        section("Waiting for you", pending)
        section("Completed", completed)
      }
      .listStyle(.insetGrouped)
    #endif
  }
  #if os(macOS)
    @ViewBuilder private func desktopSection(_ title: String, _ requests: [SigningRequest]) -> some View {
      if !requests.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(title).font(.headline).foregroundStyle(.secondary)
          VStack(spacing: 0) {
            ForEach(requests) { request in
              requestButton(request)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
              if request.id != requests.last?.id { Divider().padding(.leading, 60) }
            }
          }
          .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
      }
    }
  #endif
  @ViewBuilder private func section(_ title: String, _ requests: [SigningRequest]) -> some View {
    if !requests.isEmpty {
      Section(title) {
        ForEach(requests) { request in
          requestButton(request)
        }
      }
    }
  }
  private func requestButton(_ request: SigningRequest) -> some View {
    Button {
      Haptics.tap()
      opened = OpenedRequest(id: request.id)
    } label: {
      SigningRequestRow(request: request)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this request to review and sign")
    .contextMenu {
      Button("Delete request", systemImage: "trash", role: .destructive) {
        Haptics.tap()
        deleting = request
      }
    }
    #if os(iOS)
    .swipeActions(allowsFullSwipe: false) {
      SwipeDeleteButton {
        Haptics.tap()
        deleting = request
      }
    }
    #endif
  }

}
struct SigningRequestRow: View {
  let request: SigningRequest
  private var tint: Color { request.isPending ? .orange : .buddyGreen }
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: request.isPending ? "signature" : "checkmark.seal.fill")
        .foregroundStyle(tint).frame(width: 36, height: 36)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(request.title).lineLimit(2)
        Text("\(request.summary) · \(FilledForm.dayText(request.createdAt))")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(request.isPending ? "To sign" : "Signed")
        .font(.caption.weight(.semibold)).foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
    }
    .frame(minHeight: 44)
    .padding(.vertical, 4)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
extension View {
  func deleteSigningRequestDialog(_ request: Binding<SigningRequest?>) -> some View {
    modifier(DeleteSigningRequestDialog(request: request))
  }
}
private struct DeleteSigningRequestDialog: ViewModifier {
  @Binding var request: SigningRequest?
  @Environment(AppStore.self) private var store
  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Delete “\(request?.title ?? "")”?",
      isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
      titleVisibility: .visible, presenting: request
    ) { request in
      Button("Delete request", role: .destructive) {
        Task {
          await store.perform("Deleting request…", success: "Request deleted") {
            try await store.deleteSigningRequest(request)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Unsigned forms go back to your filled forms. Signed PDFs are kept.")
    }
  }
}
/// A request opens straight onto its PDF, ready to sign. Several PDFs share one switcher.
struct SigningRequestSheet: View {
  let requestID: String
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var selectedFormID: String?
  @State private var action: FormAction?
  @State private var signing = false
  @State private var deleting: SigningRequest?
  @State private var pdf: LoadedPDF?
  @State private var problem: String?
  @State private var attempt = 0
  private struct LoadedPDF {
    let key: String
    let data: Data
  }
  private var request: SigningRequest? { store.signingRequests.first { $0.id == requestID } }
  /// What still needs signing comes first, so that's what opens.
  private var forms: [FilledForm] {
    let all = request?.forms ?? []
    return all.filter { !$0.isSigned } + all.filter(\.isSigned)
  }
  private var form: FilledForm? { forms.first { $0.id == selectedFormID } ?? forms.first }
  private func key(of form: FilledForm) -> String { "\(form.id)-\(form.status)-\(form.updatedAt)-\(attempt)" }
  var body: some View {
    NavigationStack {
      Group {
        if let request, let form {
          VStack(spacing: 0) {
            header(form)
            Divider()
            preview(form)
          }
          .navigationTitle(request.title)
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar { toolbar(request, form: form) }
          .sheet(isPresented: $signing) {
            SigningSessionView(request: request).fullSheet().actionFeedback()
          }
          .formActions($action)
          .deleteSigningRequestDialog($deleting)
          .task(id: key(of: form)) { await load(form) }
        } else {
          // It closes with its last form.
          Color.clear.onAppear { dismiss() }
        }
      }
    }
  }
  private func header(_ form: FilledForm) -> some View {
    HStack(spacing: 12) {
      if forms.count > 1 {
        Picker("PDF", selection: Binding(get: { form.id }, set: { id in
          Haptics.tap()
          selectedFormID = id
        })) {
          ForEach(forms) { option in
            Text("\(option.documentName) · \(option.statusText)").tag(option.id)
          }
        }.pickerStyle(.menu).labelsHidden()
      } else {
        Text(form.documentName).font(.subheadline).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Text(form.statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
    }.padding(.horizontal).padding(.vertical, 10)
  }
  @ViewBuilder private func preview(_ form: FilledForm) -> some View {
    if let pdf, pdf.key == key(of: form) {
      PDFPreview(data: pdf.data).id(pdf.key)
    } else if let problem {
      ContentUnavailableView {
        Label("Couldn’t show the PDF", systemImage: "doc.questionmark")
      } description: {
        Text(problem)
      } actions: {
        Button("Try again") {
          Haptics.tap()
          attempt += 1
        }
      }
    } else {
      ResourceLoadingView()
    }
  }
  @ToolbarContentBuilder private func toolbar(_ request: SigningRequest, form: FilledForm) -> some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Done") {
        Haptics.tap()
        dismiss()
      }
    }
    ToolbarItem(placement: actionsPlacement) {
      Menu {
        FormContextMenu(form: form, action: $action)
        Divider()
        Button("Delete request", systemImage: "trash", role: .destructive) {
          Haptics.tap()
          deleting = request
        }
      } label: {
        Image(systemName: "ellipsis")
      }.menuIndicator(.hidden).accessibilityLabel("More actions")
    }
    if !request.unsigned.isEmpty {
      ToolbarItem(placement: .confirmationAction) {
        Button(request.unsigned.count == 1 ? "Sign PDF" : "Sign \(request.unsigned.count) PDFs", systemImage: "signature") {
          Haptics.tap()
          signing = true
        }.labelStyle(.titleAndIcon).buttonStyle(.borderedProminent).disabled(store.busy != nil)
      }
    }
  }
  // Sheet primary actions appear in the bottom bar on macOS.
  private var actionsPlacement: ToolbarItemPlacement {
    #if os(macOS)
      .navigation
    #else
      .primaryAction
    #endif
  }
  private func load(_ form: FilledForm) async {
    problem = nil
    do {
      let complete = try await store.completeForm(form)
      let data: Data
      if complete.isSigned {
        data = try await store.signedPDF(complete)
      } else {
        let base = try await store.downloadPDF(url: complete.pdfUrl, path: complete.pdfPath ?? "")
        let locations = SignatureLocations.placements(complete, pdf: base)
        let filled = try await store.filledPDF(complete)
        data = SignatureLocations.highlightedPreview(filled, placements: locations)
      }
      try Task.checkCancellation()
      pdf = LoadedPDF(key: key(of: form), data: data)
    } catch {
      if !isSilentCancellation(error) { problem = error.localizedDescription }
    }
  }
}
/// Sends filled forms to a new or waiting signing request. They can't be edited until removed.
struct AddToSigningView: View {
  let forms: [FilledForm]
  var onAdded: () -> Void = {}
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var requestID = ""
  @State private var title = ""
  private var pending: [SigningRequest] { store.signingRequests.filter(\.isPending) }
  var body: some View {
    NavigationStack {
      Form {
        Section(forms.count == 1 ? "PDF to sign" : "\(forms.count) PDFs to sign") {
          ForEach(forms) { form in
            LabeledContent(form.documentName, value: form.title)
          }
        }
        Section {
          Picker("Request", selection: $requestID) {
            Text("New request").tag("")
            ForEach(pending) { Text($0.title).tag($0.id) }
          }
          if requestID.isEmpty {
            TextField("Request name", text: $title, prompt: Text("Optional"))
          }
        } footer: {
          Text("Forms in a request can’t be edited. Remove one from the request to change it.")
        }
      }.formStyle(.grouped).navigationTitle("Add to Signing")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Add") { add() }.disabled(store.busy != nil || forms.isEmpty)
          }
        }
        .task { if store.signingRequests.isEmpty { await store.loadSigningRequests() } }
    }
  }
  private func add() {
    Task {
      let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if await store.perform("Adding to signing…", success: "Added to signing", {
        try await store.addToSigning(forms, requestID: requestID.isEmpty ? nil : requestID, title: name.isEmpty ? nil : name)
      }) {
        onAdded()
        dismiss()
      }
    }
  }
}
/// Capture one signature, check where it lands on each PDF, then sign them all at once.
struct SigningSessionView: View {
  let request: SigningRequest
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var art: SignatureArt?
  @State private var chosen: Set<String>
  @State private var placements: [String: [FormPlacement]] = [:]
  @State private var pdfs: [String: Data] = [:]
  @State private var problem: String?
  @State private var reviewed: Set<String> = []
  init(request: SigningRequest) {
    self.request = request
    _chosen = State(initialValue: Set(request.unsigned.map(\.id)))
  }
  private var forms: [FilledForm] { request.unsigned }
  private var chosenForms: [FilledForm] { forms.filter { chosen.contains($0.id) } }
  var body: some View {
    NavigationStack {
      Group {
        if art == nil {
          SignatureCaptureView { art = $0; reviewed.removeAll() }
        } else {
          review
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .interactiveDismissDisabled()
    .task { await loadPDFs() }
  }
  private var review: some View {
    Form {
      Section {
        HStack {
          if let art { SignatureArtView(art: art).frame(height: 70).signaturePaper() }
          Button("Change") {
            Haptics.tap()
            art = nil
          }
        }
      } header: {
        Text("Your signature")
      }
      Section {
        ForEach(forms) { form in
          HStack(spacing: 12) {
            Toggle(form.documentName, isOn: Binding(
              get: { chosen.contains(form.id) },
              set: { isOn in
                Haptics.tap()
                if isOn { chosen.insert(form.id) } else { chosen.remove(form.id) }
              }
            )).labelsHidden()
              #if os(macOS)
                .toggleStyle(.checkbox)
              #endif
            NavigationLink {
              if let art, let data = pdfs[form.id] {
                SignaturePlacementView(
                  title: form.documentName, pdf: data, art: art,
                  placements: Binding(get: { placements[form.id] ?? [] }, set: { placements[form.id] = $0; reviewed.remove(form.id) }),
                  onConfirm: { reviewed.insert(form.id) })
              }
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(form.documentName).lineLimit(1).truncationMode(.middle)
                Text(placementSummary(form)).font(.subheadline).foregroundStyle(.secondary)
              }
            }.disabled(pdfs[form.id] == nil)
          }
        }
      } header: {
        Text("PDFs")
      } footer: {
        if let problem {
          Text(problem).foregroundStyle(.red)
        } else {
          Text("Open each PDF to review and confirm the signature locations. If no signature field was found, add a signature on the correct line.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Review & Sign")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(chosenForms.count == 1 ? "Sign" : "Sign \(chosenForms.count)") { sign() }
          .disabled(chosenForms.isEmpty || store.busy != nil || chosenForms.contains { pdfs[$0.id] == nil || !reviewed.contains($0.id) || (placements[$0.id] ?? []).isEmpty })
      }
    }
  }
  private func placementSummary(_ form: FilledForm) -> String {
    guard pdfs[form.id] != nil else { return "Loading…" }
    let count = placements[form.id]?.count ?? 0
    if count == 0 { return "Choose where to sign" }
    return "\(count) signature location(s) · " + (reviewed.contains(form.id) ? "Confirmed" : "Review required")
  }
  private func loadPDFs() async {
    do {
      for form in forms {
        let complete = try await store.completeForm(form)
        let base = try await store.downloadPDF(url: complete.pdfUrl, path: complete.pdfPath ?? "")
        placements[form.id] = SignatureLocations.placements(complete, pdf: base)
        // Preview and sign the same filled page, including all current answers.
        pdfs[form.id] = try await store.filledPDF(complete)
      }
    } catch {
      if !isSilentCancellation(error) { problem = error.localizedDescription }
    }
  }

  private func sign() {
    guard let art else { return }
    Task {
      if await store.perform("Signing…", success: chosenForms.count == 1 ? "PDF signed" : "\(chosenForms.count) PDFs signed", {
        try await store.sign(chosenForms, in: request, art: art, placements: placements, pdfs: pdfs, alreadyFilled: true)
      }) {
        dismiss()
      }
    }
  }
}
/// Drag the signature where it belongs on any page, and add it to more than one place.
private struct SignaturePlacementView: View {
  let title: String
  let pdf: Data
  let art: SignatureArt
  @Binding var placements: [FormPlacement]
  var onConfirm: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var document: PDFDocument?
  @State private var page = 0
  @State private var selected: Int?
  @State private var renderProblem: String?
  @State private var zoom: CGFloat = 1
  @State private var pinchStart: CGFloat?

  private func changeZoom(_ value: CGFloat) {
    zoom = min(max(value, 1), 6)
  }
  var body: some View {
    ZStack(alignment: .bottom) {
      Color.secondary.opacity(0.1)
      if let document {
        GeometryReader { canvas in
          let pageSize = document.page(at: page).map(FormRenderer.displaySize(of:)) ?? CGSize(width: 612, height: 792)
          let fit = min(canvas.size.width / max(pageSize.width, 1), canvas.size.height / max(pageSize.height, 1))
          ScrollView([.horizontal, .vertical]) {
            PDFPageSurface(document: document, page: page, resolution: min(1500 * zoom, 4500)) { size in
              ForEach(placements.indices.filter { placements[$0].page == page }, id: \.self) { index in
                DraggablePlacement(
                  placement: Binding(
                    get: { placements.indices.contains(index) ? placements[index] : FormPlacement(page: page, x: 0, y: 0, w: 0, h: 0) },
                    set: { value in if placements.indices.contains(index) { placements[index] = value } }),
                  pageSize: size, isSelected: selected == index, tint: .indigo,
                  minimumSide: 0.02,
                  onSelect: {
                    Haptics.tap()
                    selected = index
                  }
                ) {
                  Color.clear
                    .overlay { Rectangle().strokeBorder(Color.indigo, lineWidth: selected == index ? 3 : 2) }
                }
              }
            }
            .frame(width: pageSize.width * fit * zoom, height: pageSize.height * fit * zoom)
            .frame(minWidth: canvas.size.width, minHeight: canvas.size.height)
          }
          .simultaneousGesture(
            MagnifyGesture().onChanged { value in
              if pinchStart == nil { pinchStart = zoom }
              changeZoom((pinchStart ?? 1) * value.magnification)
            }.onEnded { _ in pinchStart = nil }
          )
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 64)
        .id(page)
        PagePager(page: $page, count: document.pageCount).padding(.bottom, 14)
      } else {
        ProgressView()
      }
    }
    .navigationTitle(title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onChange(of: page) { _, _ in
      selected = placements.indices.first { placements[$0].page == page }
      zoom = 1
      pinchStart = nil
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button("Zoom out", systemImage: "minus.magnifyingglass") {
          Haptics.tap()
          changeZoom(zoom / 1.25)
        }.disabled(zoom <= 1)
        Button("\(Int(zoom * 100))%", systemImage: "arrow.up.left.and.arrow.down.right") {
          Haptics.tap()
          changeZoom(1)
        }.help("Fit PDF to the window")
        Button("Zoom in", systemImage: "plus.magnifyingglass") {
          Haptics.tap()
          changeZoom(zoom * 1.25)
        }.disabled(zoom >= 6)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Confirm locations") {
          Haptics.tap()
          onConfirm()
          dismiss()
        }.disabled(placements.isEmpty || renderProblem != nil)
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Add signature here", systemImage: "plus") {
          Haptics.tap()
          placements.append(FormPlacement(page: page, x: 0.33, y: 0.45, w: 0.34, h: 0.08))
          selected = placements.count - 1
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Remove signature", systemImage: "trash") {
          Haptics.tap()
          if let selected, placements.indices.contains(selected) { placements.remove(at: selected) }
          selected = nil
        }.disabled(selected == nil)
      }
    }
    .task {
      if let first = placements.first { page = first.page; selected = 0 }
    }
    .task(id: placements) {
      do {
        let stamps = placements.map { SignatureStamp(art: art, placement: $0) }
        let rendered = try FormRenderer.render(base: pdf, sections: [], values: [:], stamps: stamps)
        document = PDFDocument(data: rendered)
        renderProblem = nil
      } catch {
        renderProblem = error.localizedDescription
      }
    }
    .overlay(alignment: .top) {
      if let renderProblem {
        Text(renderProblem).foregroundStyle(.red).padding().background(.regularMaterial)
      }
    }
  }
}

/// Preview annotations never enter the signing, upload, or export paths.
private enum SignatureLocations {
  static func placements(_ form: FilledForm, pdf: Data) -> [FormPlacement] {
    let fields = (form.sections ?? []).flatMap(\.fields).filter { $0.type == "signature" }
    let widgets = (try? FormRenderer.widgets(in: pdf).widgets) ?? []
    let lines = fields.flatMap { field -> [FormPlacement] in
      // The form owns its signature locations, including corrections saved in the field editor.
      // Only consult embedded PDF widgets when the form has no saved locations.
      if !field.placements.isEmpty { return field.placements }
      return widgets.filter { field.widgets.contains($0.name) && $0.kind == "signature" }
        .map { FormPlacement(page: $0.page, x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
    }
    let pageCount = PDFDocument(data: pdf)?.pageCount ?? 0
    return Array(Set(lines)).filter {
      $0.page >= 0 && $0.page < pageCount && $0.x.isFinite && $0.y.isFinite
        && $0.w > 0 && $0.h > 0 && $0.x >= 0 && $0.y >= 0
        && $0.x + $0.w <= 1.001 && $0.y + $0.h <= 1.001
    }.sorted { $0.page == $1.page ? $0.y < $1.y : $0.page < $1.page }
  }

  static func highlightedPreview(_ data: Data, placements: [FormPlacement]) -> Data {
    guard let document = PDFDocument(data: data) else { return data }
    for placement in placements {
      guard let page = document.page(at: placement.page) else { continue }
      let displayRect = FormRenderer.rect(of: placement, pageSize: FormRenderer.displaySize(of: page))
      let bounds = displayRect.applying(page.transform(for: .cropBox).inverted())
      let box = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
      #if os(macOS)
        box.color = .systemIndigo
        box.interiorColor = NSColor.systemIndigo.withAlphaComponent(0.12)
      #else
        box.color = .systemIndigo
        box.interiorColor = UIColor.systemIndigo.withAlphaComponent(0.12)
      #endif
      let border = PDFBorder()
      border.lineWidth = 2
      box.border = border
      box.contents = "Sign here"
      box.shouldPrint = false
      page.addAnnotation(box)
    }
    return document.dataRepresentation() ?? data
  }
}
