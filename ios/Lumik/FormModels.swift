import Foundation

/// One piece of a date that the form prints as separate blanks.
enum FormDatePart: String, Codable, Hashable, Sendable {
  case day, month, year
}
/// A box on a page as fractions of the page as displayed: rotated and cropped, with y running down.
struct FormPlacement: Codable, Hashable, Sendable {
  var page: Int
  var x: Double
  var y: Double
  var w: Double
  var h: Double
  /// Set once the user positions this box, so it is drawn exactly there rather than aligned.
  var manual: Bool? = nil
  /// Which piece of a date goes here, when the date is written across several boxes.
  var part: FormDatePart? = nil
}
struct FormOption: Codable, Hashable, Sendable {
  var value: String
  var label: String
  var placements: [FormPlacement] = []
}
struct FormField: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var label: String
  var type: String
  var required = false
  var help: String?
  var placements: [FormPlacement] = []
  var options: [FormOption] = []
  var widgets: [String] = []
  var defaultValue: JSONValue?
  var typeName: String {
    switch type {
    case "multiline": "Long text"
    case "date": "Date"
    case "number": "Number"
    case "checkbox": "Checkbox"
    case "choice": "Choice"
    case "signature": "Signature"
    default: "Text"
    }
  }
}
struct FormSection: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var title: String
  var footer: String?
  var fields: [FormField]
}
struct FormTemplate: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var versionId: String
  var title: String
  var source: String
  var sections: [FormSection]
  var createdAt: String
  var updatedAt: String
  var fieldCount: Int { sections.reduce(0) { $0 + $1.fields.count } }
}
struct FormTemplateUpdate: Decodable, Sendable {
  var title: String
  var sections: [FormSection]
  var updatedAt: String
}
struct DocumentVersion: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var number: Int
  var name: String
  var size: Int
  var createdAt: String
  var isCurrent: Bool
  var pdfPath: String
  var pdfUrl: String?
}
struct FilledForm: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var documentId: String
  var documentName: String
  var groupId: String
  var versionId: String
  var versionNumber: Int
  var templateId: String
  var title: String
  var status: String
  var revision: Int
  var values: [String: JSONValue]
  var signingRequestId: String?
  var signingRequestTitle: String?
  var signatureMethod: String?
  var signedAt: String?
  var signedSize: Int?
  var createdAt: String
  var updatedAt: String
  /// Left out of lists, and added from the template or by reading the form when it's opened.
  var sections: [FormSection]?
  var templateTitle: String?
  var pdfPath: String?
  var pdfUrl: String?
  var signedPdfPath: String?
  var signedPdfUrl: String?
  var isDraft: Bool { status == "draft" }
  var isSigned: Bool { status == "signed" }
  var isAwaitingSignature: Bool { status == "awaiting_signature" }
  var isComplete: Bool { sections != nil && pdfPath != nil }
}
struct FormValuesSaved: Decodable, Sendable {
  var revision: Int
  var updatedAt: String
  var title: String
}
struct FormTemplateCreated: Decodable, Sendable {
  var template: FormTemplate
  var form: FilledForm
}
struct DocumentWorkspace: Codable, Sendable {
  var document: ScanDocument
  var versions: [DocumentVersion]
  var templates: [FormTemplate]
  var forms: [FilledForm]
  var currentVersion: DocumentVersion? { versions.first(where: \.isCurrent) }
  var currentTemplate: FormTemplate? {
    templates.first { $0.versionId == currentVersion?.id }
  }
  /// The newest copy of the current version's form that can still be edited.
  var latestDraft: FilledForm? {
    forms.first { $0.isDraft && $0.versionId == currentVersion?.id }
  }
  /// One API read returns forms and templates side by side, so a form never has to fetch its template.
  func joined() -> DocumentWorkspace {
    var copy = self
    copy.forms = forms.map { form in
      var form = form
      let template = templates.first { $0.id == form.templateId }
      form.sections = template?.sections
      form.templateTitle = template?.title
      return form
    }
    return copy
  }
}
struct GroupOverview: Decodable, Sendable {
  var groups: [ScanGroup]
  var requests: [SigningRequest]
  var documents: [ScanDocument]
  var views: [GroupView]
  var forms: [FilledForm]
}
struct SigningRequest: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var title: String
  var createdAt: String
  var status: String
  var forms: [FilledForm]
  var isPending: Bool { status == "pending" }
  var unsigned: [FilledForm] { forms.filter(\.isAwaitingSignature) }
  var summary: String {
    let signed = forms.filter(\.isSigned).count
    let total = forms.count == 1 ? "1 PDF" : "\(forms.count) PDFs"
    return isPending && signed > 0 ? "\(signed) of \(total) signed" : total
  }
}
struct SigningRequestList: Decodable, Sendable {
  var id: String?
  var requests: [SigningRequest]
}
/// What PDFKit finds in a PDF's own form, sent so the server maps it without guessing.
struct PDFWidgetInfo: Encodable, Sendable {
  var name: String
  var kind: String
  var page: Int
  var x: Double
  var y: Double
  var w: Double
  var h: Double
  var label: String?
  var value: String?
  var onState: String?
  var options: [String]
}
