import PDFKit
import SwiftUI

/// Holds one filled copy while it's open: values save themselves, and the PDF redraws on this device.
@MainActor @Observable final class FormFillModel {
  enum SaveState: Equatable {
    case saved
    case saving
    case failed(String)
    /// Another device saved first or the form moved to signing, so saving again would overwrite it.
    case blocked(String)
  }
  var form: FilledForm
  var values: [String: JSONValue]
  var title: String
  var saveState = SaveState.saved
  var previewData: Data?
  /// Drawn before the preview appears, so an opened form is never seen without its answers.
  var firstPreview: FilledRevision?
  var problem: String?
  private var base: Data?
  private var dirty = false
  private var saveTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var flushing = false
  private let store: AppStore
  init(form: FilledForm, store: AppStore) {
    self.form = form
    self.store = store
    values = form.values
    title = form.title
  }
  var sections: [FormSection] { form.sections ?? [] }
  var isEditable: Bool { form.isDraft }
  var requiredProgress: (done: Int, total: Int) {
    let required = sections.flatMap(\.fields).filter { $0.required && $0.type != "signature" }
    let done = required.filter { field in
      switch FormRenderer.value(of: field, in: values) {
      case .string(let text)?: !text.isEmpty
      case .bool(let isOn)?: isOn
      default: false
      }
    }
    return (done.count, required.count)
  }
  func load() async {
    problem = nil
    do {
      form = try await store.completeForm(form)
      if form.isSigned {
        previewData = try await store.signedPDF(form)
      } else {
        let base = try await store.downloadPDF(url: form.pdfUrl, path: form.pdfPath ?? "")
        self.base = base
        let (sections, values) = (sections, values)
        // A failure here just opens the plain PDF; saving reports rendering problems separately.
        firstPreview = await Task.detached(priority: .userInitiated) {
          (try? FormRenderer.render(base: base, sections: sections, values: values))
            .map { FilledRevision(pdf: $0, sections: sections, values: values) }
        }.value
        previewData = base
      }
    } catch {
      if !isSilentCancellation(error) { problem = error.localizedDescription }
    }
  }
  func set(_ value: JSONValue?, for field: FormField) {
    values[field.id] = value ?? .null
    changed()
  }
  func setTitle(_ text: String) {
    title = text
    changed()
  }
  private func changed() {
    guard isEditable else { return }
    dirty = true
    saveTask?.cancel()
    // Typing settles before anything is sent, so a burst of keys costs one database write.
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
    refreshPreview(after: .milliseconds(350))
  }
  func flush() async {
    if case .blocked = saveState { return }
    guard dirty, !flushing, isEditable else { return }
    flushing = true
    defer { flushing = false }
    while dirty {
      dirty = false
      saveState = .saving
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      do {
        let saved = try await store.saveValues(of: form, values: values, title: trimmed.isEmpty ? form.title : trimmed)
        form.revision = saved.revision
        form.updatedAt = saved.updatedAt
        form.title = saved.title
        form.values = values
        store.update(form)
        saveState = .saved
      } catch {
        dirty = true
        saveState = (error as? APIError)?.status == 409
          ? .blocked(error.localizedDescription) : .failed(error.localizedDescription)
        return
      }
    }
  }
  func retrySave() {
    saveState = .saved
    Task { await flush() }
  }
  func refreshPreview(after delay: Duration) {
    guard let base else { return }
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      // Field ink updates in place; the original PDF bytes never change while typing.
      self.previewData = base
    }
  }
  func replaceSections(_ sections: [FormSection]) {
    form.sections = sections
    refreshPreview(after: .zero)
  }
}

