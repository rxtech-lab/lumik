import SwiftUI
import UniformTypeIdentifiers

/// What can be done to a filled form from any list it appears in.
enum FormAction: Hashable, Identifiable {
  case open(FilledForm)
  case addToSigning([FilledForm])
  case saveFilled(FilledForm)
  case saveSigned(FilledForm)
  case removeFromSigning(FilledForm)
  case delete(FilledForm)
  var id: Self { self }
}
private enum FormSheet: Identifiable {
  case fill(FilledForm)
  case signing([FilledForm])
  var id: String {
    switch self {
    case .fill(let form): "fill-\(form.id)"
    case .signing(let forms): "signing-\(forms.map(\.id).joined())"
    }
  }
}
/// Runs form actions, so every list offers the same sheets, downloads, and confirmations.
private struct FormActionHost: ViewModifier {
  @Binding var action: FormAction?
  @Environment(AppStore.self) private var store
  @State private var sheet: FormSheet?
  @State private var deleting: FilledForm?
  @State private var exportFile: ExportFile?
  @State private var exportName = ""
  @State private var exporting = false
  func body(content: Content) -> some View {
    content
      .onChange(of: action) {
        guard let action else { return }
        self.action = nil
        Haptics.tap()
        run(action)
      }
      .sheet(item: $sheet) { sheet in
        switch sheet {
        case .fill(let form): FormFillView(form: form).wideSheet().actionFeedback()
        case .signing(let forms): AddToSigningView(forms: forms).fullSheet().actionFeedback()
        }
      }
      .confirmationDialog(
        "Delete “\(deleting?.title ?? "")”?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible, presenting: deleting
      ) { form in
        Button("Delete", role: .destructive) {
          Task {
            await store.perform("Deleting form…", success: "Form deleted") { try await store.deleteForm(form) }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { form in
        Text(
          form.isSigned
            ? "This deletes the signed PDF too. The original PDF stays as it is."
            : "The original PDF and the form stay as they are.")
      }
      .fileExporter(
        isPresented: $exporting, document: exportFile, contentType: .pdf, defaultFilename: exportName
      ) { result in
        if case .failure(let error) = result, !isSilentCancellation(error) {
          store.error = error.localizedDescription
        }
      }
  }
  private func run(_ action: FormAction) {
    switch action {
    case .open(let form): sheet = .fill(form)
    case .addToSigning(let forms): sheet = .signing(forms)
    case .delete(let form): deleting = form
    case .saveFilled(let form): export(form, label: "Filling in your PDF…") { try await store.filledPDF(form) }
    case .saveSigned(let form): export(form, label: "Getting your signed PDF…") { try await store.signedPDF(form) }
    case .removeFromSigning(let form):
      Task {
        await store.perform("Removing from request…", success: "Back in your filled forms") {
          try await store.removeFromSigning(form)
        }
      }
    }
  }
  private func export(_ form: FilledForm, label: String, _ data: @escaping () async throws -> Data) {
    Task {
      await store.perform(label, success: "PDF ready") {
        exportFile = ExportFile(data: try await data(), type: .pdf)
        exportName = form.exportName
        exporting = true
      }
    }
  }
}
extension View {
  func formActions(_ action: Binding<FormAction?>) -> some View {
    modifier(FormActionHost(action: action))
  }
}
/// The context menu for one filled form. Every download is a fresh copy; the original isn't touched.
struct FormContextMenu: View {
  let form: FilledForm
  @Binding var action: FormAction?
  var body: some View {
    Button(form.isDraft ? "Open form" : "View form", systemImage: "doc.text") { action = .open(form) }
    Divider()
    if form.isSigned {
      Button("Download signed PDF", systemImage: "square.and.arrow.down") { action = .saveSigned(form) }
    } else {
      Button("Download filled PDF", systemImage: "square.and.arrow.down") { action = .saveFilled(form) }
    }
    if form.isDraft {
      Button("Add to signing request", systemImage: "signature") { action = .addToSigning([form]) }
    }
    if form.isAwaitingSignature {
      Button("Remove from signing request", systemImage: "arrow.uturn.backward") { action = .removeFromSigning(form) }
    }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { action = .delete(form) }
  }
}
struct FilledFormRow: View {
  let form: FilledForm
  var showsDocument = false
  private var tint: Color {
    switch form.status {
    case "signed": .buddyGreen
    case "awaiting_signature": .orange
    default: .indigo
    }
  }
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: form.statusIcon).foregroundStyle(tint).frame(width: 36, height: 36)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(showsDocument ? form.documentName : form.title).lineLimit(2).truncationMode(.middle)
        Text(
          showsDocument
            ? "\(form.title) · \(form.statusText)"
            : "\(form.statusText) · Version \(form.versionNumber) · \(form.updatedText)"
        ).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
    }.padding(.vertical, 1).accessibilityElement(children: .combine)
  }
}
/// A filled and a signed form on the PDF's page, each opening with a tap.
struct DocumentFormsSection: View {
  let workspace: DocumentWorkspace
  @Binding var action: FormAction?
  @Binding var layout: FormLayoutRequest?
  @Environment(AppStore.self) private var store
  private var filled: [FilledForm] { workspace.forms.filter { !$0.isSigned } }
  private var signed: [FilledForm] { workspace.forms.filter(\.isSigned) }
  var body: some View {
    if !workspace.forms.isEmpty || workspace.currentTemplate != nil {
      Section("Forms") {
        ForEach(filled) { row($0) }
        if let template = workspace.currentTemplate {
          Button("New filled copy", systemImage: "plus") {
            Task {
              var created: FilledForm?
              let succeeded = await store.perform("Starting a copy…", success: "Ready to fill") {
                created = try await store.newForm(of: template, document: workspace.document)
              }
              if succeeded, let created { action = .open(created) }
            }
          }
          Button("Edit form fields", systemImage: "rectangle.and.pencil.and.ellipsis") {
            Task {
              await store.perform("Opening form fields…", success: "Ready") {
                layout = FormLayoutRequest(template: template, pdf: try await store.currentPDF(of: workspace.document))
              }
            }
          }
        }
      }
    }
    if !signed.isEmpty {
      Section("Signed") {
        ForEach(signed) { row($0) }
      }
    }
  }
  private func row(_ form: FilledForm) -> some View {
    Button {
      action = .open(form)
    } label: {
      FilledFormRow(form: form).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { FormContextMenu(form: form, action: $action) }
  }
}
/// Every filled and signed form in a group. Several can go to signing at once.
struct GroupFormsView: View {
  let group: ScanGroup
  @Environment(AppStore.self) private var store
  @State private var action: FormAction?
  @State private var selection = Set<String>()
  private var waiting: [FilledForm] { store.groupForms.filter(\.isAwaitingSignature) }
  private var filled: [FilledForm] { store.groupForms.filter(\.isDraft) }
  private var signed: [FilledForm] { store.groupForms.filter(\.isSigned) }
  private var selectedDrafts: [FilledForm] { filled.filter { selection.contains($0.id) } }
  var body: some View {
    List(selection: $selection) {
      section("Filled", filled, footer: "Select several to send them to signing together.")
      section("Waiting for signature", waiting, footer: nil)
      section("Signed", signed, footer: nil)
    }
    #if os(iOS)
      .listStyle(.insetGrouped)
    #else
      .listStyle(.inset)
    #endif
    .overlay {
      if store.groupForms.isEmpty {
        ContentUnavailableView(
          "No forms yet", systemImage: "list.clipboard",
          description: Text("Open a PDF and choose Create form to fill it in."))
      }
    }
    .navigationTitle("Forms")
    .navigationSubtitle(group.name)
    .contextMenu(forSelectionType: String.self) { ids in
      if let form = store.groupForms.first(where: { ids.contains($0.id) }) {
        FormContextMenu(form: form, action: $action)
      }
    } primaryAction: { ids in
      if let form = store.groupForms.first(where: { ids.contains($0.id) }) { action = .open(form) }
    }
    .toolbar {
      #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
      #endif
      ToolbarItem(placement: .primaryAction) {
        Button("Add to signing", systemImage: "signature") {
          action = .addToSigning(selectedDrafts)
        }.disabled(selectedDrafts.isEmpty)
      }
    }
    .formActions($action)
    .refreshable { await store.loadGroupPage(group.id) }
  }
  @ViewBuilder private func section(_ title: String, _ forms: [FilledForm], footer: String?) -> some View {
    if !forms.isEmpty {
      Section {
        ForEach(forms) { form in
          FilledFormRow(form: form, showsDocument: true).tag(form.id)
            .swipeActions(allowsFullSwipe: false) {
              SwipeDeleteButton { action = .delete(form) }
            }
        }
      } header: {
        Text(title)
      } footer: {
        if let footer { Text(footer) }
      }
    }
  }
}
