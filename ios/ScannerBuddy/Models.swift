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
  var schema: JSONValue
  var createdAt: String
  var documentCount: Int
}
struct GroupDraft: Codable, Sendable {
  var name = ""
  var instructions = ""
  var namingTemplate = "{date}-{title}"
  var schema = JSONValue.emptySchema
  init(group: ScanGroup? = nil) {
    if let group {
      name = group.name
      instructions = group.instructions
      namingTemplate = group.namingTemplate
      schema = group.schema
    }
  }
}
struct ScanDocument: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var groupId: String
  var name: String
  var originalName: String
  var status: String
  var data: JSONValue?
  var error: String?
  var createdAt: String
  var size: Int
}
struct Proposal: Codable, Identifiable, Sendable {
  var id: String
  var mutation: JSONValue
  var state: String
  var title: String {
    mutation.object["action"]?.string.replacingOccurrences(of: "_", with: " ").capitalized
      ?? "Review change"
  }
}
struct ChatMessage: Identifiable, Codable, Sendable {
  var id = UUID()
  var role: String
  var content: String
}
struct ChatReply: Decodable, Sendable {
  var text: String
  var proposals: [Proposal]
}
struct APIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