/// A grouped form on one side and the real PDF filling in on the other. iPhone switches between them.
struct FormFillView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  private enum Pane: Hashable {
    case form
    case pdf
  }
  @State private var model: FormFillModel?
  @State private var pane = Pane.form
  @State private var addingToSigning = false
  @State private var requestingSignature = false
  @State private var layout: FormLayoutRequest?
  @State private var exportFile: ExportFile?
  @State private var exporting = false
  let form: FilledForm
  private var isRegular: Bool {
    #if os(macOS)
      true
    #else
      sizeClass != .compact
    #endif
  }
  var body: some View {
    NavigationStack {
      Group {
        if let model {
          content(model)
            #if os(macOS)
              .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                  Text(model.title.isEmpty ? form.title : model.title)
                    .font(.headline).lineLimit(1)
                  Spacer()
                  if model.isEditable { requestSignatureButton(model) }
                }.padding().background(.bar)
              }
            #else
              .navigationTitle(model.title.isEmpty ? form.title : model.title)
              .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar(model) }
            .sheet(isPresented: $addingToSigning) {
              AddToSigningView(forms: [model.form]) {
                model.form.status = "awaiting_signature"
              }.fullSheet().actionFeedback()
            }
            .sheet(item: $layout) { request in
              FormLayoutEditor(request: request) { model.replaceSections($0) }.wideSheet().actionFeedback()
            }
            .fileExporter(
              isPresented: $exporting, document: exportFile, contentType: .pdf,
              defaultFilename: model.form.exportName
            ) { result in
              if case .failure(let error) = result, !isSilentCancellation(error) {
                store.error = error.localizedDescription
              }
            }
            .onDisappear { Task { await model.flush() } }
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .task {
        if model == nil {
          let created = FormFillModel(form: form, store: store)
          model = created
          await created.load()
        }
      }
    }
  }
  @ViewBuilder private func content(_ model: FormFillModel) -> some View {
    if isRegular {
      HStack(spacing: 0) {
        FormPane(model: model, requestSignature: { requestSigning(model) }).frame(minWidth: 400, idealWidth: 440, maxWidth: 480)
        Divider()
        FilledPreviewPane(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      VStack(spacing: 0) {
        Picker("View", selection: $pane) {
          Text("Form").tag(Pane.form)
          Text("PDF").tag(Pane.pdf)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal).padding(.vertical, 8)
          .onChange(of: pane) { Haptics.tap() }
        if pane == .form {
          FormPane(model: model, requestSignature: { requestSigning(model) })
        } else {
          FilledPreviewPane(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }
  private func requestSignatureButton(_ model: FormFillModel) -> some View {
    Button("Request signature", systemImage: "signature") { requestSigning(model) }
      .labelStyle(.titleAndIcon)
      .buttonStyle(.borderedProminent)
      .disabled(store.busy != nil || requestingSignature)
      .accessibilityIdentifier("form-request-signature")
  }
  @ToolbarContentBuilder private func toolbar(_ model: FormFillModel) -> some ToolbarContent {
    #if os(iOS)
      if model.isEditable {
        ToolbarItem(placement: .topBarTrailing) { requestSignatureButton(model) }
      }
    #endif
    ToolbarItem(placement: .cancellationAction) {
      Button("Done") {
        Haptics.tap()
        Task {
          await model.flush()
          // Unsaved answers stay on screen so they can be retried instead of lost.
          if case .failed(let message) = model.saveState {
            store.error = "Your latest changes aren’t saved yet. \(message)"
          } else {
            dismiss()
          }
        }
      }
    }
    ToolbarItem(placement: .status) { SaveStatusView(model: model) }
    ToolbarItem(placement: formActionsPlacement) {
      Menu {
        Button(model.form.isSigned ? "Save signed PDF" : "Save filled PDF", systemImage: "square.and.arrow.down") {
          Task {
            await store.perform("Preparing PDF…", success: "PDF ready") {
              await model.flush()
              var current = model.form
              current.values = model.values
              let data = current.isSigned ? try await store.signedPDF(current) : try await store.filledPDF(current)
              exportFile = ExportFile(data: data, type: .pdf)
              exporting = true
            }
          }
        }
        if model.form.isDraft {
          Button("Add to signing request", systemImage: "signature") {
            requestSigning(model)
          }
          Divider()
          Button("Edit fields on PDF", systemImage: "rectangle.and.pencil.and.ellipsis") { editLayout(model) }
        }
      } label: {
        Image(systemName: "ellipsis")
      }.menuIndicator(.hidden).accessibilityLabel("Form actions")
    }
  }
  // Sheet primary actions appear in the bottom bar on macOS.
  private var formActionsPlacement: ToolbarItemPlacement {
    #if os(macOS)
      .navigation
    #else
      .primaryAction
    #endif
  }
  private func requestSigning(_ model: FormFillModel) {
    guard model.isEditable, !requestingSignature, store.busy == nil else { return }
    Haptics.tap()
    requestingSignature = true
    Task {
      defer { requestingSignature = false }
      await model.flush()
      guard case .saved = model.saveState else {
        store.error = "Save your latest changes before requesting a signature. Retry saving, then try again."
        return
      }
      addingToSigning = true
    }
  }
  private func editLayout(_ model: FormFillModel) {
    Haptics.tap()
    Task {
      await store.perform("Opening form fields…", success: "Ready") {
        let full = try await store.completeForm(model.form)
        let pdf = try await store.downloadPDF(url: full.pdfUrl, path: full.pdfPath ?? "")
        layout = FormLayoutRequest(
          template: FormTemplate(
            id: full.templateId, versionId: full.versionId, title: full.templateTitle ?? full.title, source: "ai",
            sections: full.sections ?? [], createdAt: full.createdAt, updatedAt: full.updatedAt),
          pdf: pdf, values: model.values)
      }
    }
  }
}
/// Autosave is quiet: a word in the toolbar, unless it needs the person's attention.
private struct SaveStatusView: View {
  let model: FormFillModel
  var body: some View {
    switch model.saveState {
    case .saved:
      if model.isEditable {
        Label("Saved", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.secondary)
          .labelStyle(.titleAndIcon)
      }
    case .saving:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Saving…").font(.caption).foregroundStyle(.secondary)
      }
    case .failed:
      Button("Not saved · Retry", systemImage: "exclamationmark.icloud") { model.retrySave() }
        .font(.caption).tint(.orange).labelStyle(.titleAndIcon)
    case .blocked(let message):
      Label(message, systemImage: "lock.icloud").font(.caption).foregroundStyle(.orange).lineLimit(2)
        .labelStyle(.titleAndIcon)
    }
  }
}
private struct FormPane: View {
  let model: FormFillModel
  let requestSignature: () -> Void
  var body: some View {
    Form {
      if !model.isEditable {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(model.form.statusText).fontWeight(.medium)
              Text(
                model.form.isSigned
                  ? "Signed \(FilledForm.dayText(model.form.signedAt ?? "")). It can no longer change."
                  : "In “\(model.form.signingRequestTitle ?? "a signing request")”. Remove it from the request to edit."
              ).font(.subheadline).foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: model.form.statusIcon).foregroundStyle(Color.buddyGreen)
          }
        }
      }
      Section {
        LabeledContent("Name") {
          TextField("Name", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
            .multilineTextAlignment(.trailing).labelsHidden()
        }.disabled(!model.isEditable)
        LabeledContent("PDF version", value: "Version \(model.form.versionNumber)")
        let progress = model.requiredProgress
        if progress.total > 0 {
          LabeledContent("Required") {
            Text("\(progress.done) of \(progress.total)")
              .foregroundStyle(progress.done == progress.total ? Color.buddyGreen : .secondary)
          }
        }
      }
      ForEach(model.sections) { section in
        Section {
          ForEach(section.fields) { field in
            FormFieldRow(field: field, model: model, requestSignature: requestSignature).disabled(!model.isEditable)
          }
        } header: {
          Text(section.title)
        } footer: {
          if let footer = section.footer, !footer.isEmpty { Text(footer) }
        }
      }
      if model.sections.flatMap(\.fields).isEmpty {
        ContentUnavailableView(
          "No fields yet", systemImage: "list.clipboard",
          description: Text("Choose Edit form fields from the menu to place them on the PDF."))
      }
    }.formStyle(.grouped)
    #if os(iOS)
      .scrollDismissesKeyboard(.interactively)
    #endif
  }
}
private struct FormFieldRow: View {
  let field: FormField
  let model: FormFillModel
  let requestSignature: () -> Void
  private var value: JSONValue? { FormRenderer.value(of: field, in: model.values) }
  private var text: Binding<String> {
    Binding(
      get: { if case .string(let text)? = value { text } else { "" } },
      set: { model.set(.string($0), for: field) })
  }
  /// A choice without options has nothing to pick from, so it's typed like text.
  private var kind: String { field.type == "choice" && field.options.isEmpty ? "text" : field.type }
  private var prompt: Text { Text(field.required ? "Required" : "Optional") }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
      if let help = field.help, !help.isEmpty {
        Text(help).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  @ViewBuilder private var control: some View {
    switch kind {
    case "multiline":
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label)
        TextField(field.label, text: text, prompt: prompt, axis: .vertical).lineLimit(3...10).labelsHidden()
      }
    case "number":
      labelled {
        TextField(field.label, text: text, prompt: prompt).labelsHidden().multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
      }
    case "date": dateRow
    case "checkbox":
      Toggle(
        field.label,
        isOn: Binding(
          get: { if case .bool(true)? = value { true } else { false } },
          set: {
            Haptics.tap()
            model.set(.bool($0), for: field)
          }))
    case "choice":
      Picker(field.label, selection: text) {
        Text("Not chosen").tag("")
        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
      }
    case "signature":
      Button(action: requestSignature) {
        HStack {
          Text(field.label).foregroundStyle(.primary)
          Spacer()
          Label("Request signature", systemImage: "signature")
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityHint("Opens a signing request for this form")

    default:
      labelled {
        TextField(field.label, text: text, prompt: prompt).labelsHidden().multilineTextAlignment(.trailing)
      }
    }
  }
  /// Short labels sit opposite their field like Settings; long ones get their own line.
  @ViewBuilder private func labelled<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if field.label.count > 26 {
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label)
        content()
      }
    } else {
      LabeledContent {
        content()
      } label: {
        Text(field.label)
      }
    }
  }
  private var selectedDate: Date? {
    guard case .string(let text)? = value, !text.isEmpty else { return nil }
    return try? Date(text, strategy: .iso8601.year().month().day())
  }
  @ViewBuilder private var dateRow: some View {
    if let selectedDate {
      HStack {
        DatePicker(
          field.label,
          selection: Binding(
            get: { selectedDate },
            set: { model.set(.string($0.formatted(.iso8601.year().month().day())), for: field) }),
          displayedComponents: .date)
        Button("Clear date", systemImage: "xmark.circle.fill") {
          Haptics.tap()
          model.set(.string(""), for: field)
        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
      }
    } else {
      LabeledContent {
        Button("Add date") {
          Haptics.tap()
          model.set(.string(Date.now.formatted(.iso8601.year().month().day())), for: field)
        }
      } label: {
        Text(field.label)
      }
    }
  }
}
private struct FilledPreviewPane: View {
  let model: FormFillModel
  var body: some View {
    Group {
      if let data = model.previewData {
        PDFPreview(
          data: data, sections: model.form.isSigned ? [] : model.sections, values: model.values,
          first: model.form.isSigned ? nil : model.firstPreview)
      } else if let problem = model.problem {
        ContentUnavailableView {
          Label("Couldn’t show the PDF", systemImage: "doc.questionmark")
        } description: {
          Text(problem)
        } actions: {
          Button("Try again") { Task { await model.load() } }
        }
      } else {
        ResourceLoadingView(title: "Preparing your PDF", subtitle: "Filling in what you’ve entered…")
      }
    }.accessibilityLabel("Filled PDF preview")
  }
}
