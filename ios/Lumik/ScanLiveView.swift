#if os(macOS)
import SwiftUI

/// Paces pipeline frames so each correction stays visible for a moment. The pipeline
/// never waits on this, so animation does not slow down scanning.
@MainActor @Observable
final class ScanLiveFeed {
  private(set) var frame: ScanLiveFrame?
  private(set) var isPresenting = false
  private var queue: [ScanLiveFrame] = []
  private var presenter: Task<Void, Never>?
  private let maxQueuedFrames = 12

  func enqueue(_ frame: ScanLiveFrame) {
    queue.append(frame)
    // Previews are several MB each. Every frame is a full snapshot, so old ones can go.
    if queue.count > maxQueuedFrames { queue.removeFirst(queue.count - maxQueuedFrames) }
    guard presenter == nil else { return }
    isPresenting = true
    presenter = Task { [weak self] in await self?.present() }
  }

  func reset() {
    presenter?.cancel()
    presenter = nil
    queue = []
    frame = nil
    isPresenting = false
  }

  private func present() async {
    while !queue.isEmpty {
      let next = queue.removeFirst()
      frame = next
      // Catch up when the feeder is faster than the animation.
      let pace = queue.count > 6 ? 0.3 : 1
      try? await Task.sleep(for: .seconds(next.dwell * pace))
      if Task.isCancelled { return }
    }
    presenter = nil
    isPresenting = false
  }
}

private extension ScanLiveFrame {
  var dwell: Double {
    switch (stage, reveal) {
    case (.raw, _): 1.0
    case (.done, _): 0.9
    case (_, .none): quad == nil ? 0.45 : 0.9
    default: 0.75
    }
  }
}

/// Live correction preview on the left and the untouched scan on the right.
struct ScanLiveView: View {
  let feed: ScanLiveFeed
  let awaitingPage: Bool
  let pageCount: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var frame: ScanLiveFrame? { feed.frame }
  /// The feeder is working on a page that hasn't reached the app yet.
  private var rawWaiting: Bool { awaitingPage && (frame == nil || frame?.stage == .done) }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 14) {
        panel("Live Preview", detail: frame.map { "Page \($0.page)" }) {
          if let frame {
            ScanPreviewPage(frame: frame, reduceMotion: reduceMotion)
              .id(frame.page)
              .transition(.asymmetric(
                insertion: .opacity,
                removal: .scale(scale: 0.8).combined(with: .opacity).combined(with: .offset(x: -40))))
          } else {
            placeholder("The corrected page appears here")
          }
        }
        .animation(.smooth(duration: 0.4), value: frame?.page)
        panel("Raw Scan", detail: rawWaiting ? "Feeding" : "Unprocessed") {
          if rawWaiting {
            ScanFeedingPage(reduceMotion: reduceMotion)
          } else if let frame {
            ScanRawPage(image: frame.raw, reduceMotion: reduceMotion).id(frame.page)
          } else {
            placeholder("Preparing the scanner")
          }
        }
      }
      ScanStageTimeline(frame: frame, pageCount: pageCount)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    // Clears the status overlay that floats above this view.
    .padding(.top, 92)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func panel<Content: View>(_ title: String, detail: String?,
    @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .contentTransition(.numericText())
        }
      }
      content()
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Pages

/// The corrected page. Each kind of correction gets a motion that shows what changed.
private struct ScanPreviewPage: View {
  let frame: ScanLiveFrame
  let reduceMotion: Bool
  @State private var image: CGImage
  @State private var previous: CGImage?
  @State private var wipe: CGFloat = 1
  // The animated value reads as final immediately, so track the sweep separately.
  @State private var wiping = false
  @State private var angle = 0.0

  init(frame: ScanLiveFrame, reduceMotion: Bool) {
    self.frame = frame
    self.reduceMotion = reduceMotion
    _image = State(initialValue: frame.preview)
  }

