import Foundation

/// Forms, signing, and versions. Pages read through one request; PDFs come straight from storage.
extension AppStore {
  // MARK: PDFs
  /// A presigned link costs the API nothing and has no size limit. An expired one falls back to the API.
  func downloadPDF(url: String?, path: String) async throws -> Data {
    if let cachedPDF, cachedPDF.path == path { return cachedPDF.data }
    var result: Data?
    if let url, let remote = URL(string: url),
      let (data, response) = try? await URLSession.shared.data(from: remote),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.starts(with: Data("%PDF-".utf8))
    {
      result = data
    }
    let data: Data
    if let result { data = result } else { data = try await request(path) }
    cachedPDF = (path, data)
    return data
  }
  func currentPDF(of document: ScanDocument) async throws -> Data {
    if workspace?.document.id != document.id { _ = try await loadWorkspace(document) }
    guard let version = workspace?.currentVersion else { throw APIError(message: "This document has no PDF.") }
    return try await downloadPDF(url: version.pdfUrl, path: version.pdfPath)
  }
  /// A filled PDF is never stored: it is drawn here from the untouched original and the saved values.
  func filledPDF(_ form: FilledForm) async throws -> Data {
    let form = try await completeForm(form)
    if form.isSigned { return try await signedPDF(form) }
    let base = try await downloadPDF(url: form.pdfUrl, path: form.pdfPath ?? "")
    let sections = form.sections ?? []
    let values = form.values
    return try await Task.detached(priority: .userInitiated) {
      try FormRenderer.render(base: base, sections: sections, values: values)
    }.value
  }
  func signedPDF(_ form: FilledForm) async throws -> Data {
    let form = try await completeForm(form)
    guard let path = form.signedPdfPath else { throw APIError(message: "This form hasn’t been signed yet.") }
    return try await downloadPDF(url: form.signedPdfUrl, path: path)
  }
  /// Lists leave out the template and links until a form is actually opened.
  func completeForm(_ form: FilledForm) async throws -> FilledForm {
    if form.isComplete { return form }
    return try await fetch(FilledForm.self, "forms/\(form.id)")
  }

  // MARK: Workspace
  @discardableResult func loadWorkspace(_ document: ScanDocument) async throws -> DocumentWorkspace {
    if isPreview {
      let preview = DocumentWorkspace(
        document: document,
        versions: [
          DocumentVersion(
            id: document.id, number: 1, name: document.originalName, size: document.size,
            createdAt: document.createdAt, isCurrent: true, pdfPath: "documents/\(document.id)/pdf")
        ], templates: [], forms: [])
      workspace = preview
      return preview
    }
    let result = try await fetch(DocumentWorkspace.self, "documents/\(document.id)/workspace").joined()
    apply(result)
    return result
  }
  /// Shows a new read, and picks up reading a version that just became current.
  func apply(_ result: DocumentWorkspace) {
    workspace = result
    if let index = documents.firstIndex(where: { $0.id == result.document.id }) {
      documents[index] = result.document
    }
    if result.document.status == "processing", selectedGroupID == result.document.groupId {
      documentPoll?.cancel()
      pollProcessingDocuments(result.document.groupId)
    }
  }
  /// Keeps every list showing the same copy of a form without reading it again.
  func update(_ form: FilledForm) {
    if let index = workspace?.forms.firstIndex(where: { $0.id == form.id }) {
      workspace?.forms[index] = form
    } else if workspace?.document.id == form.documentId {
      workspace?.forms.insert(form, at: 0)
    }
    if let index = groupForms.firstIndex(where: { $0.id == form.id }) {
      groupForms[index] = form
    } else if selectedGroupID == form.groupId {
      groupForms.insert(form, at: 0)
    }
  }

