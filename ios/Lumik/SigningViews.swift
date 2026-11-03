import PDFKit
import SwiftUI

/// Every signing request: what's waiting, then what's finished.
struct SigningRequestsView: View {
  @Environment(AppStore.self) private var store
  @State private var loaded = false
  @State private var deleting: SigningRequest?
  private var pending: [SigningRequest] { store.signingRequests.filter(\.isPending) }
  private var completed: [SigningRequest] { store.signingRequests.filter { !$0.isPending } }
  var body: some View {
    List {
      section("Waiting for you", pending)
      section("Completed", completed)
    }
    #if os(iOS)
      .listStyle(.insetGrouped)
    #else
      .listStyle(.inset)
    #endif
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
      await store.loadSigningRequests()
      loaded = true
    }
    .refreshable { await store.loadSigningRequests() }
    .confirmationDialog(
      "Delete “\(deleting?.title ?? "")”?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
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
  @ViewBuilder private func section(_ title: String, _ requests: [SigningRequest]) -> some View {
    if !requests.isEmpty {
      Section(title) {
        ForEach(requests) { request in
          NavigationLink {
            SigningRequestDetailView(requestID: request.id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: request.isPending ? "signature" : "checkmark.seal.fill")
                .foregroundStyle(request.isPending ? Color.orange : .buddyGreen).frame(width: 36, height: 36)
                .background(
                  (request.isPending ? Color.orange : .buddyGreen).opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 9, style: .continuous))
              VStack(alignment: .leading, spacing: 2) {
                Text(request.title).lineLimit(2)
                Text("\(request.summary) · \(FilledForm.dayText(request.createdAt))")
                  .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
              }
            }.padding(.vertical, 1)
          }
          .contextMenu {
            Button("Delete request", systemImage: "trash", role: .destructive) {
              Haptics.tap()
              deleting = request
            }
          }
          .swipeActions(allowsFullSwipe: false) {
            SwipeDeleteButton {
              Haptics.tap()
              deleting = request
            }
          }
        }
      }
    }
  }
}
/// One request's PDFs, ready to sign together.
struct SigningRequestDetailView: View {
  let requestID: String
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var action: FormAction?
  @State private var signing = false
  private var request: SigningRequest? { store.signingRequests.first { $0.id == requestID } }
  var body: some View {
    Group {
      if let request {
        List {
          if !request.unsigned.isEmpty {
            Section("To sign") { rows(request.unsigned) }
          }
          let signed = request.forms.filter(\.isSigned)
          if !signed.isEmpty {
            Section("Signed") { rows(signed) }
          }
        }
        #if os(iOS)
          .listStyle(.insetGrouped)
        #else
          .listStyle(.inset)
        #endif
        .navigationTitle(request.title)
        .toolbar {
          if !request.unsigned.isEmpty {
            ToolbarItem(placement: .primaryAction) {
              Button(request.unsigned.count == 1 ? "Sign PDF" : "Sign \(request.unsigned.count) PDFs", systemImage: "signature") {
                Haptics.tap()
                signing = true
              }.labelStyle(.titleAndIcon).buttonStyle(.borderedProminent)
            }
          }
        }
        .sheet(isPresented: $signing) {
          SigningSessionView(request: request).fullSheet().actionFeedback()
        }
        .formActions($action)
      } else {
        // It closes with its last form.
        Color.clear.onAppear { dismiss() }
      }
    }
  }
  private func rows(_ forms: [FilledForm]) -> some View {
    ForEach(forms) { form in
      Button {
        action = .open(form)
      } label: {
        FilledFormRow(form: form, showsDocument: true).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contextMenu { FormContextMenu(form: form, action: $action) }
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
          if let art { SignatureArtView(art: art).frame(height: 70) }
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
        let data = try await store.downloadPDF(url: form.pdfUrl, path: form.pdfPath ?? "")
        placements[form.id] = defaultPlacements(form, pdf: data)
        pdfs[form.id] = data
      }
    } catch {
      if !isSilentCancellation(error) { problem = error.localizedDescription }
    }
  }
  private func defaultPlacements(_ form: FilledForm, pdf: Data) -> [FormPlacement] {
    let fields = (form.sections ?? []).flatMap(\.fields).filter { $0.type == "signature" }
    let widgets = (try? FormRenderer.widgets(in: pdf).widgets) ?? []
    let lines = fields.flatMap { field -> [FormPlacement] in
      let matching = widgets.filter { field.widgets.contains($0.name) && $0.kind == "signature" }
      if !matching.isEmpty {
        return matching.map { FormPlacement(page: $0.page, x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
      }
      return field.placements
    }
    let pageCount = PDFDocument(data: pdf)?.pageCount ?? 0
    return Array(Set(lines)).filter {
      $0.page >= 0 && $0.page < pageCount && $0.x.isFinite && $0.y.isFinite
        && $0.w > 0 && $0.h > 0 && $0.x >= 0 && $0.y >= 0
        && $0.x + $0.w <= 1.001 && $0.y + $0.h <= 1.001
    }.sorted { $0.page == $1.page ? $0.y < $1.y : $0.page < $1.page }
  }

  private func sign() {
    guard let art else { return }
    Task {
      if await store.perform("Signing…", success: chosenForms.count == 1 ? "PDF signed" : "\(chosenForms.count) PDFs signed", {
        try await store.sign(chosenForms, in: request, art: art, placements: placements, pdfs: pdfs)
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
  var body: some View {
    ZStack(alignment: .bottom) {
      Color.secondary.opacity(0.1)
      if let document {
        PDFPageSurface(document: document, page: page) { size in
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
              SignatureArtView(art: art)
            }
          }
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
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Confirm locations") {
          Haptics.tap()
          onConfirm()
          dismiss()
        }.disabled(placements.isEmpty)
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
      document = PDFDocument(data: pdf)
      if let first = placements.first { page = first.page }
    }
  }
}