  var body: some View {
    ZStack {
      if let previous {
        pageImage(previous)
      }
      pageImage(image)
        .id(ObjectIdentifier(image))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .mask {
          GeometryReader { proxy in
            Rectangle().frame(height: proxy.size.height * wipe)
          }
        }
    }
    .overlay {
      GeometryReader { proxy in
        if wiping {
          ScanBeam().frame(height: 26).offset(y: proxy.size.height * wipe - 26)
        }
      }
    }
    .overlay {
      if let quad = frame.quad {
        ScanQuadOverlay(quad: quad, reduceMotion: reduceMotion).id(frame.id)
      }
    }
    .overlay {
      if frame.analyzing && !reduceMotion {
        ScanSweepingBeam()
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if frame.stage == .done {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 34))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .green)
          .shadow(radius: 4)
          .padding(10)
          .transition(.scale(scale: 0.3).combined(with: .opacity))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .rotationEffect(.degrees(angle))
    .shadow(color: .black.opacity(frame.stage == .done ? 0.35 : 0.2), radius: frame.stage == .done ? 12 : 6, y: 2)
    .animation(.spring(duration: 0.4, bounce: 0.35), value: frame.stage == .done)
    .animation(.easeInOut(duration: 0.25), value: frame.analyzing)
    .onChange(of: frame.id) { update(to: frame) }
  }

  private func pageImage(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1).resizable().scaledToFit()
  }

  private func update(to frame: ScanLiveFrame) {
    guard frame.preview !== image else { return }
    switch reduceMotion ? .crossfade : frame.reveal {
    case .wipe:
      previous = image
      image = frame.preview
      wipe = 0
      wiping = true
      withAnimation(.easeInOut(duration: 0.65)) { wipe = 1 } completion: {
        previous = nil
        wiping = false
      }
    case .rotate(let degrees):
      image = frame.preview
      angle = -degrees
      withAnimation(.spring(duration: 0.6, bounce: 0.2)) { angle = 0 }
    case .crossfade, .none:
      withAnimation(.smooth(duration: 0.4)) { image = frame.preview }
    }
  }
}

/// The untouched page, unveiled by a passing scan head.
private struct ScanRawPage: View {
  let image: CGImage
  let reduceMotion: Bool
  @State private var reveal: CGFloat = 0
  @State private var revealing = false

  var body: some View {
    Image(decorative: image, scale: 1).resizable().scaledToFit()
      .mask {
        GeometryReader { proxy in
          Rectangle().frame(height: proxy.size.height * reveal)
        }
      }
      .overlay {
        GeometryReader { proxy in
          if revealing {
            ScanBeam().frame(height: 26).offset(y: proxy.size.height * reveal - 26)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
      .onAppear {
        guard !reduceMotion else { reveal = 1; return }
        revealing = true
        withAnimation(.easeInOut(duration: 0.8)) { reveal = 1 } completion: { revealing = false }
      }
  }
}

/// A blank sheet while the next page travels through the feeder.
private struct ScanFeedingPage: View {
  let reduceMotion: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(.white.opacity(0.9))
      .aspectRatio(8.5 / 11, contentMode: .fit)
      .overlay {
        if !reduceMotion { ScanSweepingBeam() }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
      .accessibilityLabel("Waiting for the next page")
  }
}

// MARK: - Effects

/// A soft scan head: a bright leading edge with a fading trail above it.
private struct ScanBeam: View {
  var body: some View {
    VStack(spacing: 0) {
      LinearGradient(colors: [.clear, .accentColor.opacity(0.35)], startPoint: .top, endPoint: .bottom)
      Rectangle().fill(Color.accentColor).frame(height: 2)
        .shadow(color: .accentColor, radius: 4)
    }
    .allowsHitTesting(false)
  }
}

/// Repeats the scan head over the page while on-device analysis runs.
private struct ScanSweepingBeam: View {
  @State private var position: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      ScanBeam().frame(height: 26).offset(y: proxy.size.height * position - 26)
    }
    .clipped()
    .transition(.opacity)
    .onAppear {
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { position = 1 }
    }
  }
}

/// Dims everything outside the detected page and traces its outline.
private struct ScanQuadOverlay: View {
  let quad: ScanQuad
  let reduceMotion: Bool
  @State private var progress: CGFloat = 0

  var body: some View {
    ZStack {
      ScanQuadShape(quad: quad, includesBounds: true)
        .fill(.black.opacity(0.4 * progress), style: FillStyle(eoFill: true))
      ScanQuadShape(quad: quad)
        .trim(from: 0, to: progress)
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
        .shadow(color: .accentColor.opacity(0.8), radius: 5)
      GeometryReader { proxy in
        ForEach(Array(quad.corners.enumerated()), id: \.offset) { _, corner in
          Circle().fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .scaleEffect(progress)
            .position(corner.flipped(in: proxy.size))
        }
      }
    }
    .allowsHitTesting(false)
    .onAppear {
      guard !reduceMotion else { progress = 1; return }
      withAnimation(.easeInOut(duration: 0.55)) { progress = 1 }
    }
  }
}

private struct ScanQuadShape: Shape {
  let quad: ScanQuad
  var includesBounds = false