  // MARK: Forms
  /// The saved form when there is one. Otherwise reads the PDF once and saves the form for next time.
  func openOrCreateForm(_ document: ScanDocument, pdf: Data, regenerate: Bool = false) async throws -> FilledForm {
    if !regenerate, let current = workspace, current.document.id == document.id, let template = current.currentTemplate {
      if let draft = current.latestDraft { return draft }
      busy = "Creating a draft…"
      actionActivity.append("Saved template loaded")
      actionActivity.append("Creating form draft on server…")
      return try await newForm(of: template, document: document)
    }
    struct Request: Encodable {
      var regenerate: Bool
      var pageCount: Int
      var widgets: [PDFWidgetInfo]
      var textRegions: [FormPlacement]
    }
    busy = "Inspecting PDF fields…"
    actionActivity.append("PDFKit · Inspecting pages and embedded fields…")
    let scan = try await Task.detached(priority: .userInitiated) {
      let fields = try FormRenderer.widgets(in: pdf)
      return (pageCount: fields.pageCount, widgets: fields.widgets, textRegions: try FormRenderer.textRegions(in: pdf))
    }.value
    actionActivity[0] = "PDFKit · Inspected \(scan.pageCount) pages, found \(scan.widgets.count) embedded fields"
    busy = "Building your form…"
    actionActivity.append("Form service · Requested field analysis and draft creation…")
    let response = try await request(
      "documents/\(document.id)/form-template", method: "POST",
      body: JSONEncoder().encode(Request(regenerate: regenerate, pageCount: scan.pageCount, widgets: scan.widgets, textRegions: scan.textRegions)),
      progress: { message in
        self.busy = message
        self.actionActivity.append(message)
        if self.actionActivity.count > 30 { self.actionActivity.removeFirst() }
      })
    let created = try JSONDecoder().decode(FormTemplateCreated.self, from: response)
    if workspace?.document.id == document.id, workspace?.templates.contains(where: { $0.id == created.template.id }) == false {
      workspace?.templates.insert(created.template, at: 0)
    }
    actionActivity[actionActivity.count - 1] = "Form service · Form received"
    busy = "Opening form…"
    actionActivity.append("Preparing saved fields for editing…")
    update(created.form)
    return created.form
  }
  func newForm(of template: FormTemplate, document: ScanDocument, title: String? = nil) async throws -> FilledForm {
    struct Request: Encodable {
      var templateId: String
      var title: String?
    }
    let form = try await fetch(
      FilledForm.self, "documents/\(document.id)/forms", method: "POST",
      body: JSONEncoder().encode(Request(templateId: template.id, title: title)))
    update(form)
    return form
  }
  func saveValues(of form: FilledForm, values: [String: JSONValue], title: String) async throws -> FormValuesSaved {
    struct Request: Encodable {
      var revision: Int
      var title: String
      var values: [String: JSONValue]
    }
    return try await fetch(
      FormValuesSaved.self, "forms/\(form.id)", method: "PATCH",
      body: JSONEncoder().encode(Request(revision: form.revision, title: title, values: values)))
  }
  func deleteForm(_ form: FilledForm) async throws {
    _ = try await request("forms/\(form.id)", method: "DELETE")
    workspace?.forms.removeAll { $0.id == form.id }
    groupForms.removeAll { $0.id == form.id }
    if let index = signingRequests.firstIndex(where: { $0.id == form.signingRequestId }) {
      signingRequests[index].forms.removeAll { $0.id == form.id }
      if signingRequests[index].forms.isEmpty { signingRequests.remove(at: index) }
    }
  }
  func saveTemplate(_ template: FormTemplate, title: String, sections: [FormSection]) async throws {
    struct Request: Encodable {
      var title: String
      var sections: [FormSection]
    }
    let saved = try await fetch(
      FormTemplateUpdate.self, "form-templates/\(template.id)", method: "PATCH",
      body: JSONEncoder().encode(Request(title: title, sections: sections)))
    if let index = workspace?.templates.firstIndex(where: { $0.id == template.id }) {
      workspace?.templates[index].title = saved.title
      workspace?.templates[index].sections = saved.sections
      workspace?.templates[index].updatedAt = saved.updatedAt
      if let joined = workspace?.joined() { workspace = joined }
    }
  }

