#if os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO

/// The steps a scanned page moves through, in display order.
enum ScanCorrectionStage: Int, CaseIterable, Sendable {
  case raw, edges, rotation, whiteBalance, finishing, done
}

/// Four corners of the detected page, normalized with a lower-left origin like Vision.
struct ScanQuad: Sendable, Equatable {
  let topLeft, topRight, bottomLeft, bottomRight: CGPoint
}

/// How the live preview moves from the previous image to this frame's image.
enum ScanPreviewReveal: Sendable, Equatable {
  case none, crossfade, wipe
  case rotate(degrees: Double)
}

/// One complete snapshot of a page in progress, so frames can be dropped under load.
struct ScanLiveFrame: Identifiable, Sendable {
  let id = UUID()
  let page: Int
  let stage: ScanCorrectionStage
  let message: String
  let raw: CGImage
  let preview: CGImage
  var quad: ScanQuad? = nil
  var reveal: ScanPreviewReveal = .none
  /// True while on-device analysis runs without a new image to show yet.
  var analyzing = false
  var skipped: Set<ScanCorrectionStage> = []
}

/// Runs off the main actor. All analysis stays on the device.
enum ScanImageProcessor {
  private static let context = CIContext()
  private static let previewDimension: CGFloat = 1000

  static func process(url: URL, page: Int = 1, whiteBalance: Bool, geometry: Bool,
    progress: @Sendable (ScanLiveFrame) -> Void = { _ in }) -> Data? {
    autoreleasepool {
      guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
      let raw = render(image)
      var shown = raw
      var skipped = Set<ScanCorrectionStage>()
      if !geometry { skipped.formUnion([.edges, .rotation]) }
      if !whiteBalance { skipped.insert(.whiteBalance) }
      func emit(_ stage: ScanCorrectionStage, _ message: String, quad: ScanQuad? = nil,
        reveal: ScanPreviewReveal = .none, analyzing: Bool = false) {
        guard let raw, let shown else { return }
        progress(ScanLiveFrame(page: page, stage: stage, message: message, raw: raw, preview: shown,
          quad: quad, reveal: reveal, analyzing: analyzing, skipped: skipped))
      }
      emit(.raw, "Raw scan received")
      if geometry {
        emit(.edges, "Detecting page edges…", analyzing: true)
        let request = VNDetectDocumentSegmentationRequest()
        if (try? VNImageRequestHandler(ciImage: analysisImage(image)).perform([request])) != nil,
          let page = request.results?.first, page.confidence >= 0.8,
          page.boundingBox.width * page.boundingBox.height >= 0.5 {
          emit(.edges, "Page edges found", quad: ScanQuad(topLeft: page.topLeft, topRight: page.topRight,
            bottomLeft: page.bottomLeft, bottomRight: page.bottomRight))
          let extent = image.extent
          func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
          }
          let correction = CIFilter.perspectiveCorrection()
          correction.inputImage = image
          correction.topLeft = point(page.topLeft)
          correction.topRight = point(page.topRight)
          correction.bottomLeft = point(page.bottomLeft)
          correction.bottomRight = point(page.bottomRight)
          if let corrected = correction.outputImage {
            image = corrected
            shown = render(image) ?? shown
            emit(.edges, "Edges straightened", reveal: .crossfade)
          }
        }
        emit(.rotation, "Checking page rotation…", analyzing: true)
        let turned = upright(image, context: context)
        if turned.degrees != 0 {
          image = turned.image
          shown = render(image) ?? shown
          emit(.rotation, "Page turned upright", reveal: .rotate(degrees: turned.degrees))
        }
      }
      if whiteBalance {
        emit(.whiteBalance, "Balancing paper color…", analyzing: true)
        let balanced = balancePaper(image, context: context)
        if balanced !== image {
          image = balanced
          shown = render(image) ?? shown
          emit(.whiteBalance, "Paper color corrected", reveal: .wipe)
        }
      }
      emit(.finishing, "Rendering corrected page…", analyzing: true)
      let data = context.tiffRepresentation(of: image, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
      if data != nil { emit(.done, "Page \(page) corrected") }
      return data
    }
  }

  /// A small display copy so previews stay cheap at any scan resolution.
  private static func render(_ image: CIImage) -> CGImage? {
    let scale = min(1, previewDimension / max(image.extent.width, image.extent.height))
    let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
    return context.createCGImage(scaled, from: scaled.extent)
  }

  private static func analysisImage(_ image: CIImage) -> CIImage {
    let scale = min(1, 1400 / max(image.extent.width, image.extent.height))
    return image.transformed(by: .init(scaleX: scale, y: scale))
  }

  private static func upright(_ image: CIImage, context: CIContext) -> (image: CIImage, degrees: Double) {
    let scale = min(1, 1400 / max(image.extent.width, image.extent.height))
    guard let preview = context.createCGImage(image.transformed(by: .init(scaleX: scale, y: scale)),
      from: image.extent.applying(.init(scaleX: scale, y: scale))) else { return (image, 0) }
    let orientations: [(value: CGImagePropertyOrientation, degrees: Double)] =
      [(.up, 0), (.right, 90), (.down, 180), (.left, -90)]
    var scores: [Float] = []
    for orientation in orientations {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .fast
      request.usesLanguageCorrection = false
      request.automaticallyDetectsLanguage = true
      guard (try? VNImageRequestHandler(cgImage: preview, orientation: orientation.value).perform([request])) != nil else {
        scores.append(0); continue
      }
      let score = (request.results ?? []).reduce(Float(0)) { total, observation in
        guard let text = observation.topCandidates(1).first, text.confidence >= 0.6 else { return total }
        return total + text.confidence * Float(min(text.string.count, 80))
      }
      scores.append(score)
    }
    let ranked = scores.indices.sorted { scores[$0] > scores[$1] }
    guard let best = ranked.first, best != 0, scores[best] >= 20,
      scores[best] > scores[ranked[1]] * 1.2 else { return (image, 0) }
    return (image.oriented(orientations[best].value), orientations[best].degrees)
  }

  /// Estimate neutral paper from bright, low-chroma pixels, excluding dark borders and ink.
  /// Bounded gains avoid aggressively bleaching colored paper or photographs.
  private static func balancePaper(_ image: CIImage, context: CIContext) -> CIImage {
    let size = 128
    let sample = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
      .transformed(by: .init(scaleX: CGFloat(size) / image.extent.width, y: CGFloat(size) / image.extent.height))
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    context.render(sample, toBitmap: &pixels, rowBytes: size * 4,
      bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var samples: [[Double]] = []
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let rgb = (0..<3).map { Double(pixels[index + $0]) / 255 }
      if rgb.min()! > 0.65 && rgb.max()! - rgb.min()! < 0.15 { samples.append(rgb) }
    }
    guard samples.count > size * size / 10 else { return image }
    let neutral = (0..<3).map { channel in
      let values = samples.map { $0[channel] }.sorted()
      return values[values.count * 3 / 4]
    }
    // Core Image applies the matrix in its linear working color space.
    func linear(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    let gains = neutral.map { min(1.65, linear(0.98) / linear($0)) }
    let filter = CIFilter.colorMatrix()
    filter.inputImage = image
    filter.rVector = CIVector(x: gains[0], y: 0, z: 0, w: 0)
    filter.gVector = CIVector(x: 0, y: gains[1], z: 0, w: 0)
    filter.bVector = CIVector(x: 0, y: 0, z: gains[2], w: 0)
    return filter.outputImage ?? image
  }
}
#endif