  func path(in rect: CGRect) -> Path {
    var path = Path()
    if includesBounds { path.addRect(rect) }
    path.addLines(quad.corners.map { $0.flipped(in: rect.size) })
    path.closeSubpath()
    return path
  }
}

private extension ScanQuad {
  var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
}

private extension CGPoint {
  /// Vision's normalized lower-left point to a SwiftUI position.
  func flipped(in size: CGSize) -> CGPoint {
    CGPoint(x: x * size.width, y: (1 - y) * size.height)
  }
}

// MARK: - Timeline

private struct ScanStageTimeline: View {
  let frame: ScanLiveFrame?
  let pageCount: Int

  private static let steps: [(stage: ScanCorrectionStage, title: String, icon: String)] = [
    (.raw, "Raw scan", "scanner"),
    (.edges, "Edges", "crop"),
    (.rotation, "Rotation", "rotate.right"),
    (.whiteBalance, "White balance", "circle.lefthalf.filled"),
    (.finishing, "Finish", "doc.badge.gearshape"),
  ]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Self.steps, id: \.stage) { step in
        stepView(step)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    .animation(.smooth(duration: 0.3), value: frame?.stage)
  }

  private func stepView(_ step: (stage: ScanCorrectionStage, title: String, icon: String)) -> some View {
    let state = state(of: step.stage)
    return VStack(spacing: 5) {
      Image(systemName: state == .complete ? "checkmark.circle.fill" : state == .skipped ? "minus.circle" : step.icon)
        .font(.title3)
        .frame(height: 24)
        .foregroundStyle(state == .complete ? AnyShapeStyle(.green)
          : state == .active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .symbolEffect(.pulse, isActive: state == .active && frame?.analyzing == true)
        .contentTransition(.symbolEffect(.replace))
      Text(step.title)
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(state == .active ? .primary : .secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(state.label)
  }

  private enum StepState {
    case pending, active, complete, skipped
    var label: String {
      switch self {
      case .pending: "Pending"
      case .active: "In progress"
      case .complete: "Complete"
      case .skipped: "Off"
      }
    }
  }

  private func state(of stage: ScanCorrectionStage) -> StepState {
    guard let frame else { return .pending }
    if frame.skipped.contains(stage) { return .skipped }
    if stage.rawValue < frame.stage.rawValue { return .complete }
    return stage == frame.stage ? .active : .pending
  }
}

#Preview("Scan Live View") {
  ScanLivePreviewHost().frame(width: 720, height: 600)
}

/// Plays the live view with a synthetic page, so it can be checked without a scanner.
private struct ScanLivePreviewHost: View {
  @State private var feed = ScanLiveFeed()

  var body: some View {
    ScanLiveView(feed: feed, awaitingPage: true, pageCount: 2)
      .task { for frame in Self.frames { feed.enqueue(frame) } }
  }

  private static var frames: [ScanLiveFrame] {
    let context = CIContext()
    func page(_ tint: CIColor) -> CGImage {
      let extent = CGRect(x: 0, y: 0, width: 510, height: 660)
      return context.createCGImage(CIImage(color: tint).cropped(to: extent), from: extent)!
    }
    let raw = page(CIColor(red: 0.86, green: 0.78, blue: 0.6))
    let balanced = page(CIColor(red: 0.97, green: 0.97, blue: 0.97))
    let quad = ScanQuad(topLeft: CGPoint(x: 0.08, y: 0.94), topRight: CGPoint(x: 0.95, y: 0.97),
      bottomLeft: CGPoint(x: 0.05, y: 0.05), bottomRight: CGPoint(x: 0.92, y: 0.03))
    return [
      ScanLiveFrame(page: 3, stage: .raw, message: "Raw scan received", raw: raw, preview: raw),
      ScanLiveFrame(page: 3, stage: .edges, message: "Detecting page edges…", raw: raw, preview: raw, analyzing: true),
      ScanLiveFrame(page: 3, stage: .edges, message: "Page edges found", raw: raw, preview: raw, quad: quad),
      ScanLiveFrame(page: 3, stage: .whiteBalance, message: "Paper color corrected", raw: raw, preview: balanced, reveal: .wipe),
      ScanLiveFrame(page: 3, stage: .done, message: "Page 3 corrected", raw: raw, preview: balanced),
    ]
  }
}
#endif
