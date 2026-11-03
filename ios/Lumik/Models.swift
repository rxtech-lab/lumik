import Foundation

indirect enum JSONValue: Codable, Hashable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
  var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
  var string: String { if case .string(let v) = self { v } else { "" } }
  var bool: Bool { if case .bool(let v) = self { v } else { false } }
  var pretty: String {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(data: e.encode(self), encoding: .utf8)) ?? "{}"
  }
  static let emptySchema: JSONValue = .object([
    "type": .string("object"), "properties": .object([:]), "required": .array([]),
    "additionalProperties": .bool(false),
  ])
  static func parse(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(Self.self, from: Data(string.utf8))
  }
}
struct ScanGroup: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var instructions: String
  var namingTemplate: String
  var extractAdditional: Bool
  var schema: JSONValue
  var createdAt: String
  var documentCount: Int
  /// The group this one sits inside. Optional, like `kind`, for responses from older servers.
  var parentId: String? = nil
  var kind: String? = nil
  /// Holds scans that have not been filed yet. It can't be edited, deleted, or nested into.
  var isInbox: Bool { kind == "inbox" }
  var documentCountText: String { documentCount == 1 ? "1 document" : "\(documentCount) documents" }
}
/// One line of the group hierarchy, for pickers that show it indented.
struct GroupTreeRow: Identifiable, Sendable {
  let group: ScanGroup
  let depth: Int
  var id: String { group.id }
}
/// A group waiting in the Recycle Bin until `purgeAt`.
struct DeletedGroup: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var documentCount: Int
  var deletedAt: String
  var purgeAt: String
  var daysLeft: Int {
    guard let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(purgeAt)
    else { return 0 }
    return max(1, Int((date.timeIntervalSinceNow / 86_400).rounded(.up)))
  }
}
struct GroupDraft: Codable, Sendable {
  var name = ""
  var instructions = ""
  var namingTemplate = "{date}-{title}"
  var extractAdditional = false
  var schema = JSONValue.emptySchema
  /// Sent only when creating a subgroup; a group stays where it was created.
  var parentId: String?
  /// A new subgroup starts with its parent's setup, so PDFs keep their fields moving between them.
  init(group: ScanGroup? = nil, parent: ScanGroup? = nil) {
    if let source = group ?? parent {
      instructions = source.instructions
      namingTemplate = source.namingTemplate
      extractAdditional = source.extractAdditional
      schema = source.schema
    }
    if let group { name = group.name }
    parentId = parent?.id
  }
}
/// What the agent found beyond the group's schema, and a json-render spec that shows it.
struct AdditionalData: Codable, Hashable, Sendable {
  var facts: JSONValue
  var spec: JSONValue
}
/// A statistics view or filter the agent created for a group.
struct GroupView: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var groupId: String
  var kind: String
  var title: String
  var spec: JSONValue
  var queries: JSONValue
}
struct ViewStateReply: Decodable, Sendable { var state: JSONValue }
/// Documents narrowed by a saved filter or by Lumik.
struct DocumentFilter: Hashable, Sendable {
  var title: String
  var documentIDs: Set<String>
}
struct ScanDocument: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var groupId: String
  var name: String
  var originalName: String
  var status: String
  var data: JSONValue?
  var additional: AdditionalData?
  var error: String?
  var createdAt: String
  var size: Int
}
struct Proposal: Codable, Identifiable, Sendable {
  var id: String
  var mutation: JSONValue
  var state: String
  var title: String {
    let action = mutation.object["action"]?.string.replacingOccurrences(of: "_", with: " ").capitalized
    if let view = mutation.object["view"]?.object["title"]?.string { return "\(action ?? "Change"): \(view)" }
    return action ?? "Review change"
  }
}
struct ChatMessage: Identifiable, Codable, Sendable {
  var id = UUID()
  var role: String
  var content: String
  var activity: [ChatActivity] = []
  private enum CodingKeys: String, CodingKey { case role, content }
}
struct ChatActivity: Codable, Hashable, Sendable {
  var tool: String
  var detail: String?
}
struct ChatSelection: Decodable, Sendable {
  var groupId: String
  var documentIds: [String]
  var label: String
}
struct ChatReply: Decodable, Sendable {
  var text: String
  var proposals: [Proposal]
  var selection: ChatSelection?
  var activity: [ChatActivity]
}
struct ChatHistory: Decodable, Sendable {
  struct Entry: Decodable, Sendable {
    var role: String
    var content: String
    var activity: [ChatActivity]
  }
  var conversationId: String?
  var messages: [Entry]
}
struct APIError: LocalizedError {
  let message: String
  var status: Int? = nil
  var errorDescription: String? { message }
}

/// Cancellation is expected when navigating away, dismissing a picker, or stopping work.
func isSilentCancellation(_ error: Error) -> Bool {
  if Task.isCancelled || error is CancellationError { return true }
  var current = error as NSError
  for _ in 0..<8 {
    if (current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled)
      || (current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError) {
      return true
    }
    guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
    current = underlying
  }
  return false
}
