import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// A signature drawn with a finger or pointer, or typed in a script font. Both stay vector in the PDF.
struct SignatureArt: Hashable, Sendable {
  enum Content: Hashable, Sendable {
    case strokes([[CGPoint]])
    case typed(text: String, font: String)
  }
  var content: Content
  /// How it was made, kept with the signed PDF: drawn, trackpad, or typed.
  var method: String
  static let ink = CGColor(srgbRed: 0.04, green: 0.09, blue: 0.36, alpha: 1)
  /// Draws centered in `rect`, in a context whose y axis runs up, like a PDF page.
  func draw(in rect: CGRect, context: CGContext) {
    switch content {
    case .strokes(let strokes): drawStrokes(strokes, in: rect, context: context)
    case .typed(let text, let font): drawTyped(text, font: font, in: rect, context: context)
    }
  }
  private func drawStrokes(_ strokes: [[CGPoint]], in rect: CGRect, context: CGContext) {
    let points = strokes.flatMap { $0 }
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
    else { return }
    let width = max(maxX - minX, 1)
    let height = max(maxY - minY, 1)
    let scale = min(rect.width / width, rect.height / height)
    let offsetX = rect.minX + (rect.width - width * scale) / 2
    let offsetY = rect.minY + (rect.height - height * scale) / 2
    func map(_ point: CGPoint) -> CGPoint {
      CGPoint(x: offsetX + (point.x - minX) * scale, y: offsetY + (maxY - point.y) * scale)
    }
    context.saveGState()
    context.setStrokeColor(Self.ink)
    context.setFillColor(Self.ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let lineWidth = min(max(rect.height * 0.035, 0.7), 2.2)
    context.setLineWidth(lineWidth)
    for stroke in strokes {
      guard let first = stroke.first else { continue }
      if stroke.count == 1 {
        let dot = map(first)
        context.fillEllipse(in: CGRect(x: dot.x - lineWidth / 2, y: dot.y - lineWidth / 2, width: lineWidth, height: lineWidth))
        continue
      }
      // Curving through midpoints smooths the corners between sampled points.
      context.beginPath()
      context.move(to: map(first))
      for index in 1..<stroke.count {
        let previous = map(stroke[index - 1])
        let current = map(stroke[index])
        context.addQuadCurve(
          to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2),
          control: previous)
      }
      context.addLine(to: map(stroke[stroke.count - 1]))
      context.strokePath()
    }
    context.restoreGState()
  }
  private func drawTyped(_ text: String, font: String, in rect: CGRect, context: CGContext) {
    let line = FormRenderer.fittedLine(
      text, fontName: font, color: Self.ink, width: rect.width, height: rect.height, largest: rect.height)
    FormRenderer.draw(line, centeredIn: rect, leftAligned: false, context: context)
  }
}
struct SignatureStamp: Hashable, Sendable {
  var art: SignatureArt
  var placement: FormPlacement
}
enum FormRenderError: LocalizedError {
  case unreadable
  case locked
  var errorDescription: String? {
    switch self {
    case .unreadable: "This PDF can’t be read. It may be damaged."
    case .locked: "This PDF is password protected, so it can’t be filled in."
    }
  }
}
/// Draws filled values and signatures over a copy of a PDF on this device. The original stays
/// untouched, previews need no server, and CoreText handles every language.
enum FormRenderer {
  fileprivate enum Mark {
    case text(String, FormPlacement, multiline: Bool)
    case check(FormPlacement)
    case stamp(SignatureStamp)
    var page: Int {
      switch self {
      case .text(_, let placement, _), .check(let placement): placement.page
      case .stamp(let stamp): stamp.placement.page
      }
    }
  }
  private static let textColor = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
  /// The value to show: what was entered, else what the PDF came with.
  static func value(of field: FormField, in values: [String: JSONValue]) -> JSONValue? {
    if let entered = values[field.id] {
      if case .null = entered { return nil }
      return entered
    }
    return field.defaultValue
  }
  static func displayText(of field: FormField, value: JSONValue?) -> String? {
    guard case .string(let text)? = value, !text.isEmpty else { return nil }
    switch field.type {
    case "date":
      return (try? Date(text, strategy: .iso8601.year().month().day()))?
        .formatted(date: .numeric, time: .omitted) ?? text
    case "choice":
      return field.options.first { $0.value == text }?.label ?? text
    default:
      return text
    }
  }
  static func render(
    base: Data, sections: [FormSection], values: [String: JSONValue], stamps: [SignatureStamp] = []
  ) throws -> Data {
    guard let document = PDFDocument(data: base) else { throw FormRenderError.unreadable }
    if document.isLocked { throw FormRenderError.locked }
    let marks = marks(in: document, base: base, sections: sections, values: values, stamps: stamps)
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output) else { throw FormRenderError.unreadable }
    var firstBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
      throw FormRenderError.unreadable
    }
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      let size = displaySize(of: page)
      var box = CGRect(origin: .zero, size: size)
      context.beginPage(mediaBox: &box)
      context.saveGState()
      // Handles the page's rotation and crop, so everything after draws in display coordinates.
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
      for mark in marks where mark.page == index { draw(mark, pageSize: size, context: context) }
      context.endPage()
    }
    context.closePDF()
    return output as Data
  }
  private static func marks(
    in document: PDFDocument, base: Data, sections: [FormSection], values: [String: JSONValue],
    stamps: [SignatureStamp] = []
  ) -> [Mark] {
    let fields = sections.flatMap(\.fields)
    let widgets = widgetsByName(in: document, needed: fields)
    let layout = PrintedLayout(document: document, base: base)
    var marks = stamps.map { Mark.stamp($0) }
    for field in fields {
      let value = value(of: field, in: values)
      let matching = field.widgets.flatMap { widgets[$0] ?? [] }
      let touched = values[field.id] != nil || value != nil
      // A field with nothing to draw leaves its page unread, which keeps opening a new form instant.
      let positioned = value == nil ? field : layout.aligned(field)
      switch field.type {
      case "signature":
        break
      case "checkbox":
        if touched { matching.forEach { $0.buttonWidgetState = .offState } }
        if case .bool(true)? = value { marks += positioned.placements.map { .check($0) } }
      case "choice" where field.options.contains { !$0.placements.isEmpty }:
        if touched { matching.forEach { $0.buttonWidgetState = .offState } }
        if case .string(let selected)? = value {
          marks += positioned.options.first { $0.value == selected }?.placements.map { .check($0) } ?? []
        }
      default:
        // The widget would draw its own text under ours, so it comes off this in-memory copy.
        if touched { matching.forEach { $0.page?.removeAnnotation($0) } }
        for placement in positioned.placements {
          if let text = writtenText(of: field, value: value, at: placement, layout: layout) {
            marks.append(.text(text, placement, multiline: field.type == "multiline"))
          }
        }
      }
    }
    return marks
  }

  /// The boxes as they would be drawn right now, ready to be moved by hand. Single-line boxes
  /// are trimmed to the line's height around the same center, so the text doesn't shift.
  static func editableSections(base: Data, sections: [FormSection]) throws -> [FormSection] {
    guard let document = PDFDocument(data: base) else { throw FormRenderError.unreadable }
    if document.isLocked { throw FormRenderError.locked }
    let layout = PrintedLayout(document: document, base: base)
    return sections.map { section in
      var section = section
      section.fields = section.fields.map { field in
        var field = layout.aligned(field)
        guard field.type != "multiline", field.type != "signature", field.type != "checkbox" else { return field }
        field.placements = field.placements.map { placement in
          guard placement.manual != true, placement.part == nil else { return placement }
          let height = layout.size(of: placement.page).height
          let line = 16 / max(height, 1)
          guard placement.h > line else { return placement }
          var trimmed = placement
          trimmed.y += (placement.h - line) / 2
          trimmed.h = line
          return trimmed
        }
        return field
      }
      return section
    }
  }

  /// Where these fields' ink lands, for showing what just changed.
  static func drawnBoxes(base: Data, sections: [FormSection], fieldIDs: Set<String>) throws -> [FormPlacement] {
    guard !fieldIDs.isEmpty else { return [] }
    guard let document = PDFDocument(data: base) else { throw FormRenderError.unreadable }
    let layout = PrintedLayout(document: document, base: base)
    return sections.flatMap(\.fields).filter { fieldIDs.contains($0.id) }.flatMap { field in
      let aligned = layout.aligned(field)
      return aligned.placements + aligned.options.flatMap(\.placements)
    }
  }

  /// What is written in one box: the whole value, or its piece of a date in the form's own format.
  static func writtenText(of field: FormField, value: JSONValue?, at placement: FormPlacement, layout: PrintedLayout?) -> String? {
    guard let text = displayText(of: field, value: value) else { return nil }
    guard field.type == "date", let parts = dateParts(of: value) else { return text }
    if let part = placement.part { return parts[part] }
    // A PDF's own date field keeps its usual text; the page's format applies to written boxes.
    guard field.widgets.isEmpty, let order = layout?.printedDateOrder(on: placement.page) else { return text }
    return order.map { parts[$0] }.joined(separator: "/")
  }

  private struct DateParts {
    let day: String, month: String, year: String
    subscript(part: FormDatePart) -> String {
      switch part {
      case .day: day
      case .month: month
      case .year: year
      }
    }
  }
  private static func dateParts(of value: JSONValue?) -> DateParts? {
    guard case .string(let text)? = value else { return nil }
    let parts = text.prefix(10).split(separator: "-").map(String.init)
    return parts.count == 3 ? DateParts(day: parts[2], month: parts[1], year: parts[0]) : nil
  }

  /// Printed geometry for the pages this form draws on, and where it puts each field's ink.
  final class PrintedLayout {
    private let document: PDFDocument
    private let base: Data
    private lazy var key: String = FormPageGeometry.documentKey(of: base)
    init(document: PDFDocument, base: Data) {
      self.document = document
      self.base = base
    }
    func size(of page: Int) -> CGSize {
      document.page(at: page).map(FormRenderer.displaySize(of:)) ?? .zero
    }
    func geometry(of index: Int) -> FormPageGeometry? {
      document.page(at: index).map { FormPageGeometry.of(page: $0, index: index, documentKey: key) }
    }
    func printedDateOrder(on index: Int) -> [FormDatePart]? {
      document.page(at: index).flatMap(FormPageGeometry.printedDateOrder(on:))
    }
    private func placement(of rect: CGRect, page: Int) -> FormPlacement {
      let size = size(of: page)
      return FormPlacement(
        page: page, x: rect.minX / size.width, y: 1 - rect.maxY / size.height,
        w: rect.width / size.width, h: rect.height / size.height)
    }
    /// A field with its boxes on the printed page. A PDF's own form field is already exact, a
    /// signature is placed when signing, and boxes the user positioned stay where they are.
    func aligned(_ field: FormField) -> FormField {
      guard field.widgets.isEmpty, field.type != "signature" else { return field }
      var result = field
      var remaining = tickBoxes(for: field.options.flatMap(\.placements))[...]
      for index in result.options.indices {
        let count = result.options[index].placements.count
        result.options[index].placements = Array(remaining.prefix(count))
        remaining = remaining.dropFirst(count)
      }
      result.placements = field.type == "checkbox"
        ? tickBoxes(for: field.placements)
        : field.placements.flatMap { writingPlacements(of: $0, type: field.type) }
      return result
    }
    private func writingPlacements(of original: FormPlacement, type: String) -> [FormPlacement] {
      guard original.manual != true, let geometry = geometry(of: original.page) else { return [original] }
      let box = FormRenderer.rect(of: original, pageSize: size(of: original.page))
      if type == "date", let blanks = geometry.dateBlanks(for: box) {
        return blanks.map { blank in
          var piece = placement(of: blank.area, page: original.page)
          piece.part = blank.part
          return piece
        }
      }
      return [placement(of: geometry.writingArea(for: box), page: original.page)]
    }
    /// Aligns boxes page by page, keeping their order.
    private func tickBoxes(for placements: [FormPlacement]) -> [FormPlacement] {
      var result = placements
      for page in Set(placements.map(\.page)) {
        let indices = placements.indices.filter { placements[$0].page == page && placements[$0].manual != true }
        // Boxes placed by hand don't need the page read at all.
        guard !indices.isEmpty, let geometry = geometry(of: page) else { continue }
        let size = size(of: page)
        let snapped = geometry.tickBoxes(for: indices.map { FormRenderer.rect(of: placements[$0], pageSize: size) })
        for (index, rect) in zip(indices, snapped) { result[index] = placement(of: rect, page: page) }
      }
      return result
    }
  }

  /// Printed lines in the same cropped, rotated coordinate space as form fields.
  static func textRegions(in data: Data) throws -> [FormPlacement] {
    guard let document = PDFDocument(data: data) else { throw FormRenderError.unreadable }
    var regions: [FormPlacement] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      let size = displaySize(of: page)
      guard size.width > 0, size.height > 0 else { continue }
      let transform = page.transform(for: .cropBox)
      for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] {
        let box = line.bounds(for: page).applying(transform)
          .intersection(CGRect(origin: .zero, size: size))
        guard !box.isNull, box.width > 0, box.height > 0 else { continue }
        regions.append(FormPlacement(page: index, x: box.minX / size.width,
          y: 1 - box.maxY / size.height, w: box.width / size.width, h: box.height / size.height))
        if regions.count == 10000 { return regions }
      }
    }
    return regions
  }

  static func displaySize(of page: PDFPage) -> CGSize {
    let box = page.bounds(for: .cropBox)
    return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
  }
  /// The PDF's own form fields, in display coordinates, for the server to map exactly.
  static func widgets(in data: Data) throws -> (pageCount: Int, widgets: [PDFWidgetInfo]) {
    guard let document = PDFDocument(data: data) else { throw FormRenderError.unreadable }
    if document.isLocked { throw FormRenderError.locked }
    var found: [PDFWidgetInfo] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      let size = displaySize(of: page)
      guard size.width > 0, size.height > 0 else { continue }
      let transform = page.transform(for: .cropBox)
      for annotation in page.annotations {
        guard let kind = widgetKind(annotation) else { continue }
        let box = annotation.bounds.applying(transform)
        let isButton = kind == "checkbox" || kind == "radio"
        let onState = isButton ? annotation.buttonWidgetStateString : nil
        found.append(
          PDFWidgetInfo(
            name: annotation.fieldName ?? "", kind: kind, page: index,
            x: clamp(box.minX / size.width), y: clamp(1 - box.maxY / size.height),
            w: clamp(box.width / size.width), h: clamp(box.height / size.height),
            label: annotation.annotationKeyValues[AnyHashable("/TU")] as? String,
            value: isButton
              ? (annotation.buttonWidgetState == .onState ? onState : nil)
              : annotation.widgetStringValue,
            onState: onState, options: annotation.choices ?? []))
      }
    }
    return (document.pageCount, found)
  }
  private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
  private static func widgetKind(_ annotation: PDFAnnotation) -> String? {
    guard annotation.type == "Widget", !annotation.isReadOnly else { return nil }
    switch annotation.widgetFieldType {
    case .text: return annotation.isMultiline ? "multiline" : "text"
    case .choice: return "choice"
    case .signature: return "signature"
    case .button:
      switch annotation.widgetControlType {
      case .checkBoxControl: return "checkbox"
      case .radioButtonControl: return "radio"
      default: return nil
      }
    default: return nil
    }
  }
  private static func widgetsByName(in document: PDFDocument, needed: [FormField]) -> [String: [PDFAnnotation]] {
    let names = Set(needed.flatMap(\.widgets))
    guard !names.isEmpty else { return [:] }
    var result: [String: [PDFAnnotation]] = [:]
    for index in 0..<document.pageCount {
      for annotation in document.page(at: index)?.annotations ?? [] {
        if let name = annotation.fieldName, names.contains(name) {
          result[name, default: []].append(annotation)
        }
      }
    }
    return result
  }
  static func rect(of placement: FormPlacement, pageSize: CGSize) -> CGRect {
    CGRect(
      x: placement.x * pageSize.width, y: (1 - placement.y - placement.h) * pageSize.height,
      width: placement.w * pageSize.width, height: placement.h * pageSize.height)
  }
  fileprivate static func draw(_ mark: Mark, pageSize: CGSize, context: CGContext) {
    switch mark {
    case .text(let text, let placement, let multiline):
      let box = rect(of: placement, pageSize: pageSize)
      if multiline {
        drawParagraph(text, in: box, context: context)
      } else {
        let line = fittedLine(
          text.replacingOccurrences(of: "\n", with: " "), fontName: "Helvetica", color: textColor,
          width: box.width - 4, height: box.height, largest: min(max(box.height * 0.72, 6), 11), smallest: 5)
        // Below a readable size the end is cut off at the box instead of printing over its neighbors.
        context.saveGState()
        context.clip(to: box.insetBy(dx: 0, dy: -box.height * 0.2))
        draw(line, centeredIn: box.insetBy(dx: 2, dy: 0), leftAligned: true, context: context)
        context.restoreGState()
      }
    case .check(let placement):
      let box = rect(of: placement, pageSize: pageSize)
      let side = min(box.width, box.height)
      let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
      context.saveGState()
      context.setStrokeColor(textColor)
      context.setLineWidth(max(side * 0.13, 0.8))
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.move(to: CGPoint(x: square.minX + side * 0.2, y: square.minY + side * 0.5))
      context.addLine(to: CGPoint(x: square.minX + side * 0.42, y: square.minY + side * 0.24))
      context.addLine(to: CGPoint(x: square.minX + side * 0.82, y: square.minY + side * 0.8))
      context.strokePath()
      context.restoreGState()
    case .stamp(let stamp):
      stamp.art.draw(in: rect(of: stamp.placement, pageSize: pageSize), context: context)
    }
  }
  private static func attributed(_ text: String, fontName: String, size: CGFloat, color: CGColor) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
      ])
  }
  /// The largest size at which the text fits, so a long answer shrinks rather than running off its box.
  static func fittedLine(
    _ text: String, fontName: String, color: CGColor, width: CGFloat, height: CGFloat, largest: CGFloat,
    smallest: CGFloat = 3
  ) -> CTLine {
    var size = max(largest, smallest)
    while true {
      let line = CTLineCreateWithAttributedString(attributed(text, fontName: fontName, size: size, color: color))
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
      if size <= smallest || (lineWidth <= width && ascent + descent <= height * 1.15) { return line }
      size = max(size - 0.5, smallest)
    }
  }
  static func draw(_ line: CTLine, centeredIn rect: CGRect, leftAligned: Bool, context: CGContext) {
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = CGPoint(
      x: leftAligned ? rect.minX : rect.midX - width / 2, y: rect.midY - (ascent - descent) / 2)
    CTLineDraw(line, context)
    context.restoreGState()
  }
  private static func drawParagraph(_ text: String, in box: CGRect, context: CGContext) {
    let inset = box.insetBy(dx: 2, dy: 1)
    guard inset.width > 0, inset.height > 0 else { return }
    var size: CGFloat = 11
    var setter = CTFramesetterCreateWithAttributedString(attributed(text, fontName: "Helvetica", size: size, color: textColor))
    while size > 4 {
      let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRange(), nil, CGSize(width: inset.width, height: .greatestFiniteMagnitude), nil)
      if fitted.height <= inset.height { break }
      size -= 0.5
      setter = CTFramesetterCreateWithAttributedString(attributed(text, fontName: "Helvetica", size: size, color: textColor))
    }
    context.saveGState()
    context.textMatrix = .identity
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: inset, transform: nil), nil), context)
    context.restoreGState()
  }
}
