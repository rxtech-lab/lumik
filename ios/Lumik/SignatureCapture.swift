import SwiftUI

/// A signature to use: drawn with a finger, pointer, or trackpad, or typed.
struct SignatureCaptureView: View {
  let onDone: (SignatureArt) -> Void
  private enum Mode: Hashable {
    case draw
    case type
  }
  /// Script fonts that ship on both iPhone and Mac.
  private static let fonts = [
    ("SnellRoundhand", "Snell Roundhand"), ("BradleyHandITCTT-Bold", "Bradley Hand"),
    ("Noteworthy-Light", "Noteworthy"), ("Zapfino", "Zapfino"),
  ]
  @Environment(AppStore.self) private var store
  @State private var mode = Mode.draw
  @State private var strokes: [[CGPoint]] = []
  @State private var usedTrackpad = false
  @State private var name = ""
  @State private var font = Self.fonts[0].0
  private var result: SignatureArt? {
    switch mode {
    case .draw:
      let marks = strokes.filter { !$0.isEmpty }
      return marks.isEmpty ? nil : SignatureArt(content: .strokes(marks), method: usedTrackpad ? "trackpad" : "drawn")
    case .type:
      let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : SignatureArt(content: .typed(text: text, font: font), method: "typed")
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      Picker("Signature", selection: $mode) {
        Text("Draw").tag(Mode.draw)
        Text("Type").tag(Mode.type)
      }.pickerStyle(.segmented).labelsHidden().padding()
        .onChange(of: mode) { Haptics.tap() }
      if mode == .draw {
        drawing
      } else {
        typing
      }
    }
    .navigationTitle("Your Signature")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Continue") {
          Haptics.success()
          if let result { onDone(result) }
        }.disabled(result == nil)
      }
    }
  }
  private var drawing: some View {
    VStack(spacing: 12) {
      SignaturePad(strokes: $strokes, usedTrackpad: $usedTrackpad)
        .frame(maxWidth: 620, maxHeight: 280)
      Button("Clear", systemImage: "eraser") {
        Haptics.tap()
        strokes = []
        usedTrackpad = false
      }.disabled(strokes.isEmpty)
      Spacer(minLength: 0)
      legalNote
    }.padding(.horizontal)
  }
  private var typing: some View {
    Form {
      Section("Your name") {
        TextField("Full name", text: $name).labelsHidden()
          #if os(iOS)
            .textContentType(.name)
          #endif
      }
      Section("Style") {
        ForEach(Self.fonts, id: \.0) { option in
          Button {
            Haptics.tap()
            font = option.0
          } label: {
            HStack {
              Text(name.isEmpty ? option.1 : name)
                .font(.custom(option.0, size: option.0 == "Zapfino" ? 20 : 28)).lineLimit(1)
                .minimumScaleFactor(0.5).foregroundStyle(Color(cgColor: SignatureArt.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
                .signaturePaper()
              if font == option.0 { Image(systemName: "checkmark").foregroundStyle(Color.buddyGreen) }
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel(option.1)
        }
      }
      Section { legalNote.listRowBackground(Color.clear) }
    }.formStyle(.grouped)
  }
  private var legalNote: some View {
    Text("By continuing, you agree this mark is your signature on the PDFs you sign next.")
      .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 12)
  }
}
/// Ink follows a finger, pencil, or pointer. On Mac it can also follow a finger on the trackpad.
private struct SignaturePad: View {
  @Binding var strokes: [[CGPoint]]
  @Binding var usedTrackpad: Bool
  @State private var isStroking = false
  #if os(macOS)
    @State private var trackpadMode = false
    @State private var trackpadActive = false
  #endif
  var body: some View {
    VStack(spacing: 10) {
      GeometryReader { geometry in
        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator) }
          Rectangle().fill(.black.opacity(0.18)).frame(height: 1)
            .padding(.horizontal, 28).offset(y: geometry.size.height * 0.22)
          Canvas { context, _ in
            context.stroke(
              inkPath, with: .color(Color(cgColor: SignatureArt.ink)),
              style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
          }
          if strokes.isEmpty { hint.allowsHitTesting(false) }
          #if os(macOS)
            if trackpadMode {
              TrackpadCapture(
                size: geometry.size, active: $trackpadActive,
                began: { strokes.append([$0]) },
                moved: { if !strokes.isEmpty { strokes[strokes.count - 1].append($0) } },
                ended: { usedTrackpad = true })
            }
          #endif
        }
        .contentShape(Rectangle())
        .gesture(pointerGesture(in: geometry.size))
      }
      .accessibilityElement()
      .accessibilityLabel("Signature pad")
      .accessibilityHint("Draw your signature here")
      #if os(macOS)
        Toggle("Sign with a finger on the trackpad", isOn: $trackpadMode).toggleStyle(.switch)
          .controlSize(.small)
      #endif
    }
  }
  /// The pad is white paper in every appearance, so its text can't follow the system's colors.
  private static let hintColor = Color.black.opacity(0.6)
  @ViewBuilder private var hint: some View {
    #if os(macOS)
      Text(
        trackpadMode
          ? (trackpadActive ? "Draw with one finger on your trackpad. Press any key when you’re done." : "Click here, then draw with one finger on your trackpad.")
          : "Sign here by dragging with your trackpad or mouse."
      ).foregroundStyle(Self.hintColor).multilineTextAlignment(.center).padding()
    #else
      Text("Sign here with your finger").foregroundStyle(Self.hintColor)
    #endif
  }
  private func pointerGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0).onChanged { value in
      let point = CGPoint(
        x: min(max(value.location.x, 0), size.width), y: min(max(value.location.y, 0), size.height))
      if isStroking {
        strokes[strokes.count - 1].append(point)
      } else {
        isStroking = true
        Haptics.tap()
        strokes.append([point])
      }
    }.onEnded { _ in isStroking = false }
  }
  private var inkPath: Path {
    var path = Path()
    for stroke in strokes {
      guard let first = stroke.first else { continue }
      if stroke.count == 1 {
        path.addEllipse(in: CGRect(x: first.x - 1, y: first.y - 1, width: 2, height: 2))
        continue
      }
      path.move(to: first)
      for index in 1..<stroke.count {
        let previous = stroke[index - 1]
        let current = stroke[index]
        path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
      }
      path.addLine(to: stroke[stroke.count - 1])
    }
    return path
  }
}
#if os(macOS)
  import AppKit

  /// Maps the whole trackpad onto the pad, the way Preview does: click to start, draw without
  /// pressing, press any key to finish. The pointer is hidden and held still until then.
  private struct TrackpadCapture: NSViewRepresentable {
    let size: CGSize
    @Binding var active: Bool
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {
      view.size = size
      view.setActive = { active = $0 }
      view.began = began
      view.moved = moved
      view.ended = ended
    }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.finish() }
    final class CaptureView: NSView {
      var size = CGSize.zero
      var setActive: (Bool) -> Void = { _ in }
      var began: (CGPoint) -> Void = { _ in }
      var moved: (CGPoint) -> Void = { _ in }
      var ended: () -> Void = {}
      private var isActive = false
      private var touchID: (any NSObjectProtocol & NSCopying)?
      override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
      }
      @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
      override var acceptsFirstResponder: Bool { true }
      override func mouseDown(with event: NSEvent) {
        guard !isActive else { return }
        isActive = true
        window?.makeFirstResponder(self)
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        setActive(true)
      }
      override func keyDown(with event: NSEvent) {
        if isActive { finish() } else { super.keyDown(with: event) }
      }
      override func resignFirstResponder() -> Bool {
        finish()
        return super.resignFirstResponder()
      }
      override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finish() }
        super.viewWillMove(toWindow: newWindow)
      }
      func finish() {
        guard isActive else { return }
        isActive = false
        touchID = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        setActive(false)
      }
      private func point(_ touch: NSTouch) -> CGPoint {
        CGPoint(x: touch.normalizedPosition.x * size.width, y: (1 - touch.normalizedPosition.y) * size.height)
      }
      override func touchesBegan(with event: NSEvent) {
        guard isActive, touchID == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        touchID = touch.identity
        began(point(touch))
      }
      override func touchesMoved(with event: NSEvent) {
        guard isActive, let touchID else { return }
        if let touch = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(touchID) }) {
          moved(point(touch))
        }
      }
      override func touchesEnded(with event: NSEvent) {
        guard let touchID else { return }
        if event.touches(matching: [.ended, .cancelled], in: self).contains(where: { $0.identity.isEqual(touchID) }) {
          self.touchID = nil
          ended()
        }
      }
      override func touchesCancelled(with event: NSEvent) { touchesEnded(with: event) }
    }
  }
#endif
extension View {
  /// Signature ink is dark navy, as on the PDF, so on screen it always sits on white paper too.
  func signaturePaper() -> some View {
    padding(.horizontal, 12).padding(.vertical, 6)
      .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
/// Draws a signature in SwiftUI with the same code that writes it into the PDF.
struct SignatureArtView: View {
  let art: SignatureArt
  var body: some View {
    Canvas { context, size in
      context.withCGContext { cg in
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        art.draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2), context: cg)
      }
    }.allowsHitTesting(false)
  }
}
