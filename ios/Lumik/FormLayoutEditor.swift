import PDFKit
import SwiftUI

struct FormLayoutRequest: Identifiable {
  let template: FormTemplate
  let pdf: Data
  /// The answers to show on the page while moving things, when opened from a filled form.
  var values: [String: JSONValue] = [:]
  var id: String { template.id }
}
/// How far a page is zoomed and panned inside its canvas. Points are measured from the canvas center.
struct PageViewport: Equatable {
  static let zoomRange: ClosedRange<CGFloat> = 1...6
  private(set) var zoom: CGFloat = 1
  private(set) var pan = CGSize.zero

  /// Changes the zoom while keeping the page point under `anchor` exactly where it is.
  mutating func setZoom(_ target: CGFloat, around anchor: CGPoint = .zero, fitted: CGSize, canvas: CGSize) {
    let next = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    let ratio = next / zoom
    pan = CGSize(
      width: anchor.x - (anchor.x - pan.width) * ratio,
      height: anchor.y - (anchor.y - pan.height) * ratio)
    zoom = next
    clamp(fitted: fitted, canvas: canvas)
  }
  mutating func setPan(_ target: CGSize, fitted: CGSize, canvas: CGSize) {
    pan = target
    clamp(fitted: fitted, canvas: canvas)
  }
  /// A zoomed page can reach each edge, but never drift away from the canvas.
  mutating func clamp(fitted: CGSize, canvas: CGSize) {
    let reachX = max((fitted.width * zoom - canvas.width) / 2 + 20, 0)
    let reachY = max((fitted.height * zoom - canvas.height) / 2 + 64, 0)
    pan.width = zoom <= 1 ? 0 : min(max(pan.width, -reachX), reachX)
    pan.height = zoom <= 1 ? 0 : min(max(pan.height, -reachY), reachY)
  }
}
/// One PDF page, sized to fit, with its overlay laid out in page-fraction coordinates.
struct PDFPageSurface<Overlay: View>: View {
  let document: PDFDocument
  let page: Int
  /// Pixels along the page's longer side. Zooming asks for more, so text stays sharp.
  var resolution: CGFloat = 1500
  @ViewBuilder let overlay: (CGSize) -> Overlay
  @State private var image: Image?
  var body: some View {
    Group {
      if let image {
        image.resizable().scaledToFit()
          .background(.white)
          .overlay { GeometryReader { overlay($0.size) } }
          .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: "\(page)-\(resolution)") { render() }
  }
  private func render() {
    guard let pdfPage = document.page(at: page) else { return }
    let size = FormRenderer.displaySize(of: pdfPage)
    let scale = resolution / max(size.width, size.height, 1)
    let thumbnail = pdfPage.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
    #if os(macOS)
      image = Image(nsImage: thumbnail)
    #else
      image = Image(uiImage: thumbnail)
    #endif
  }
}
/// A box on the page that moves when dragged and resizes from its corner.
struct DraggablePlacement<Content: View>: View {
  @Binding var placement: FormPlacement
  let pageSize: CGSize
  var isSelected = false
  /// When false a drag passes through to whatever is behind the box, such as panning the page.
  var isMovable = true
  var tint = Color.buddyGreen
  var minimumSide = 0.008
  var onSelect: () -> Void = {}
  @ViewBuilder var content: Content
  @State private var moveStart: FormPlacement?
  @State private var resizeStart: FormPlacement?
  private var frame: CGRect {
    CGRect(
      x: placement.x * pageSize.width, y: placement.y * pageSize.height,
      width: max(placement.w * pageSize.width, 6), height: max(placement.h * pageSize.height, 6))
  }
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Rectangle().fill(tint.opacity(isSelected ? 0.22 : 0.12))
        .overlay { Rectangle().strokeBorder(tint, lineWidth: isSelected ? 1.5 : 0.75) }
        .overlay { content }
        .contentShape(Rectangle())
        .gesture(moveGesture, including: isMovable ? .all : .subviews)
        .onTapGesture { onSelect() }
      if isSelected {
        Circle().fill(tint).overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
          .frame(width: 14, height: 14).offset(x: 7, y: 7)
          .contentShape(Rectangle().size(width: 30, height: 30))
          .gesture(resizeGesture)
          .accessibilityLabel("Resize")
      }
    }
    .frame(width: frame.width, height: frame.height)
    .position(x: frame.midX, y: frame.midY)
  }
  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 2).onChanged { value in
      let start = moveStart ?? placement
      if moveStart == nil {
        moveStart = placement
        onSelect()
      }
      placement.manual = true
      placement.x = min(max(start.x + value.translation.width / pageSize.width, 0), 1 - placement.w)
      placement.y = min(max(start.y + value.translation.height / pageSize.height, 0), 1 - placement.h)
    }.onEnded { _ in
      moveStart = nil
      Haptics.tap()
    }
  }
  private var resizeGesture: some Gesture {
    DragGesture(minimumDistance: 0).onChanged { value in
      let start = resizeStart ?? placement
      if resizeStart == nil { resizeStart = placement }
      placement.manual = true
      placement.w = min(max(start.w + value.translation.width / pageSize.width, minimumSide), 1 - placement.x)
      placement.h = min(max(start.h + value.translation.height / pageSize.height, minimumSide), 1 - placement.y)
    }.onEnded { _ in
      resizeStart = nil
      Haptics.tap()
    }
  }
}
/// Back and forward through pages, under a canvas.
struct PagePager: View {
  @Binding var page: Int
  let count: Int
  var body: some View {
    HStack(spacing: 14) {
      Button("Previous page", systemImage: "chevron.left") {
        Haptics.tap()
        page -= 1
      }.disabled(page <= 0)
      Text("Page \(page + 1) of \(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      Button("Next page", systemImage: "chevron.right") {
        Haptics.tap()
        page += 1
      }.disabled(page >= count - 1)
    }.labelStyle(.iconOnly).padding(.horizontal, 12).padding(.vertical, 8)
      .background(.regularMaterial, in: Capsule())
  }
}
/// Where each field lands on the PDF. AI's boxes on a scan are close, not perfect, so they can be moved here.
struct FormLayoutEditor: View {
  let request: FormLayoutRequest
  var onSave: ([FormSection]) -> Void = { _ in }
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @State private var document: PDFDocument?
  @State private var sections: [FormSection]
  @State private var title: String
  @State private var page = 0
  @State private var selectedID: String?
  @State private var selectedBoxID: String?
  @State private var printed: FormRenderer.PrintedLayout?
  @State private var viewport = PageViewport()
  @State private var pinchStart: PageViewport?
  @State private var panOrigin: CGSize?
  @State private var pageResolution: CGFloat = 1500
  #if os(macOS)
    @State private var isHoveringCanvas = false
    @State private var scrollMonitor: Any?
  #endif
  init(request: FormLayoutRequest, onSave: @escaping ([FormSection]) -> Void = { _ in }) {
    self.request = request
    self.onSave = onSave
    _sections = State(initialValue: request.template.sections)
    _title = State(initialValue: request.template.title)
  }
  private var isRegular: Bool {
    #if os(macOS)
      true
    #else
      sizeClass != .compact
    #endif
  }
  private struct BoxRef: Identifiable {
    let section: Int
    let field: Int
    let option: Int?
    let placement: Int
    let label: String
    let fieldID: String
    var id: String { "\(fieldID)-\(option ?? -1)-\(placement)" }
  }
  private var boxes: [BoxRef] {
    var result: [BoxRef] = []
    for (s, section) in sections.enumerated() {
      for (f, field) in section.fields.enumerated() {
        for (p, placement) in field.placements.enumerated() where placement.page == page {
          result.append(BoxRef(section: s, field: f, option: nil, placement: p, label: field.label, fieldID: field.id))
        }
        for (o, option) in field.options.enumerated() {
          for (p, placement) in option.placements.enumerated() where placement.page == page {
            result.append(BoxRef(section: s, field: f, option: o, placement: p, label: option.label, fieldID: field.id))
          }
        }
      }
    }
    return result
  }
  private func binding(_ box: BoxRef) -> Binding<FormPlacement> {
    // A box's view can read once more after its field is deleted, so a stale position falls back.
    let snapshot = current(box) ?? FormPlacement(page: page, x: 0, y: 0, w: 0, h: 0)
    return Binding {
      current(box) ?? snapshot
    } set: { value in
      guard current(box) != nil else { return }
      if let option = box.option {
        sections[box.section].fields[box.field].options[option].placements[box.placement] = value
      } else {
        sections[box.section].fields[box.field].placements[box.placement] = value
      }
    }
  }
  private func current(_ box: BoxRef) -> FormPlacement? {
    guard sections.indices.contains(box.section), sections[box.section].fields.indices.contains(box.field),
      sections[box.section].fields[box.field].id == box.fieldID
    else { return nil }
    let field = sections[box.section].fields[box.field]
    if let option = box.option {
      guard field.options.indices.contains(option), field.options[option].placements.indices.contains(box.placement)
      else { return nil }
      return field.options[option].placements[box.placement]
    }
    return field.placements.indices.contains(box.placement) ? field.placements[box.placement] : nil
  }
  private var selectedIndex: (section: Int, field: Int)? {
    for (s, section) in sections.enumerated() {
      if let f = section.fields.firstIndex(where: { $0.id == selectedID }) { return (s, f) }
    }
    return nil
  }
  var body: some View {
    NavigationStack {
      Group {
        if isRegular {
          HStack(spacing: 0) {
            canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector.frame(width: 320)
          }
        } else {
          VStack(spacing: 0) {
            canvas.frame(maxHeight: .infinity)
            Divider()
            inspector.frame(height: 240)
          }
        }
      }
      .navigationTitle("Form Fields")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { addMenu }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }.disabled(store.busy != nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .task { await load() }
    }
    // Dragging a box must never pull the sheet down and lose the edits.
    .interactiveDismissDisabled()
  }
  private var addMenu: some View {
    Menu {
      Button("Text", systemImage: "textformat") { add("text", label: "Text") }
      Button("Long text", systemImage: "text.alignleft") { add("multiline", label: "Notes") }
      Button("Date", systemImage: "calendar") { add("date", label: "Date") }
      Button("Number", systemImage: "number") { add("number", label: "Number") }
      Button("Checkbox", systemImage: "checkmark.square") { add("checkbox", label: "Checkbox") }
      Button("Signature", systemImage: "signature") { add("signature", label: "Signature") }
    } label: {
      Label("Add field", systemImage: "plus")
    }
  }
  private var canvas: some View {
    GeometryReader { proxy in
      let canvasSize = proxy.size
      let fitted = fittedPageSize(in: canvasSize)
      ZStack {
        if let document {
          PDFPageSurface(document: document, page: page, resolution: pageResolution) { size in
            ForEach(boxes) { box in
              DraggablePlacement(
                placement: binding(box), pageSize: size, isSelected: box.fieldID == selectedID,
                isMovable: boxIsMovable(box),
                onSelect: {
                  Haptics.tap()
                  selectedID = box.fieldID
                  selectedBoxID = box.id
                }
              ) {
                ink(of: box, viewSize: size)
              }
            }
          }
          .frame(width: fitted.width * viewport.zoom, height: fitted.height * viewport.zoom)
          .id(page)
          // The pager sits under the page, so the page centers in the space above it.
          .offset(x: viewport.pan.width, y: viewport.pan.height - 22)
        } else {
          ProgressView()
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .background(Color.secondary.opacity(0.1))
      .clipped()
      .contentShape(Rectangle())
      .gesture(panGesture(fitted: fitted, canvas: canvasSize))
      .simultaneousGesture(zoomGesture(fitted: fitted, canvas: canvasSize))
      .onTapGesture(count: 2) { location in
        let anchor = CGPoint(x: location.x - canvasSize.width / 2, y: location.y - canvasSize.height / 2)
        Haptics.tap()
        setZoom(viewport.zoom > 1 ? 1 : 2.5, around: anchor, fitted: fitted, canvas: canvasSize)
      }
      .overlay(alignment: .bottom) {
        if let document {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              PagePager(page: $page, count: document.pageCount)
              zoomControls(fitted: fitted, canvas: canvasSize)
            }
            VStack(spacing: 6) {
              zoomControls(fitted: fitted, canvas: canvasSize)
              PagePager(page: $page, count: document.pageCount)
            }
          }.padding(.bottom, 14)
        }
      }
      .onChange(of: page) { viewport.setPan(.zero, fitted: fitted, canvas: canvasSize) }
      .onChange(of: canvasSize) { viewport.clamp(fitted: fitted, canvas: canvasSize) }
      #if os(macOS)
        .onContinuousHover { phase in
          if case .active = phase { isHoveringCanvas = true } else { isHoveringCanvas = false }
        }
        .onAppear { watchScrolling(fitted: { fittedPageSize(in: canvasSize) }, canvas: canvasSize) }
        .onDisappear {
          if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
          scrollMonitor = nil
        }
      #endif
    }
  }
  private func fittedPageSize(in canvas: CGSize) -> CGSize {
    let page = printed?.size(of: self.page) ?? CGSize(width: 3, height: 4)
    let available = CGSize(width: max(canvas.width - 40, 1), height: max(canvas.height - 84, 1))
    let scale = min(available.width / max(page.width, 1), available.height / max(page.height, 1))
    return CGSize(width: page.width * scale, height: page.height * scale)
  }
  /// On touch screens a form can be nearly all boxes, so a drag only moves the one that's selected.
  /// Any other drag pans the page, and two fingers can pinch without nudging a box.
  private func boxIsMovable(_ box: BoxRef) -> Bool {
    #if os(macOS)
      true
    #else
      box.id == selectedBox?.id
    #endif
  }
  private func panGesture(fitted: CGSize, canvas: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 2).onChanged { value in
      // A pinch also moves its fingers. Panning restarts from wherever the pinch leaves the page.
      guard pinchStart == nil else {
        panOrigin = nil
        return
      }
      let origin = panOrigin ?? CGSize(
        width: viewport.pan.width - value.translation.width, height: viewport.pan.height - value.translation.height)
      panOrigin = origin
      viewport.setPan(
        CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height),
        fitted: fitted, canvas: canvas)
    }.onEnded { _ in panOrigin = nil }
  }
  private func zoomGesture(fitted: CGSize, canvas: CGSize) -> some Gesture {
    MagnifyGesture().onChanged { value in
      let start = pinchStart ?? viewport
      if pinchStart == nil { pinchStart = viewport }
      let anchor = CGPoint(
        x: value.startAnchor.x * canvas.width - canvas.width / 2,
        y: value.startAnchor.y * canvas.height - canvas.height / 2)
      var next = start
      next.setZoom(start.zoom * value.magnification, around: anchor, fitted: fitted, canvas: canvas)
      viewport = next
    }.onEnded { _ in
      pinchStart = nil
      sharpenPage()
    }
  }
  private func setZoom(_ target: CGFloat, around anchor: CGPoint = .zero, fitted: CGSize, canvas: CGSize) {
    var next = viewport
    next.setZoom(target, around: anchor, fitted: fitted, canvas: canvas)
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { viewport = next }
    sharpenPage()
  }
  /// The page redraws only when a gesture ends, so pinching itself stays smooth.
  private func sharpenPage() {
    let needed = 1500 * min(viewport.zoom.rounded(.up), 3)
    if needed != pageResolution { pageResolution = needed }
  }
  private func zoomControls(fitted: CGSize, canvas: CGSize) -> some View {
    HStack(spacing: 14) {
      Button("Zoom out", systemImage: "minus.magnifyingglass") {
        Haptics.tap()
        setZoom(viewport.zoom / 1.5, fitted: fitted, canvas: canvas)
      }
      .disabled(viewport.zoom <= PageViewport.zoomRange.lowerBound)
      .keyboardShortcut("-", modifiers: .command)
      Button {
        Haptics.tap()
        setZoom(1, fitted: fitted, canvas: canvas)
      } label: {
        Text(viewport.zoom, format: .percent.precision(.fractionLength(0)).scale(100))
          .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Fit page")
      .accessibilityValue(Text(viewport.zoom, format: .percent.precision(.fractionLength(0)).scale(100)))
      .keyboardShortcut("0", modifiers: .command)
      Button("Zoom in", systemImage: "plus.magnifyingglass") {
        Haptics.tap()
        setZoom(viewport.zoom * 1.5, fitted: fitted, canvas: canvas)
      }
      .disabled(viewport.zoom >= PageViewport.zoomRange.upperBound)
      .keyboardShortcut("=", modifiers: .command)
    }.labelStyle(.iconOnly).padding(.horizontal, 12).padding(.vertical, 8)
      .background(.regularMaterial, in: Capsule())
  }
  #if os(macOS)
    /// Two-finger scrolling and the mouse wheel pan a zoomed page, as they do in any Mac document.
    private func watchScrolling(fitted: @escaping () -> CGSize, canvas: CGSize) {
      guard scrollMonitor == nil else { return }
      let viewport = $viewport
      let hovering = $isHoveringCanvas
      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        guard hovering.wrappedValue, viewport.wrappedValue.zoom > 1 else { return event }
        var next = viewport.wrappedValue
        next.setPan(
          CGSize(width: next.pan.width + event.scrollingDeltaX, height: next.pan.height + event.scrollingDeltaY),
          fitted: fitted(), canvas: canvas)
        viewport.wrappedValue = next
        return nil
      }
    }
  #endif
  @ViewBuilder private var inspector: some View {
    Form {
      if let index = selectedIndex {
        selectedFieldSections(index)
      } else {
        Section("Form name") {
          TextField("Name", text: $title).labelsHidden()
        }
        if sections.flatMap(\.fields).isEmpty {
          Section {
            Text("We couldn’t find anywhere to write on this PDF. Add fields, then drag them where they belong.")
              .foregroundStyle(.secondary)
          }
        }
        ForEach(sections) { section in
          Section(section.title) {
            ForEach(section.fields) { field in
              Button {
                Haptics.tap()
                selectedID = field.id
                if let target = field.placements.first?.page ?? field.options.first?.placements.first?.page {
                  page = target
                }
              } label: {
                LabeledContent(field.label, value: field.typeName).contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
        }
      }
    }.formStyle(.grouped)
  }
  @ViewBuilder private func selectedFieldSections(_ index: (section: Int, field: Int)) -> some View {
    let snapshot = sections[index.section].fields[index.field]
    let field = Binding(
      get: {
        sections.indices.contains(index.section) && sections[index.section].fields.indices.contains(index.field)
          ? sections[index.section].fields[index.field] : snapshot
      },
      set: { value in
        guard sections.indices.contains(index.section), sections[index.section].fields.indices.contains(index.field)
        else { return }
        sections[index.section].fields[index.field] = value
      })
    Section {
      TextField("Label", text: field.label)
      Picker("Type", selection: field.type) {
        Text("Text").tag("text")
        Text("Long text").tag("multiline")
        Text("Date").tag("date")
        Text("Number").tag("number")
        Text("Checkbox").tag("checkbox")
        Text("Signature").tag("signature")
        if !field.wrappedValue.options.isEmpty { Text("Choice").tag("choice") }
      }
      Toggle("Required", isOn: field.required)
    } header: {
      Text("Field")
    } footer: {
      #if os(macOS)
        Text("Drag its box on the page to move it, and its corner to resize it. Pinch or use the zoom buttons for a closer look. Saved positions apply to every copy of this form.")
      #else
        Text("Tap a box to select it, then drag to move it or drag its corner to resize it. Pinch to zoom, and drag anywhere else to pan. Saved positions apply to every copy of this form.")
      #endif
    }
    if let box = selectedBox {
      Section {
        HStack {
          Button("Move left", systemImage: "arrow.left") { nudge(box, x: -1, y: 0) }
          Spacer()
          Button("Move up", systemImage: "arrow.up") { nudge(box, x: 0, y: -1) }
          Spacer()
          Button("Move down", systemImage: "arrow.down") { nudge(box, x: 0, y: 1) }
          Spacer()
          Button("Move right", systemImage: "arrow.right") { nudge(box, x: 1, y: 0) }
        }.labelStyle(.iconOnly).buttonStyle(.bordered)
      } header: {
        Text("Fine tune")
      } footer: {
        Text("Moves the selected box one point at a time.")
      }
    }
    Section {
      Button("Also write it on this page", systemImage: "plus.square.on.square") {
        Haptics.tap()
        field.wrappedValue.placements.append(defaultPlacement(for: field.wrappedValue.type))
      }
      Button("Done", systemImage: "checkmark") {
        Haptics.tap()
        selectedID = nil
      }
      Button("Delete field", systemImage: "trash", role: .destructive) {
        Haptics.tap()
        sections[index.section].fields.remove(at: index.field)
        if sections[index.section].fields.isEmpty { sections.remove(at: index.section) }
        selectedID = nil
      }
    }
  }
  private func load() async {
    let pdf = request.pdf
    let original = sections
    // Boxes open where the ink is actually drawn, so what gets moved is what the PDF shows.
    sections = (try? await Task.detached(priority: .userInitiated) {
      try FormRenderer.editableSections(base: pdf, sections: original)
    }.value) ?? original
    guard let opened = PDFDocument(data: pdf) else { return }
    printed = FormRenderer.PrintedLayout(document: opened, base: pdf)
    document = opened
  }
  /// The box's real answer, at the size the PDF draws it. Empty fields show their label instead.
  @ViewBuilder private func ink(of box: BoxRef, viewSize: CGSize) -> some View {
    let pageSize = printed?.size(of: page) ?? viewSize
    let scale = viewSize.width / max(pageSize.width, 1)
    if let field = field(of: box), let placement = current(box) {
      let value = FormRenderer.value(of: field, in: request.values)
      if box.option != nil || field.type == "checkbox" {
        if isTicked(box, field: field, value: value) {
          Image(systemName: "checkmark").resizable().scaledToFit().fontWeight(.bold).padding(1)
            .foregroundStyle(.black)
        } else if request.values.isEmpty {
          boxLabel(box)
        }
      } else if let text = FormRenderer.writtenText(of: field, value: value, at: placement, layout: printed) {
        let multiline = field.type == "multiline"
        let points = multiline ? 11 : min(max(placement.h * pageSize.height * 0.72, 6), 11)
        Text(text).font(.custom("Helvetica", size: points * scale)).lineLimit(multiline ? nil : 1)
          .minimumScaleFactor(0.45).foregroundStyle(.black)
          .padding(.horizontal, 2 * scale)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: multiline ? .topLeading : .leading)
      } else {
        boxLabel(box)
      }
    }
  }
  private func boxLabel(_ box: BoxRef) -> some View {
    Text(box.label).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
      .padding(.horizontal, 2).foregroundStyle(Color.buddyGreen)
  }
  private func field(of box: BoxRef) -> FormField? {
    guard sections.indices.contains(box.section), sections[box.section].fields.indices.contains(box.field),
      sections[box.section].fields[box.field].id == box.fieldID
    else { return nil }
    return sections[box.section].fields[box.field]
  }
  private func isTicked(_ box: BoxRef, field: FormField, value: JSONValue?) -> Bool {
    if let option = box.option, field.options.indices.contains(option) {
      if case .string(let selected)? = value { return selected == field.options[option].value }
      return false
    }
    if case .bool(true)? = value { return true }
    return false
  }
  private var selectedBox: BoxRef? {
    boxes.first { $0.id == selectedBoxID } ?? boxes.first { $0.fieldID == selectedID }
  }
  private func nudge(_ box: BoxRef, x: CGFloat, y: CGFloat) {
    guard var placement = current(box), let size = printed?.size(of: page), size.width > 0, size.height > 0 else { return }
    Haptics.tap()
    placement.manual = true
    placement.x = min(max(placement.x + x / size.width, 0), 1 - placement.w)
    placement.y = min(max(placement.y + y / size.height, 0), 1 - placement.h)
    binding(box).wrappedValue = placement
    selectedBoxID = box.id
  }
  /// Everything was reviewed on the page, so all of it stays exactly as shown from now on.
  private func confirmed(_ sections: [FormSection]) -> [FormSection] {
    func fixed(_ placements: [FormPlacement]) -> [FormPlacement] {
      placements.map { placement in
        var placement = placement
        placement.manual = true
        return placement
      }
    }
    return sections.map { section in
      var section = section
      section.fields = section.fields.map { field in
        var field = field
        field.placements = fixed(field.placements)
        field.options = field.options.map { option in
          var option = option
          option.placements = fixed(option.placements)
          return option
        }
        return field
      }
      return section
    }
  }
  private func defaultPlacement(for type: String) -> FormPlacement {
    let aspect = document?.page(at: page).map { size in
      let display = FormRenderer.displaySize(of: size)
      return display.width / max(display.height, 1)
    } ?? 0.77
    var placement: FormPlacement
    switch type {
    case "checkbox":
      placement = FormPlacement(page: page, x: 0.47, y: 0.47, w: 0.03, h: 0.03 * aspect)
    case "signature":
      placement = FormPlacement(page: page, x: 0.3, y: 0.45, w: 0.4, h: 0.07)
    case "multiline":
      placement = FormPlacement(page: page, x: 0.2, y: 0.42, w: 0.6, h: 0.14)
    default:
      placement = FormPlacement(page: page, x: 0.3, y: 0.48, w: 0.4, h: 0.03)
    }
    placement.manual = true
    return placement
  }
  private func add(_ type: String, label: String) {
    Haptics.tap()
    let field = FormField(
      id: "f" + UUID().uuidString.prefix(8).lowercased(), label: label, type: type,
      placements: [defaultPlacement(for: type)])
    if sections.isEmpty {
      sections.append(FormSection(id: "s" + UUID().uuidString.prefix(8).lowercased(), title: "Details", fields: []))
    }
    sections[sections.count - 1].fields.append(field)
    selectedID = field.id
  }
  private func save() {
    let sections = confirmed(sections)
    Task {
      if await store.perform("Saving form…", success: "Form saved", {
        try await store.saveTemplate(request.template, title: title, sections: sections)
      }) {
        onSave(sections)
        dismiss()
      }
    }
  }
}
