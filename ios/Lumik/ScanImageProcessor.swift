#if os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO

/// Runs off the main actor. All analysis stays on the device.
enum ScanImageProcessor {
  static func process(url: URL, whiteBalance: Bool, geometry: Bool) -> Data? {
    autoreleasepool {
      guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
      let context = CIContext()
      if geometry {
        let request = VNDetectDocumentSegmentationRequest()
        if (try? VNImageRequestHandler(ciImage: image).perform([request])) != nil,
          let page = request.results?.first, page.confidence >= 0.8,
          page.boundingBox.width * page.boundingBox.height >= 0.5 {
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
          if let corrected = correction.outputImage { image = corrected }
        }
        image = upright(image, context: context)
      }
      if whiteBalance { image = balancePaper(image, context: context) }
      return context.tiffRepresentation(of: image, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
  }

  private static func upright(_ image: CIImage, context: CIContext) -> CIImage {
    let scale = min(1, 1400 / max(image.extent.width, image.extent.height))
    guard let preview = context.createCGImage(image.transformed(by: .init(scaleX: scale, y: scale)),
      from: image.extent.applying(.init(scaleX: scale, y: scale))) else { return image }
    let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    var scores: [Float] = []
    for orientation in orientations {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.automaticallyDetectsLanguage = true
      guard (try? VNImageRequestHandler(cgImage: preview, orientation: orientation).perform([request])) != nil else {
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
      scores[best] > scores[ranked[1]] * 1.2 else { return image }
    return image.oriented(orientations[best])
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
