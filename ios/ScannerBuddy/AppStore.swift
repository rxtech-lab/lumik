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
  var documents: [ScanDocument] = []
  var messages: [ChatMessage] = []
  var proposals: [Proposal] = []
  var busy: String?
  var notice: String?
  var error: String?
  var loading = false
  var pendingImport: URL?
  var selectedGroupID: String?
  private var refreshTask: Task<Void, Error>?
  private var documentPoll: Task<Void, Never>?
  init() {
    let info = Bundle.main.infoDictionary ?? [:]
    let clientID = info["RxLabClientID"] as? String ?? "unconfigured"
    configured = !clientID.isEmpty && clientID != "unconfigured" && !clientID.contains("$(")
    baseURL = URL(string: info["ScannerAPIURL"] as? String ?? "https://scanner.rxlab.app")!
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
      throw APIError(message: message ?? "The server could not complete this request.")
    }
    return data
  }
  #if DEBUG
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
          namingTemplate: "{date}-{vendor}",
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
      self.error = error.localizedDescription
    }
  }
  func loadDocuments(_ id: String) async {
    if isPreview {
      documents = [
        ScanDocument(
          id: "preview-document", groupId: id, name: "2026-11-01-acme.pdf",
          originalName: "Scan.pdf", status: "ready",
          data: .object(["vendor": .string("Acme"), "total": .number(42)]),
          error: nil, createdAt: "2026-11-01", size: 48_000)
      ]
      return
    }
    selectedGroupID = id
    documentPoll?.cancel()
    documents = []
    loading = true
    defer { loading = false }
    do {
      let result = try await fetch([ScanDocument].self, "groups/\(id)/documents")
      if selectedGroupID == id {
        documents = result
        pollProcessingDocuments(id)
      }
    } catch { self.error = error.localizedDescription }
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
      self.error = error.localizedDescription
      Haptics.failure()
      return false
    }
  }
  func saveGroup(_ draft: GroupDraft, id: String?) async throws {
    let _: ScanGroup = try await fetch(
      ScanGroup.self, id.map { "groups/\($0)" } ?? "groups", method: id == nil ? "POST" : "PATCH",
      body: JSONEncoder().encode(draft))
    await refresh()
  }
  func upload(_ data: Data, name: String, groupID: String) async throws {
    guard data.count <= 20 * 1024 * 1024 else {
      throw APIError(message: "Choose a PDF smaller than 20 MB.")
    }
    let boundary = UUID().uuidString
    var body = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\"\r\nContent-Type: application/pdf\r\n\r\n"
        .utf8)
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    _ = try await request(
      "groups/\(groupID)/documents", method: "POST", body: body,
      contentType: "multipart/form-data; boundary=\(boundary)")
    await loadDocuments(groupID)
    await refresh()
  }
  func send(_ text: String) async {
    let history = Array((messages + [ChatMessage(role: "user", content: text)]).suffix(30))
    messages.append(ChatMessage(role: "user", content: text))
    await perform("Working on your request…", success: "Reply ready") {
      let body = try JSONEncoder().encode([
        "messages": history.map { ["role": $0.role, "content": $0.content] }
      ])
      let reply = try await fetch(ChatReply.self, "chat", method: "POST", body: body)
      messages.append(
        ChatMessage(
          role: "assistant",
          content: reply.text.isEmpty ? "I’ve prepared a change for your review." : reply.text))
      proposals = reply.proposals
    }
  }
  func logout() async {
    documentPoll?.cancel()
    await auth.logout()
    groups = []
    documents = []
    messages = []
    proposals = []
    selectedGroupID = nil
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
