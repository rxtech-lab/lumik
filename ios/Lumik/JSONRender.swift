import Charts
import SwiftUI

// Draws json-render specs natively. @json-render has no SwiftUI renderer, so this implements the
// catalog and the expressions the backend allows in backend/lib/ui-catalog.ts. Keep them in step.
// Specs come from AI reading untrusted PDFs, so components only display data; none perform actions.
@MainActor @Observable final class JSONRenderState {
  var root: JSONValue
  init(_ root: JSONValue) { self.root = root }
  private static func parts(_ pointer: String) -> [String] {
    pointer.split(separator: "/", omittingEmptySubsequences: true).map {
      $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
  }
  func value(at pointer: String) -> JSONValue? {
    Self.parts(pointer).reduce(Optional(root)) { current, part in
      switch current {
      case .object(let values): values[part]
      case .array(let values): Int(part).flatMap { values.indices.contains($0) ? values[$0] : nil }
      default: nil
      }
    }
  }
  func set(_ pointer: String, to value: JSONValue) {
    func write(_ node: JSONValue, _ path: ArraySlice<String>) -> JSONValue {
      guard let head = path.first else { return value }
      var object = node.object
      object[head] = write(object[head] ?? .null, path.dropFirst())
      return .object(object)
    }
    root = write(root, Self.parts(pointer)[...])
  }
}
private struct RenderScope {
  var item: JSONValue?
  var index: Int?
}
struct JSONRenderView: View {
  let spec: JSONValue
  let state: JSONRenderState
  var body: some View {
    JSONRenderNode(
      key: spec.object["root"]?.string ?? "", elements: spec.object["elements"]?.object ?? [:],
      state: state, scope: RenderScope(), depth: 0)
  }
}
private struct JSONRenderNode: View {
  let key: String
  let elements: [String: JSONValue]
  let state: JSONRenderState
  let scope: RenderScope
  let depth: Int
  @Environment(\.stretchesRenderCards) private var stretchesCards
  private var element: [String: JSONValue] { elements[key]?.object ?? [:] }
  var body: some View {
    if depth < 24, !element.isEmpty, visible(element["visible"]) { content }
  }
  // MARK: Expressions
  private func prop(_ name: String) -> JSONValue? { resolve(element["props"]?.object[name]) }
  private func text(_ name: String) -> String? { prop(name)?.uiText }
  private func resolve(_ value: JSONValue?) -> JSONValue? {
    switch value {
    case .object(let object):
      if case .string(let path)? = object["$state"] ?? object["$bindState"] {
        return state.value(at: path)
      }
      if case .string(let field)? = object["$item"] { return itemValue(field) }
      if object["$index"] != nil { return scope.index.map { .number(Double($0)) } }
      if case .string(let template)? = object["$template"] { return .string(fill(template)) }
      return .object(object.mapValues { resolve($0) ?? .null })
    case .array(let values): return .array(values.map { resolve($0) ?? .null })
    default: return value
    }
  }
  private func itemValue(_ field: String) -> JSONValue? {
    field.isEmpty ? scope.item : scope.item?.object[field]
  }
  private func fill(_ template: String) -> String {
    var result = template
    for match in template.matches(of: /\$\{([^}]+)\}/).reversed() {
      let name = String(match.output.1)
      let value = name.hasPrefix("/") ? state.value(at: name) : itemValue(name) ?? state.value(at: "/" + name)
      result.replaceSubrange(match.range, with: value?.uiText ?? "")
    }
    return result
  }
  private func visible(_ condition: JSONValue?) -> Bool {
    switch condition {
    case nil: return true
    case .bool(let value): return value
    case .array(let all): return all.allSatisfy { visible($0) }
    case .object(let object):
      if let all = object["$and"]?.array { return all.allSatisfy { visible($0) } }
      if let any = object["$or"]?.array { return any.contains { visible($0) } }
      let value = resolve(.object(object.filter { $0.key == "$state" || $0.key == "$item" || $0.key == "$index" }))
      var result = value?.isTruthy ?? false
      let number = value?.numberValue
      for (name, other) in object {
        let bound = resolve(other)?.numberValue
        switch name {
        case "eq": result = (value ?? .null) == (resolve(other) ?? .null)
        case "neq": result = (value ?? .null) != (resolve(other) ?? .null)
        case "gt": result = number.flatMap { n in bound.map { n > $0 } } ?? false
        case "gte": result = number.flatMap { n in bound.map { n >= $0 } } ?? false
        case "lt": result = number.flatMap { n in bound.map { n < $0 } } ?? false
        case "lte": result = number.flatMap { n in bound.map { n <= $0 } } ?? false
        default: break
        }
      }
      return object["not"] == .bool(true) ? !result : result
    default: return condition?.isTruthy ?? false
    }
  }
  private func binding(_ name: String) -> Binding<JSONValue> {
    let raw = element["props"]?.object[name]
    guard case .string(let path)? = raw?.object["$bindState"] else {
      return .constant(resolve(raw) ?? .null)
    }
    let state = state
    return Binding(get: { state.value(at: path) ?? .null }, set: { Haptics.tap(); state.set(path, to: $0) })
  }
  // MARK: Components
  private var childViews: some View {
    let keys = element["children"]?.array.map(\.string) ?? []
    let repeated = repeatedItems
    return ForEach(Array((repeated ?? [nil]).enumerated()), id: \.offset) { index, item in
      ForEach(keys, id: \.self) { key in
        JSONRenderNode(
          key: key, elements: elements, state: state,
          scope: repeated == nil ? scope : RenderScope(item: item, index: index), depth: depth + 1)
      }
    }
  }
  private var repeatedItems: [JSONValue?]? {
    guard let path = element["repeat"]?.object["statePath"] else { return nil }
    let source = if case .string(let pointer) = path { state.value(at: pointer) } else { resolve(path) }
    return (source?.array ?? []).map(Optional.some)
  }
  private var gap: CGFloat {
    switch element["props"]?.object["gap"]?.string {
    case "small": 6
    case "large": 24
    default: 12
    }
  }
  @ViewBuilder private var content: some View {
    switch element["type"]?.string {
    case "Stack":
      if element["props"]?.object["direction"]?.string == "horizontal" {
        // Fixing the vertical size lets the row settle on its tallest card for the others to match.
        HStack(alignment: .top, spacing: gap) { AnyView(childViews) }
          .fixedSize(horizontal: false, vertical: true)
          .environment(\.stretchesRenderCards, true)
      } else {
        VStack(alignment: .leading, spacing: gap) { AnyView(childViews) }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    case "Grid":
      EqualHeightGrid { AnyView(childViews) }.environment(\.stretchesRenderCards, true)
    case "Card":
      VStack(alignment: .leading, spacing: 12) {
        if text("title") != nil || text("subtitle") != nil {
          VStack(alignment: .leading, spacing: 2) {
            if let title = text("title") { Text(title).font(.headline) }
            if let subtitle = text("subtitle") {
              Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
        AnyView(childViews)
      }.padding(16)
        .frame(maxWidth: .infinity, maxHeight: stretchesCards ? .infinity : nil, alignment: .topLeading)
        .cardSurface()
    case "Heading": Text(text("text") ?? "").font(.title3.bold())
    case "Text":
      Text(text("text") ?? "").foregroundStyle(tone(text("tone")))
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    case "Badge":
      Text(text("text") ?? "").font(.caption.weight(.medium)).padding(.horizontal, 10)
        .padding(.vertical, 4).foregroundStyle(tone(text("tone")))
        .background(Color.secondary.opacity(0.12), in: Capsule())
    case "Divider": Divider()
    case "Metric": metric
    case "KeyValue":
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array((prop("items")?.array ?? []).enumerated()), id: \.offset) { _, item in
          LabeledContent(item.object["label"]?.uiText ?? "") {
            Text(item.object["value"]?.uiText ?? "—").textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
        }
      }
    case "Table": table
    case "BarChart", "LineChart", "PieChart": chart(element["type"]?.string ?? "")
    case "TextInput":
      TextField(
        text("label") ?? "",
        text: Binding(
          get: { binding("value").wrappedValue.uiText ?? "" },
          set: { binding("value").wrappedValue = .string($0) }),
        prompt: text("placeholder").map { Text($0) }
      )
    case "NumberInput":
      TextField(
        text("label") ?? "",
        value: Binding(
          get: { binding("value").wrappedValue.numberValue },
          set: { binding("value").wrappedValue = $0.map { .number($0) } ?? .null }),
        format: .number)
    case "DateInput": DateInputRow(label: text("label") ?? "", value: binding("value"))
    case "Toggle":
      Toggle(
        text("label") ?? "",
        isOn: Binding(
          get: { binding("value").wrappedValue.isTruthy },
          set: { binding("value").wrappedValue = .bool($0) }))
    case "Select": select
    default: EmptyView()  // Skipped so a newer spec still draws what this version understands.
    }
  }
  private var metric: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text("label") ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      Text(formatted(prop("value"), format: text("format"), currency: text("currency")))
        .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
        .minimumScaleFactor(0.6).lineLimit(1)
      if let detail = text("detail") {
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }.padding(16)
      .frame(maxWidth: .infinity, maxHeight: stretchesCards ? .infinity : nil, alignment: .topLeading)
      .cardSurface()
  }
  private var table: some View {
    let columns = prop("columns")?.array.map(\.object) ?? []
    let rows = Array((prop("rows")?.array ?? []).prefix(200))
    // Fills the card while the columns fit, and scrolls sideways only once they don't.
    return ViewThatFits(in: .horizontal) {
      tableGrid(columns, rows)
      ScrollView(.horizontal) { tableGrid(columns, rows) }
    }
  }
  private func tableGrid(_ columns: [[String: JSONValue]], _ rows: [JSONValue]) -> some View {
    func alignment(_ column: [String: JSONValue]) -> Alignment {
      let isNumeric =
        switch column["format"]?.string {
        case "number", "currency", "percent": true
        case "date": false
        default: rows.first?.object[column["key"]?.string ?? ""]?.numberValue != nil
        }
      return isNumeric ? .trailing : .leading
    }
    return Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
      GridRow {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          Text(column["label"]?.uiText ?? "").font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, alignment: alignment(column))
        }
      }.padding(.bottom, 6)
      Divider()
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        if index > 0 { Divider().opacity(0.6) }
        GridRow {
          ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
            Text(
              formatted(
                row.object[column["key"]?.string ?? ""], format: column["format"]?.string,
                currency: column["currency"]?.string)
            ).font(.body).monospacedDigit().textSelection(.enabled).fixedSize()
              .frame(maxWidth: .infinity, alignment: alignment(column))
          }
        }.padding(.vertical, 8)
      }
    }
  }
  private var select: some View {
    let options = (prop("options")?.array ?? []).map { option -> (String, JSONValue) in
      if case .object(let object) = option {
        let value = object["value"] ?? .null
        return (object["label"]?.uiText ?? value.uiText ?? "", value)
      }
      return (option.uiText ?? "", option)
    }
    return Picker(text("label") ?? "", selection: binding("value")) {
      Text("Any").tag(JSONValue.null)
      ForEach(Array(options.enumerated()), id: \.offset) { _, option in
        Text(option.0).tag(option.1)
      }
    }
  }
  private func chart(_ type: String) -> some View {
    let x = element["props"]?.object["xKey"]?.string ?? ""
    let y = element["props"]?.object["yKey"]?.string ?? ""
    let points = (prop("data")?.array ?? []).prefix(60).enumerated().compactMap { index, row -> RenderPoint? in
      guard let value = row.object[y]?.numberValue else { return nil }
      return RenderPoint(id: index, label: row.object[x]?.uiText ?? "—", value: value)
    }
    return VStack(alignment: .leading, spacing: 8) {
      if let title = text("title") { Text(title).font(.headline) }
      if points.isEmpty {
        Text("No data yet").font(.callout).foregroundStyle(.secondary)
      } else {
        RenderChart(type: type, points: points).frame(height: 220)
      }
    }
  }
  private func tone(_ name: String?) -> Color {
    switch name {
    case "secondary": .secondary
    case "positive": .buddyGreen
    case "negative": .red
    case "warning": .orange
    default: .primary
    }
  }
}
extension EnvironmentValues {
  /// Set by containers that give their cards a shared height. Elsewhere a card keeps its own height,
  /// so it can't swallow the free space of a form row or sheet.
  @Entry var stretchesRenderCards = false
}
extension View {
  /// The quiet, neutral surface behind cards and tiles, drawn the same in light and dark.
  func cardSurface(cornerRadius: CGFloat = 14) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return background(.fill.quaternary, in: shape)
      .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
  }
}
/// Wraps cells into equal columns and gives every cell the height of the tallest one.
struct EqualHeightGrid: Layout {
  var minimumWidth: CGFloat = 150
  var spacing: CGFloat = 12
  /// Whether a short list widens to span the row, or keeps its cells near the minimum width.
  var fillsRow = true
  private func columnCount(_ width: CGFloat, _ count: Int) -> Int {
    let fitting = max(1, Int((width + spacing) / (minimumWidth + spacing)))
    return fillsRow ? min(fitting, count) : fitting
  }
  private func cellWidth(_ width: CGFloat, _ columns: Int) -> CGFloat {
    (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
  }
  private func rowCount(_ count: Int, _ columns: Int) -> Int { (count + columns - 1) / columns }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let ideal = minimumWidth * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
    let columns = columnCount(width, subviews.count)
    let cell = ProposedViewSize(width: cellWidth(width, columns), height: nil)
    let height = subviews.map { $0.sizeThatFits(cell).height }.max() ?? 0
    let rows = CGFloat(rowCount(subviews.count, columns))
    return CGSize(width: width, height: height * rows + spacing * (rows - 1))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard !subviews.isEmpty else { return }
    let columns = columnCount(bounds.width, subviews.count)
    let rows = CGFloat(rowCount(subviews.count, columns))
    let width = cellWidth(bounds.width, columns)
    let height = (bounds.height - spacing * (rows - 1)) / rows
    for (index, subview) in subviews.enumerated() {
      let origin = CGPoint(
        x: bounds.minX + CGFloat(index % columns) * (width + spacing),
        y: bounds.minY + CGFloat(index / columns) * (height + spacing))
      subview.place(at: origin, proposal: ProposedViewSize(width: width, height: height))
    }
  }
}
/// Slices take these in order, each stepped for its appearance. Past six, rows fold into "Other".
private let renderSeriesColors: [Color] = [
  (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70),
  (0xeda100, 0xc98500), (0xe87ba4, 0xd55181), (0x008300, 0x008300),
].map { light, dark in
  func components(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255)
  }
  let (l, d) = (components(light), components(dark))
  #if os(macOS)
    return Color(
      NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
      })
  #else
    return Color(
      UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? d : l
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
      })
  #endif
}
struct RenderPoint: Identifiable {
  let id: Int
  let label: String
  let value: Double
}
/// One series gets the accent; a pie's slices take the fixed order above. Selecting a mark names its value.
private struct RenderChart: View {
  let type: String
  let points: [RenderPoint]
  @State private var selection: String?
  private var selected: RenderPoint? { points.first { $0.label == selection } }
  private var slices: [RenderPoint] {
    guard points.count > renderSeriesColors.count else { return points }
    let shown = points.prefix(renderSeriesColors.count - 1)
    let rest = points.dropFirst(shown.count).reduce(0) { $0 + $1.value }
    return shown + [RenderPoint(id: -1, label: "Other", value: rest)]
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Group {
        if type == "PieChart" {
          Chart(slices) { point in
            SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(0.6), angularInset: 1.5)
              .cornerRadius(3).foregroundStyle(by: .value("Name", point.label))
          }.chartForegroundStyleScale(domain: slices.map(\.label), range: Array(renderSeriesColors.prefix(slices.count)))
        } else {
          Chart(points) { point in
            if type == "LineChart" {
              LineMark(x: .value("Name", point.label), y: .value("Value", point.value))
                .lineStyle(StrokeStyle(lineWidth: 2)).foregroundStyle(Color.buddyGreen)
              PointMark(x: .value("Name", point.label), y: .value("Value", point.value))
                .symbolSize(40).foregroundStyle(Color.buddyGreen)
            } else {
              BarMark(x: .value("Name", point.label), y: .value("Value", point.value))
                .cornerRadius(4).foregroundStyle(Color.buddyGreen)
            }
          }.chartXSelection(value: $selection)
        }
      }
      if type != "PieChart" {
        Text(selected.map { "\($0.label): \($0.value.formatted())" } ?? " ").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
private struct DateInputRow: View {
  let label: String
  @Binding var value: JSONValue
  private static let style = Date.ISO8601FormatStyle().year().month().day()
  private var date: Date? { value.stringValue.flatMap { try? Self.style.parse($0) } }
  var body: some View {
    if let date {
      HStack {
        DatePicker(
          label, selection: Binding(get: { date }, set: { value = .string($0.formatted(Self.style)) }),
          displayedComponents: .date)
        Button("Clear date", systemImage: "xmark.circle.fill") { value = .null }
          .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
      }
    } else {
      LabeledContent(label) {
        Button("Any date") { value = .string(Date.now.formatted(Self.style)) }
      }
    }
  }
}
private func formatted(_ value: JSONValue?, format: String?, currency: String?) -> String {
  guard let value else { return "—" }
  if let number = value.numberValue {
    switch format {
    case "currency":
      return number.formatted(.currency(code: currency ?? Locale.current.currency?.identifier ?? "USD"))
    case "percent": return (number / 100).formatted(.percent.precision(.fractionLength(0...1)))
    default: return number.formatted()
    }
  }
  if format == "date", let text = value.stringValue, let date = try? Date.ISO8601FormatStyle().year().month().day().parse(String(text.prefix(10))) {
    return date.formatted(date: .abbreviated, time: .omitted)
  }
  return value.uiText ?? "—"
}
extension JSONValue {
  var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
  var stringValue: String? { if case .string(let v) = self, !v.isEmpty { v } else { nil } }
  var isTruthy: Bool {
    switch self {
    case .null: false
    case .bool(let v): v
    case .number(let v): v != 0
    case .string(let v): !v.isEmpty
    default: true
    }
  }
  /// Display text for a scalar. Containers have no sensible one-line form, so they read as nil.
  var uiText: String? {
    switch self {
    case .string(let v): v
    case .number(let v): v.formatted()
    case .bool(let v): v ? "Yes" : "No"
    default: nil
    }
  }
}
