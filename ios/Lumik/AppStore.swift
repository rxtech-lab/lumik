import RxAuthSwift
import SwiftUI

#if os(iOS)
  import UIKit
#endif

@MainActor @Observable final class AppStore {
  let auth: OAuthManager
  private let tokens: KeychainTokenStorage
  let baseURL: URL
  let configured: Bool
  var isPreview: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--ui-preview")
    #else
      false
    #endif
  }
  var groups: [ScanGroup] = []
  var deletedGroups: [DeletedGroup] = []
  var documents: [ScanDocument] = []
  var messages: [ChatMessage] = []
  /// Chosen here rather than by the server, so a retry after a failed send stays in the conversation.
  private var conversationID: String?
  private var chatHistoryLoaded = false
  var proposals: [Proposal] = []
  var groupSuggestions: [PDFGroupSuggestion] = []
  private var suggestionSession = UUID()
  var busy: String?
  var notice: String?
  var error: String?
  var loading = false
  var pendingImport: URL?
  var selectedGroupID: String?
  var views: [GroupView] = []
  var documentFilter: DocumentFilter?
  var openDocument: ScanDocument? {
    didSet { if openDocument?.id != oldValue?.id { dismissedContextDocumentID = nil } }
  }
  /// Groups added to the chat by hand. The open group and PDF join on their own unless removed.
  var chatExtraGroupIDs: [String] = []
  var dismissedContextGroupID: String?
  var dismissedContextDocumentID: String?
  var loadingDocumentID: String?
  var openDocumentPages: Int?
  var sending = false
  var composerDraft = ""
  /// Scans waiting in the composer. They live in the Inbox until Lumik's plan is approved.
  var chatAttachments: [ScanDocument] = []
  /// Scans are read on upload, and Lumik files them from what that finds.
  var readingAttachments = false
  private var attachmentPoll: Task<Void, Never>?
  var agentPanelVisible = true
  var agentSheetVisible = false
  var agentPanelTab = AgentPanelTab.buddy
  var contextDocument: ScanDocument? {
    openDocument?.id == dismissedContextDocumentID ? nil : openDocument
  }
  var contextGroup: ScanGroup? {
    guard let selectedGroupID, selectedGroupID != dismissedContextGroupID else { return nil }
    return groups.first { $0.id == selectedGroupID }
  }
  var extraContextGroups: [ScanGroup] {
    chatExtraGroupIDs.filter { $0 != contextGroup?.id }
      .compactMap { id in groups.first { $0.id == id } }
  }
  /// The server takes at most 20 groups for one chat.
  var addableContextGroups: [ScanGroup] {
    if extraContextGroups.count + (contextGroup == nil ? 0 : 1) >= 20 { return [] }
    return groupTree.map(\.group).filter { group in
      group.id != contextGroup?.id && !chatExtraGroupIDs.contains(group.id)
    }
  }
  func addContextGroup(_ group: ScanGroup) {
    if group.id == selectedGroupID {
      dismissedContextGroupID = nil
    } else {
      chatExtraGroupIDs.append(group.id)
    }
  }
  func removeContextGroup(_ group: ScanGroup) {
    chatExtraGroupIDs.removeAll { $0 == group.id }
    if group.id == selectedGroupID { dismissedContextGroupID = group.id }
  }
  func groupPath(_ group: ScanGroup) -> String {
    guard let parent = groups.first(where: { $0.id == group.parentId }) else { return group.name }
    return "\(groupPath(parent)) / \(group.name)"
  }
  var inbox: ScanGroup? { groups.first(where: \.isInbox) }
  var topLevelGroups: [ScanGroup] { groups.filter { !$0.isInbox && $0.parentId == nil } }
  func subgroups(of id: String) -> [ScanGroup] {
    groups.filter { $0.parentId == id }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  /// Top-level groups, or any group at all when searching, since subgroups are otherwise a level down.
  func sidebarGroups(matching query: String) -> [ScanGroup] {
    if query.isEmpty { return topLevelGroups }
    return groups.filter { !$0.isInbox && $0.name.localizedCaseInsensitiveContains(query) }
  }
  func groupSummary(_ group: ScanGroup) -> String {
    let fields = group.schema.object["properties"]?.object.count ?? 0
    let count = subgroups(of: group.id).count
    let nested = count == 0 ? "" : count == 1 ? " · 1 subgroup" : " · \(count) subgroups"
    return "\(group.documentCountText)\(nested) · \(fields) fields"
  }
  /// Every group a document can be filed in, each followed by its subgroups.
  var groupTree: [GroupTreeRow] {
    func rows(_ groups: [ScanGroup], depth: Int) -> [GroupTreeRow] {
      groups.flatMap {
        [GroupTreeRow(group: $0, depth: depth)] + rows(subgroups(of: $0.id), depth: depth + 1)
      }
    }
    return rows(topLevelGroups, depth: 0)
  }
  var visibleDocuments: [ScanDocument] {
    guard let documentFilter else { return documents }
    return documents.filter { documentFilter.documentIDs.contains($0.id) }
  }
  private var refreshTask: Task<Void, Error>?
  private var documentLoadID = UUID()
  private var documentPoll: Task<Void, Never>?
  init() {
    let info = Bundle.main.infoDictionary ?? [:]
    let clientID = info["RxLabClientID"] as? String ?? "unconfigured"
    configured = !clientID.isEmpty && clientID != "unconfigured" && !clientID.contains("$(")
    baseURL = URL(string: info["ScannerAPIURL"] as? String ?? "https://www.lumik.dev")!
    let tokens = KeychainTokenStorage(serviceName: "app.rxlab.scannerbuddy.auth")
    self.tokens = tokens
    auth = OAuthManager(
      configuration: .init(
        issuer: info["RxLabIssuer"] as? String ?? "https://auth.rxlab.app", clientID: clientID,
        // This public client only needs sign-in; email/profile are not allowed scopes.
        redirectURI: "scannerbuddy://oauth/callback", scopes: ["openid"],
        appleNoncePath: nil, appleNativeSignInPath: nil,
        keychainServiceName: "app.rxlab.scannerbuddy.auth"), tokenStorage: tokens)
  }
  func request(
    _ path: String, method: String = "GET", body: Data? = nil,
    contentType: String = "application/json"
  ) async throws -> Data {
    #if DEBUG
      if isPreview && path.hasSuffix("/pdf") { return Self.previewPDF() }
    #endif
    if isPreview { throw APIError(message: "Preview mode does not connect to an account.") }
    if let refreshTask {
      try await refreshTask.value
    } else {
      let task = Task { try await auth.refreshTokenIfNeeded() }
      refreshTask = task
      do {
        try await task.value
        refreshTask = nil
      } catch {
        refreshTask = nil
        throw error
      }
    }
    guard let token = tokens.getAccessToken() else {
      throw APIError(message: "Please sign in again.")
    }
    var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/" + path))
    req.httpMethod = method
    req.httpBody = body
    req.timeoutInterval = 125
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let message = (try? JSONValue.parse(String(decoding: data, as: UTF8.self)))?.object["error"]?
        .string
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw APIError(message: message ?? (status == 413 ? "The upload exceeds the server size limit." : "The server could not complete this request (HTTP \(status))."))
    }
    return data
  }
  #if DEBUG
    private static func previewViews(_ groupID: String) -> [GroupView] {
      func element(_ type: String, _ props: [String: JSONValue]) -> JSONValue {
        .object(["type": .string(type), "props": .object(props), "children": .array([])])
      }
      return [
        GroupView(
          id: "preview-statistic", groupId: groupID, kind: "statistic", title: "Total spent",
          spec: .object([
            "root": .string("total"),
            "elements": .object([
              "total": element(
                "Metric",
                [
                  "label": .string("Total"), "format": .string("currency"), "currency": .string("USD"),
                  "value": .object(["$state": .string("/queries/total/0/sum")]),
                ])
            ]),
          ]), queries: .object([:])),
        GroupView(
          id: "preview-filter", groupId: groupID, kind: "filter", title: "By vendor",
          spec: .object([
            "root": .string("vendor"),
            "elements": .object([
              "vendor": element(
                "TextInput",
                ["label": .string("Vendor"), "value": .object(["$bindState": .string("/vendor")])])
            ]),
          ]), queries: .object([:])),
      ]
    }
    private static func previewPDF() -> Data {
      let data = NSMutableData()
      var page = CGRect(x: 0, y: 0, width: 612, height: 792)
      guard let consumer = CGDataConsumer(data: data),
        let context = CGContext(consumer: consumer, mediaBox: &page, nil)
      else { return Data() }
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 0.82, alpha: 1))
      for line in 0..<14 {
        context.fill(CGRect(x: 60, y: 690 - line * 40, width: line % 4 == 3 ? 280 : 492, height: 14))
      }
      context.endPDFPage()
      context.closePDF()
      return data as Data
    }
  #endif
  func fetch<T: Decodable>(
    _ type: T.Type, _ path: String, method: String = "GET", body: Data? = nil
  ) async throws -> T {
    try JSONDecoder().decode(type, from: await request(path, method: method, body: body))
  }
  func refresh() async {
    if isPreview {
      groups = [
        ScanGroup(
          id: "preview", name: "Travel receipts",
          instructions: "Capture the vendor, date, currency, and total for every expense.",
          namingTemplate: "{date}-{vendor}", extractAdditional: true,
          schema: .object([
            "type": .string("object"),
            "properties": .object([
              "vendor": .object(["type": .string("string")]),
              "total": .object(["type": .string("number")]),
            ]),
          ]), createdAt: "2026-11-01", documentCount: 0)
      ]
      return
    }
    loading = true
    defer { loading = false }
    do { groups = try await fetch([ScanGroup].self, "groups") } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription }
    }
  }
  func loadDeletedGroups() async {
    if isPreview { return }
    do { deletedGroups = try await fetch([DeletedGroup].self, "deleted-groups") } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription }
    }
  }
  func deleteGroup(_ group: ScanGroup) async throws {
    _ = try await request("groups/\(group.id)", method: "DELETE")
    if selectedGroupID == group.id { documentPoll?.cancel() }
    groups.removeAll { $0.id == group.id }
    await loadDeletedGroups()
    await refresh()
  }
  func restoreGroup(_ group: DeletedGroup) async throws {
    _ = try await request("deleted-groups/\(group.id)/restore", method: "POST")
    deletedGroups.removeAll { $0.id == group.id }
    await refresh()
  }
  func purgeGroup(_ group: DeletedGroup) async throws {
    _ = try await request("deleted-groups/\(group.id)", method: "DELETE")
    deletedGroups.removeAll { $0.id == group.id }
  }
  func loadDocuments(_ id: String) async {
    if selectedGroupID != id {
      documentFilter = nil
      dismissedContextGroupID = nil
    }
    if isPreview {
      selectedGroupID = id
      documents = [
        ScanDocument(
          id: "preview-document", groupId: id, name: "2026-11-01-acme.pdf",
          originalName: "Scan.pdf", status: "ready",
          data: .object(["vendor": .string("Acme"), "total": .number(42)]),
          additional: AdditionalData(
            facts: .object(["receipt_number": .string("R-1042")]),
            spec: .object([
              "root": .string("note"),
              "elements": .object([
                "note": .object([
                  "type": .string("Text"), "props": .object(["text": .string("Receipt number R-1042")]),
                  "children": .array([]),
                ])
              ]),
            ])),
          error: nil, createdAt: "2026-11-01", size: 48_000)
      ]
      return
    }
    selectedGroupID = id
    let loadID = UUID()
    documentLoadID = loadID
    documentPoll?.cancel()
    documents = []
    loading = true
    defer { if documentLoadID == loadID { loading = false } }
    do {
      let result = try await fetch([ScanDocument].self, "groups/\(id)/documents")
      if selectedGroupID == id && documentLoadID == loadID && !Task.isCancelled {
        documents = result
        pollProcessingDocuments(id)
      }
    } catch {
      if documentLoadID == loadID && selectedGroupID == id && !isSilentCancellation(error) {
        self.error = error.localizedDescription
      }
    }
  }
  /// Uploads are processed on the server, so watch until their new names and fields arrive.
  private func pollProcessingDocuments(_ id: String) {
    guard documents.contains(where: { $0.status == "processing" }) else { return }
    documentPoll = Task { [weak self] in
      // Slightly outlasts the server's three-minute processing lease.
      for _ in 0..<64 {
        try? await Task.sleep(for: .seconds(3))
        guard let self, !Task.isCancelled, self.selectedGroupID == id else { return }
        guard let result = try? await self.fetch([ScanDocument].self, "groups/\(id)/documents"),
          !Task.isCancelled, self.selectedGroupID == id
        else { continue }
        let previous = self.documents
        self.documents = result
        self.announceProcessed(result, previous: previous)
        if !result.contains(where: { $0.status == "processing" }) { return }
      }
    }
  }
  private func announceProcessed(_ current: [ScanDocument], previous: [ScanDocument]) {
    let finished = current.filter { document in
      document.status != "processing"
        && previous.contains { $0.id == document.id && $0.status == "processing" }
    }
    guard let first = finished.first else { return }
    if finished.contains(where: { $0.status == "failed" }) {
      showNotice("Couldn’t read a PDF. Retry from its menu.")
      Haptics.failure()
    } else {
      showNotice(finished.count == 1 ? "Renamed to \(first.name)" : "\(finished.count) PDFs renamed")
      Haptics.success()
    }
  }
  private func showNotice(_ text: String) {
    notice = text
    Task {
      try? await Task.sleep(for: .seconds(3))
      if notice == text { notice = nil }
    }
  }
  @discardableResult func perform(
    _ label: String, success: String = "Done", _ action: () async throws -> Void
  ) async -> Bool {
    guard busy == nil else { return false }
    Haptics.tap()
    busy = label
    defer { busy = nil }
    do {
      try await action()
      showNotice(success)
      Haptics.success()
      return true
    } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription; Haptics.failure() }
      return false
    }
  }
  func extract(_ document: ScanDocument) async {
    await perform("Reading and organizing your document…", success: "Details extracted") {
      _ = try await fetch(ScanDocument.self, "documents/\(document.id)/process", method: "POST")
      await loadDocuments(document.groupId)
    }
  }
  func saveGroup(_ draft: GroupDraft, id: String?) async throws {
    let _: ScanGroup = try await fetch(
      ScanGroup.self, id.map { "groups/\($0)" } ?? "groups", method: id == nil ? "POST" : "PATCH",
      body: JSONEncoder().encode(draft))
    await refresh()
  }
  @discardableResult func upload(_ data: Data, name: String, groupID: String, progress: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> ScanDocument {
    let report: @MainActor @Sendable (String) -> Void = { [weak self] message in
      progress?(message)
      if self?.busy != nil { self?.busy = message }
    }
    report("Preparing \(name)…")
    let model = PDFProcessingModel.saved
    var localResult: Data? = nil
    if model == .apple {
      let availableGroups = try await fetch([ScanGroup].self, "groups")
      guard let group = availableGroups.first(where: { $0.id == groupID }) else { throw APIError(message: "Group not found. Refresh and retry.") }
      let previous = try await fetch([ScanDocument].self, "groups/\(groupID)/documents")
      let names = previous.filter { $0.status == "ready" && $0.name != $0.originalName }.prefix(20).map(\.name)
      let result = try await LocalPDFProcessor.extract(data, group: group, previousNames: names, progress: report)
      localResult = try JSONEncoder().encode(result)
    }
    struct UploadTicket: Decodable { let mode: String; let id: String?; let url: URL? }
    let ticketBody = try JSONSerialization.data(withJSONObject: ["name": name, "size": data.count])
    let ticket = try JSONDecoder().decode(UploadTicket.self, from: await request(
      "groups/\(groupID)/uploads", method: "POST", body: ticketBody))
    if ticket.mode == "direct", let id = ticket.id, let url = ticket.url {
      var upload = URLRequest(url: url)
      upload.httpMethod = "PUT"
      upload.timeoutInterval = 300
      upload.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
      report(PDFUploadProgress.message(sent: 0, total: Int64(data.count)))
      let delegate = PDFUploadProgress(total: Int64(data.count), report: report)
      let (_, response) = try await URLSession.shared.upload(for: upload, from: data, delegate: delegate)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw APIError(message: "PDF upload failed. Please save again to retry.")
      }
      report("Upload complete · Saving PDF and \(model == .apple ? "extracted fields" : "queuing AI analysis")…")
      let document = try await fetch(
        ScanDocument.self, "groups/\(groupID)/uploads/\(id)/complete", method: "POST", body: localResult.map { result in
          Data("{\"processing\":\"apple\",\"result\":".utf8) + result + Data("}".utf8)
        })
      await uploadFinished(in: groupID)
      suggestGroupAfterProcessing(document)
      return document
    }
    guard ticket.mode == "local" else { throw APIError(message: "Invalid upload response.") }
    let boundary = UUID().uuidString
    var body = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\"\r\nContent-Type: application/pdf\r\n\r\n"
        .utf8)
    body.append(data)
    if let localResult {
      body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"localResult\"\r\n\r\n".utf8))
      body.append(localResult)
    }
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let document = try JSONDecoder().decode(
      ScanDocument.self,
      from: await request(
        "groups/\(groupID)/documents", method: "POST", body: body,
        contentType: "multipart/form-data; boundary=\(boundary)"))
    await uploadFinished(in: groupID)
      suggestGroupAfterProcessing(document)
    return document
  }
  private func suggestGroupAfterProcessing(_ uploaded: ScanDocument) {
    let session = suggestionSession
    Task {
      do {
        var document = uploaded
        for _ in 0..<60 {
          guard session == suggestionSession else { return }
          if document.status != "processing" { break }
          try await Task.sleep(for: .seconds(3))
          document = try await fetch(ScanDocument.self, "documents/\(uploaded.id)")
        }
        guard document.status == "ready" else { return }
        struct Suggestion: Decodable { let groupId: String; let reason: String }
        struct Reply: Decodable { let suggestion: Suggestion? }
        let reply = try await fetch(Reply.self, "documents/\(document.id)/suggest-group", method: "POST")
        guard session == suggestionSession, let suggestion = reply.suggestion else { return }
        await refresh()
        guard let group = groups.first(where: { $0.id == suggestion.groupId }) else { return }
        groupSuggestions.append(PDFGroupSuggestion(document: document, group: group, reason: suggestion.reason))
      } catch {
        // Saving succeeded; an optional filing suggestion must not turn it into an upload failure.
      }
    }
  }
  /// A scan sent to the Inbox from Lumik must not replace the group that is open.
  private func uploadFinished(in groupID: String) async {
    if selectedGroupID == groupID { await loadDocuments(groupID) }
    await refresh()
  }
  func prepareInbox() async throws -> ScanGroup {
    try await fetch(ScanGroup.self, "inbox", method: "POST")
  }
  func attachScan(_ document: ScanDocument) {
    chatAttachments.append(document)
    watchAttachments()
  }
  func removeAttachment(_ document: ScanDocument) {
    chatAttachments.removeAll { $0.id == document.id }
    watchAttachments()
  }
  private func watchAttachments() {
    attachmentPoll?.cancel()
    guard let groupID = chatAttachments.first?.groupId,
      chatAttachments.contains(where: { $0.status == "processing" })
    else {
      readingAttachments = false
      return
    }
    readingAttachments = true
    attachmentPoll = Task { [weak self] in
      // Slightly outlasts the server's three-minute processing lease, then lets the user send anyway.
      for _ in 0..<64 {
        try? await Task.sleep(for: .seconds(3))
        guard let self, !Task.isCancelled else { return }
        guard let current = try? await self.fetch([ScanDocument].self, "groups/\(groupID)/documents"),
          !Task.isCancelled
        else { continue }
        self.chatAttachments = self.chatAttachments.map { attachment in
          current.first { $0.id == attachment.id } ?? attachment
        }
        if !self.chatAttachments.contains(where: { $0.status == "processing" }) { break }
      }
      if !Task.isCancelled { self?.readingAttachments = false }
    }
  }
  func renameDocument(_ document: ScanDocument, to name: String) async throws {
    let renamed = try await fetch(
      ScanDocument.self, "documents/\(document.id)/rename", method: "POST",
      body: JSONEncoder().encode(["name": name]))
    if let index = documents.firstIndex(where: { $0.id == renamed.id }) {
      documents[index] = renamed
    }
  }
  func moveDocument(_ document: ScanDocument, to groupID: String) async throws {
    _ = try await fetch(
      ScanDocument.self, "documents/\(document.id)/move", method: "POST",
      body: JSONEncoder().encode(["groupId": groupID]))
    // A poll already in flight could bring the moved row back.
    documentPoll?.cancel()
    documents.removeAll { $0.id == document.id }
    pollProcessingDocuments(document.groupId)
    await refresh()
  }
  /// Moving between groups with different fields makes the server read the PDF again.
  func movePreservesDetails(_ document: ScanDocument, to group: ScanGroup) -> Bool {
    groups.first { $0.id == document.groupId }?.schema == group.schema
  }
  func suggestDocumentName(_ document: ScanDocument) async throws -> String {
    struct Reply: Decodable { var name: String }
    return try await fetch(Reply.self, "documents/\(document.id)/suggest-name", method: "POST").name
  }
  func deleteDocument(_ document: ScanDocument) async throws {
    _ = try await request("documents/\(document.id)", method: "DELETE")
    // A poll already in flight could bring the deleted row back.
    documentPoll?.cancel()
    documents.removeAll { $0.id == document.id }
    pollProcessingDocuments(document.groupId)
    await refresh()
  }
  func loadViews(_ groupID: String) async {
    #if DEBUG
      if isPreview {
        views = Self.previewViews(groupID)
        return
      }
    #endif
    do {
      let result = try await fetch([GroupView].self, "groups/\(groupID)/views")
      if selectedGroupID == groupID && !Task.isCancelled { views = result }
    } catch { if !isSilentCancellation(error) { self.error = error.localizedDescription } }
  }
  func viewState(_ view: GroupView) async throws -> JSONValue {
    if isPreview { return .object(["queries": .object(["total": .array([.object(["sum": .number(42)])])]), "vendor": .null]) }
    return try await fetch(ViewStateReply.self, "groups/\(view.groupId)/views/\(view.id)/state").state
  }
  func previewState(groupID: String, view: JSONValue) async throws -> JSONValue {
    try await fetch(
      ViewStateReply.self, "groups/\(groupID)/views/preview", method: "POST",
      body: JSONEncoder().encode(view)
    ).state
  }
  func deleteView(_ view: GroupView) async throws {
    _ = try await request("groups/\(view.groupId)/views/\(view.id)", method: "DELETE")
    views.removeAll { $0.id == view.id }
  }
  func runFilter(_ view: GroupView, values: [String: JSONValue]) async throws {
    struct Reply: Decodable { var documentIds: [String] }
    let reply = try await fetch(
      Reply.self, "groups/\(view.groupId)/views/\(view.id)/run", method: "POST",
      body: JSONEncoder().encode(["values": JSONValue.object(values)]))
    documentFilter = DocumentFilter(title: view.title, documentIDs: Set(reply.documentIds))
  }
  /// Opens Lumik with a started message, in whichever place this device shows it.
  func askBuddy(_ draft: String = "") {
    Haptics.tap()
    composerDraft = draft
    agentPanelVisible = true
    agentSheetVisible = true
  }
  /// Restores the saved conversation once per sign-in, without replacing one already under way.
  func loadChatHistory() async {
    if isPreview || chatHistoryLoaded { return }
    do {
      let history = try await fetch(ChatHistory.self, "chat/messages")
      chatHistoryLoaded = true
      guard messages.isEmpty, conversationID == nil else { return }
      conversationID = history.conversationId
      messages = history.messages.map {
        ChatMessage(role: $0.role, content: $0.content, activity: $0.activity)
      }
    } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription }
    }
  }
  func startNewConversation() {
    messages = []
    conversationID = nil
    chatExtraGroupIDs = []
    dismissedContextGroupID = nil
    dismissedContextDocumentID = nil
  }
  func send(_ text: String) async {
    struct Request: Encodable {
      struct Message: Encodable {
        var role: String
        var content: String
      }
      struct Context: Encodable {
        var groupId: String?
        var documentId: String?
        var groupIds: [String]
        var attachedDocumentIds: [String]?
      }
      var conversationId: String
      var messages: [Message]
      var context: Context
    }
    let attached = chatAttachments
    // Written into the message so it stays visible, and known to Lumik, on later turns.
    let names = attached.prefix(10).map(\.name).joined(separator: ", ")
    let more = attached.count > 10 ? " and \(attached.count - 10) more" : ""
    let content = attached.isEmpty ? text : "\(text)\n\nAttached: \(names)\(more)"
    chatAttachments = []
    messages.append(ChatMessage(role: "user", content: content))
    let conversation = conversationID ?? UUID().uuidString
    conversationID = conversation
    sending = true
    defer { sending = false }
    do {
      // The PDF stays readable while Lumik works, so this does not block the screen.
      let body = try JSONEncoder().encode(
        Request(
          conversationId: conversation,
          messages: messages.suffix(30).map { .init(role: $0.role, content: $0.content) },
          context: .init(
            groupId: contextGroup?.id, documentId: contextDocument?.id,
            groupIds: (contextGroup.map { [$0.id] } ?? []) + extraContextGroups.map(\.id),
            attachedDocumentIds: attached.isEmpty ? nil : attached.map(\.id))))
      let reply = try await fetch(ChatReply.self, "chat", method: "POST", body: body)
      messages.append(
        ChatMessage(
          role: "assistant",
          content: reply.text.isEmpty ? "I’ve prepared a change for your review." : reply.text,
          activity: reply.activity))
      proposals = reply.proposals
      if let selection = reply.selection, selection.groupId == selectedGroupID {
        documentFilter = DocumentFilter(title: selection.label, documentIDs: Set(selection.documentIds))
      }
      Haptics.success()
    } catch {
      if !isSilentCancellation(error) { self.error = error.localizedDescription }
      // Kept in the composer so the same scans go with the next try.
      if chatAttachments.isEmpty { chatAttachments = attached }
      Haptics.failure()
    }
  }
  func logout() async {
    suggestionSession = UUID()
    groupSuggestions = []
    documentPoll?.cancel()
    attachmentPoll?.cancel()
    chatAttachments = []
    readingAttachments = false
    chatExtraGroupIDs = []
    dismissedContextGroupID = nil
    dismissedContextDocumentID = nil
    await auth.logout()
    groups = []
    documents = []
    messages = []
    conversationID = nil
    chatHistoryLoaded = false
    proposals = []
    selectedGroupID = nil
    views = []
    documentFilter = nil
    openDocument = nil
    composerDraft = ""
    pendingImport = nil
  }
}
@MainActor enum Haptics {
  static func tap() {
    #if os(iOS)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
  }
  static func success() {
    #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }
  static func failure() {
    #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    #endif
  }
}

/// URLSession reports bytes actually sent to the presigned storage endpoint.
private final class PDFUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
  let total: Int64
  let report: @MainActor @Sendable (String) -> Void
  init(total: Int64, report: @escaping @MainActor @Sendable (String) -> Void) {
    self.total = total
    self.report = report
  }
  static func message(sent: Int64, total: Int64) -> String {
    String(format: "Uploading PDF · %.2f MB / %.2f MB", Double(sent) / 1_000_000, Double(total) / 1_000_000)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                  totalBytesExpectedToSend: Int64) {
    let message = Self.message(sent: min(totalBytesSent, total), total: total)
    Task { @MainActor in report(message) }
  }
}