  // MARK: Signing
  func loadSigningRequests() async {
    if isPreview { return }
    do {
      signingRequests = try await fetch(SigningRequestList.self, "signing-requests").requests
    } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription }
    }
  }
  /// The reply already holds the updated list, so nothing needs reading again.
  private func applySigning(_ list: SigningRequestList) {
    signingRequests = list.requests
    for form in list.requests.flatMap(\.forms) { update(form) }
  }
  private func returnToDrafts(_ forms: [FilledForm]) {
    for var form in forms where !form.isSigned {
      form.status = "draft"
      form.signingRequestId = nil
      form.signingRequestTitle = nil
      update(form)
    }
  }
  func addToSigning(_ forms: [FilledForm], requestID: String?, title: String?) async throws {
    struct Request: Encodable {
      var formIds: [String]
      var requestId: String?
      var title: String?
    }
    applySigning(
      try await fetch(
        SigningRequestList.self, "signing-requests", method: "POST",
        body: JSONEncoder().encode(Request(formIds: forms.map(\.id), requestId: requestID, title: title))))
  }
  func removeFromSigning(_ form: FilledForm) async throws {
    guard let requestID = form.signingRequestId else { return }
    applySigning(
      try await fetch(
        SigningRequestList.self, "signing-requests/\(requestID)/remove", method: "POST",
        body: JSONEncoder().encode(["formId": form.id])))
    returnToDrafts([form])
  }
  func deleteSigningRequest(_ request: SigningRequest) async throws {
    applySigning(try await fetch(SigningRequestList.self, "signing-requests/\(request.id)", method: "DELETE"))
    returnToDrafts(request.forms)
  }
  /// Draws each signed PDF here, uploads them directly to storage, and records them all with one call.
  func sign(
    _ forms: [FilledForm], in request: SigningRequest, art: SignatureArt,
    placements: [String: [FormPlacement]], pdfs: [String: Data], alreadyFilled: Bool = false
  ) async throws {
    struct Signed {
      var form: FilledForm
      var data: Data
    }
    var signed: [Signed] = []
    for (index, form) in forms.enumerated() {
      busy = "Signing \(index + 1) of \(forms.count)…"
      guard let base = pdfs[form.id] else { throw APIError(message: "Couldn’t load \(form.documentName).") }
      let stamps = (placements[form.id] ?? []).map { SignatureStamp(art: art, placement: $0) }
      guard !stamps.isEmpty else { throw FormRenderError.invalidSignaturePlacement }
      let sections = alreadyFilled ? [] : (form.sections ?? [])
      let values: [String: JSONValue] = alreadyFilled ? [:] : form.values
      let data = try await Task.detached(priority: .userInitiated) {
        try FormRenderer.render(base: base, sections: sections, values: values, stamps: stamps)
      }.value
      signed.append(Signed(form: form, data: data))
    }
    struct Ticket: Decodable {
      var formId: String
      var uploadId: String
      var url: URL
    }
    struct Tickets: Decodable {
      var mode: String
      var uploads: [Ticket]
    }
    struct UploadRequest: Encodable {
      struct Item: Encodable {
        var formId: String
        var size: Int
      }
      var items: [Item]
    }
    struct CompleteRequest: Encodable {
      struct Item: Encodable {
        var formId: String
        var uploadId: String
        var method: String
      }
      var items: [Item]
    }
    busy = "Uploading signed PDFs…"
    let tickets = try await fetch(
      Tickets.self, "signing-requests/\(request.id)/uploads", method: "POST",
      body: JSONEncoder().encode(
        UploadRequest(items: signed.map { .init(formId: $0.form.id, size: $0.data.count) })))
    guard tickets.mode == "direct" else {
      try await signThroughAPI(signed.map { ($0.form, $0.data) }, method: art.method)
      return
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for ticket in tickets.uploads {
        guard let data = signed.first(where: { $0.form.id == ticket.formId })?.data else { continue }
        group.addTask {
          var upload = URLRequest(url: ticket.url)
          upload.httpMethod = "PUT"
          upload.timeoutInterval = 300
          upload.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
          let (_, response) = try await URLSession.shared.upload(for: upload, from: data)
          guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Uploading a signed PDF failed. Please sign again to retry.")
          }
        }
      }
      try await group.waitForAll()
    }
    busy = "Saving signatures…"
    applySigning(
      try await fetch(
        SigningRequestList.self, "signing-requests/\(request.id)/complete", method: "POST",
        body: JSONEncoder().encode(
          CompleteRequest(
            items: tickets.uploads.map { .init(formId: $0.formId, uploadId: $0.uploadId, method: art.method) }))))
  }
  /// Local development stores files on disk, with no presigned URLs.
  private func signThroughAPI(_ items: [(FilledForm, Data)], method: String) async throws {
    for (form, data) in items {
      let boundary = UUID().uuidString
      var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"method\"\r\n\r\n\(method)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"signed.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
      body.append(data)
      body.append(Data("\r\n--\(boundary)--\r\n".utf8))
      let reply = try await request(
        "forms/\(form.id)/sign", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
      applySigning(try JSONDecoder().decode(SigningRequestList.self, from: reply))
    }
  }

  // MARK: Versions
  /// Uploads straight to storage, so the file's size never matters to the API.
  func uploadVersion(_ data: Data, name: String, of document: ScanDocument, makeCurrent: Bool) async throws {
    struct Ticket: Decodable {
      let mode: String
      let id: String?
      let url: URL?
    }
    let ticketBody = try JSONSerialization.data(withJSONObject: ["name": name, "size": data.count])
    let ticket = try await fetch(Ticket.self, "documents/\(document.id)/versions/uploads", method: "POST", body: ticketBody)
    if ticket.mode == "direct", let id = ticket.id, let url = ticket.url {
      var upload = URLRequest(url: url)
      upload.httpMethod = "PUT"
      upload.timeoutInterval = 300
      upload.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
      let report: @MainActor @Sendable (String) -> Void = { [weak self] message in self?.busy = message }
      report(PDFUploadProgress.message(sent: 0, total: Int64(data.count)))
      let delegate = PDFUploadProgress(total: Int64(data.count), report: report)
      let (_, response) = try await URLSession.shared.upload(for: upload, from: data, delegate: delegate)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw APIError(message: "PDF upload failed. Please upload again to retry.")
      }
      busy = "Saving new version…"
      apply(
        try await fetch(
          DocumentWorkspace.self, "documents/\(document.id)/versions/uploads/\(id)/complete", method: "POST",
          body: JSONEncoder().encode(["makeCurrent": makeCurrent])
        ).joined())
      return
    }
    let boundary = UUID().uuidString
    let safeName = name.filter { !"\"\r\n".contains($0) }
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"makeCurrent\"\r\n\r\n\(makeCurrent)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let reply = try await request(
      "documents/\(document.id)/versions", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    apply(try JSONDecoder().decode(DocumentWorkspace.self, from: reply).joined())
  }
  func setCurrentVersion(_ version: DocumentVersion, of document: ScanDocument) async throws {
    apply(
      try await fetch(DocumentWorkspace.self, "documents/\(document.id)/versions/\(version.id)/current", method: "POST").joined())
  }
  func deleteVersion(_ version: DocumentVersion, of document: ScanDocument) async throws {
    apply(
      try await fetch(DocumentWorkspace.self, "documents/\(document.id)/versions/\(version.id)", method: "DELETE").joined())
  }
}
extension FilledForm {
  static func summary(of forms: [FilledForm]) -> String {
    let signed = forms.filter(\.isSigned).count
    let waiting = forms.filter(\.isAwaitingSignature).count
    let filled = forms.count - signed - waiting
    return [
      filled > 0 ? "\(filled) filled" : nil, waiting > 0 ? "\(waiting) to sign" : nil,
      signed > 0 ? "\(signed) signed" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
  }
  var statusText: String {
    switch status {
    case "awaiting_signature": "Waiting for signature"
    case "signed": "Signed"
    default: "Filled"
    }
  }
  var statusIcon: String {
    switch status {
    case "awaiting_signature": "signature"
    case "signed": "checkmark.seal.fill"
    default: "pencil.line"
    }
  }
  var updatedText: String { Self.dayText(signedAt ?? updatedAt) }
  static func dayText(_ iso: String) -> String {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))?
      .formatted(date: .abbreviated, time: .shortened) ?? iso
  }
  var exportName: String {
    let base = documentName.hasSuffix(".pdf") ? String(documentName.dropLast(4)) : documentName
    return "\(base) – \(title)\(isSigned ? " (signed)" : "")"
  }
}
