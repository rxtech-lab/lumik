import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// What is actually printed on a page: ruled lines, tick boxes, and glyphs, in display points with
/// y running up. AI field boxes are only estimates, so ink is aligned to this before it is drawn.
final class FormPageGeometry {
  private struct Glyph {
    let rect: CGRect
    let character: Character
  }
  private let horizontal: [CGRect]
  private let vertical: [CGRect]
  private let underlines: [CGRect]
  private let tickBoxes: [CGRect]
  private let glyphs: [Glyph]
  private let dateOrder: [FormDatePart]?

  /// One entry per page of each PDF, because previews redraw on every edit.
  nonisolated(unsafe) private static let cache = NSCache<NSString, FormPageGeometry>()

  static func of(page: PDFPage, index: Int, documentKey: String) -> FormPageGeometry {
    let key = "\(documentKey)-\(index)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let geometry = FormPageGeometry(page: page)
    cache.setObject(geometry, forKey: key)
    return geometry
  }
  /// The day, month, and year order a page prints, as in "dd/mm/yyyy". Reads only its text.
  static func printedDateOrder(on page: PDFPage) -> [FormDatePart]? {
    dateOrder(in: page.string ?? "")
  }
  static func documentKey(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private init(page: PDFPage) {
    let glyphs = Self.glyphs(on: page)
    let raster = Raster(page: page)
    let horizontal = raster?.lines(horizontal: true) ?? []
    let vertical = raster?.lines(horizontal: false) ?? []
    // A cell border meets a vertical rule. A blank's underline stands alone in its cell.
    let (ruled, loose) = horizontal.reduce(into: ([CGRect](), [CGRect]())) { result, line in
      let meetsRule = vertical.contains { rule in
        rule.minY - 3 <= line.midY && line.midY <= rule.maxY + 3
          && (abs(rule.midX - line.minX) <= 3 || abs(rule.midX - line.maxX) <= 3)
      }
      if meetsRule { result.0.append(line) } else { result.1.append(line) }
    }
    self.horizontal = ruled
    self.vertical = vertical
    // A line right under printed words is emphasis, not a place to write.
    self.underlines = loose.filter { line in
      let band = CGRect(x: line.minX, y: line.maxY, width: line.width, height: 6)
      let printed = glyphs.filter { $0.rect.intersects(band) }.map { $0.rect.intersection(band).width }
      return printed.reduce(0, +) < line.width * 0.3
    }
    self.tickBoxes = (raster?.squares() ?? []).filter { square in
      !glyphs.contains {
        $0.rect.intersects(square.insetBy(dx: 1, dy: 1)) && !Self.isBoxCharacter($0.character)
          && !Self.fills($0.rect, square)
      }
    }
    self.glyphs = glyphs
    self.dateOrder = Self.dateOrder(in: page.string ?? "")
  }

  // MARK: Tick boxes

  /// Matches a field's options to the printed squares, keeping their reading order. Nearest-square
  /// alone is not enough: an estimate can land closer to the neighboring option's square.
  func tickBoxes(for boxes: [CGRect]) -> [CGRect] {
    let centers = boxes.map { CGPoint(x: $0.midX, y: $0.midY) }
    let candidates = Self.readingOrder(
      tickBoxes.filter { square in
        centers.contains { abs($0.x - square.midX) <= 45 && abs($0.y - square.midY) <= 22 }
      })
    let order = boxes.indices.sorted { Self.reads(boxes[$0], before: boxes[$1]) }
    guard !boxes.isEmpty, candidates.count >= boxes.count else { return boxes }
    func cost(_ option: Int, _ candidate: Int) -> CGFloat {
      let center = centers[order[option]]
      return hypot(center.x - candidates[candidate].midX, center.y - candidates[candidate].midY)
    }
    // best[i][j]: the least total distance placing the first i options among the first j squares.
    var best = Array(
      repeating: Array(repeating: CGFloat.infinity, count: candidates.count + 1), count: boxes.count + 1)
    best[0] = Array(repeating: 0, count: candidates.count + 1)
    for option in 1...boxes.count {
      for candidate in stride(from: option, through: candidates.count, by: 1) {
        best[option][candidate] = min(
          best[option][candidate - 1],
          best[option - 1][candidate - 1] + cost(option - 1, candidate - 1))
      }
    }
    var result = boxes
    var candidate = candidates.count
    for option in stride(from: boxes.count, to: 0, by: -1) {
      while best[option][candidate] == best[option][candidate - 1] { candidate -= 1 }
      if cost(option - 1, candidate - 1) <= 60 { result[order[option - 1]] = candidates[candidate - 1] }
      candidate -= 1
    }
    return result
  }

  // MARK: Written values

  /// The clear space for a value: its table cell without the printed headings, or the underline it
  /// sits on. A value never moves into a neighboring cell, even when the estimate overlaps one.
  func writingArea(for box: CGRect) -> CGRect {
    if let line = blanks(near: box).first {
      return CGRect(x: line.minX, y: line.maxY, width: line.width, height: Self.lineHeight)
    }
    return clearArea(in: region(for: box), near: box) ?? box
  }

  /// A date printed as separate day, month, and year blanks gets one area for each part.
  func dateBlanks(for box: CGRect) -> [(part: FormDatePart, area: CGRect)]? {
    guard let dateOrder else { return nil }
    let lines = blanks(near: box)
    guard lines.count == dateOrder.count, let first = lines.first,
      lines.allSatisfy({ abs($0.midY - first.midY) <= 2 })
    else { return nil }
    return zip(dateOrder, lines).map {
      ($0, CGRect(x: $1.minX, y: $1.maxY, width: $1.width, height: Self.lineHeight))
    }
  }

  private static let lineHeight: CGFloat = 14

  private func region(for box: CGRect) -> CGRect {
    guard let cell = cell(containing: CGPoint(x: box.midX, y: box.midY)) else { return box }
    let inner = cell.insetBy(dx: 2, dy: 1.5)
    // A big ruled area can hold several answers, so stay inside this one's estimate there.
    if inner.width * inner.height > box.width * box.height * 4 {
      let clipped = inner.intersection(box)
      return clipped.isNull ? box : clipped
    }
    return inner
  }

  private func cell(containing point: CGPoint) -> CGRect? {
    let crossingRow = vertical.filter { $0.minY - 1 <= point.y && point.y <= $0.maxY + 1 }
    let crossingColumn = horizontal.filter { $0.minX - 1 <= point.x && point.x <= $0.maxX + 1 }
    guard let left = crossingRow.filter({ $0.midX <= point.x }).map(\.maxX).max(),
      let right = crossingRow.filter({ $0.midX > point.x }).map(\.minX).min(),
      let bottom = crossingColumn.filter({ $0.midY <= point.y }).map(\.maxY).max(),
      let top = crossingColumn.filter({ $0.midY > point.y }).map(\.minY).min()
    else { return nil }
    return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
  }

  /// Underlines this value could sit on: those in its own cell, or just around its estimate.
  private func blanks(near box: CGRect) -> [CGRect] {
    let area = cell(containing: CGPoint(x: box.midX, y: box.midY))?.insetBy(dx: 0, dy: -1) ?? box.insetBy(dx: 0, dy: -12)
    return underlines.filter { area.contains(CGPoint(x: $0.midX, y: $0.midY)) }.sorted { $0.minX < $1.minX }
  }

  /// Subtracts the printed words from `region` and keeps the free rectangle most like the estimate.
  private func clearArea(in region: CGRect, near box: CGRect) -> CGRect? {
    let printed = Self.words(glyphs.filter { glyph in
      let overlap = glyph.rect.intersection(region)
      return !overlap.isNull && overlap.width * overlap.height >= glyph.rect.width * glyph.rect.height * 0.4
    })
    let minimumWidth: CGFloat = 24, minimumHeight: CGFloat = 9
    func overlap(_ rect: CGRect) -> CGFloat {
      let shared = rect.intersection(box)
      return shared.isNull ? 0 : shared.width * shared.height
    }
    var free = [region]
    for word in printed {
      let word = word.insetBy(dx: -2, dy: -1)
      free = free.flatMap { rect -> [CGRect] in
        guard rect.intersects(word) else { return [rect] }
        return [
          CGRect(x: rect.minX, y: rect.minY, width: word.minX - rect.minX, height: rect.height),
          CGRect(x: word.maxX, y: rect.minY, width: rect.maxX - word.maxX, height: rect.height),
          CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: word.minY - rect.minY),
          CGRect(x: rect.minX, y: word.maxY, width: rect.width, height: rect.maxY - word.maxY),
        ].filter { $0.width >= minimumWidth && $0.height >= minimumHeight }
      }
      free = Array(free.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(64))
    }
    return free.max { a, b in
      let (first, second) = (overlap(a), overlap(b))
      return first == second ? a.width * a.height < b.width * b.height : first < second
    }
  }

  // MARK: Reading the page

  private static func glyphs(on page: PDFPage) -> [Glyph] {
    let transform = page.transform(for: .cropBox)
    // Character indexes don't line up with page.string, so each is read by its own index.
    return (0..<page.numberOfCharacters).compactMap { index in
      guard let text = page.selection(for: NSRange(location: index, length: 1))?.string,
        let character = text.first(where: { !$0.isWhitespace && !$0.isNewline })
      else { return nil }
      let rect = page.characterBounds(at: index).applying(transform)
      return rect.isEmpty ? nil : Glyph(rect: rect, character: character)
    }
  }
  /// Joins neighboring glyphs, so the gaps between letters aren't mistaken for writing space.
  private static func words(_ glyphs: [Glyph]) -> [CGRect] {
    var words: [CGRect] = []
    for glyph in glyphs.sorted(by: { $0.rect.minX < $1.rect.minX }) {
      if let index = words.lastIndex(where: {
        $0.minY < glyph.rect.maxY && glyph.rect.minY < $0.maxY && glyph.rect.minX - $0.maxX <= 8
      }) {
        words[index] = words[index].union(glyph.rect)
      } else {
        words.append(glyph.rect)
      }
    }
    return words
  }
  /// A symbol font's box can read as any letter, but its bounds are the square itself. The ink of
  /// a real character, such as 口, is noticeably smaller than its glyph's bounds.
  private static func fills(_ glyph: CGRect, _ square: CGRect) -> Bool {
    abs(glyph.width - square.width) <= square.width * 0.15
      && abs(glyph.height - square.height) <= square.height * 0.15
      && abs(glyph.midX - square.midX) <= square.width * 0.15
      && abs(glyph.midY - square.midY) <= square.height * 0.15
  }
  private static func isBoxCharacter(_ character: Character) -> Bool {
    if "□☐☑☒◻▢▫◽❏❐❑❒".contains(character) { return true }
    return character.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }
  }
  private static func dateOrder(in text: String) -> [FormDatePart]? {
    let lowered = text.lowercased()
    for marks in [["dd", "mm", "yy"], ["日", "月", "年"]] {
      let ranges = zip([FormDatePart.day, .month, .year], marks).compactMap { part, mark in
        lowered.range(of: "\(mark)", options: []).map { (part, $0.lowerBound) }
      }
      // Marks that far apart are ordinary words rather than a single date format.
      if ranges.count == 3, let first = ranges.map(\.1).min(), let last = ranges.map(\.1).max(),
        lowered.distance(from: first, to: last) <= 12
      {
        return ranges.sorted { $0.1 < $1.1 }.map(\.0)
      }
    }
    return nil
  }
  private static func reads(_ a: CGRect, before b: CGRect) -> Bool {
    abs(a.midY - b.midY) > 4 ? a.midY > b.midY : a.midX < b.midX
  }
  private static func readingOrder(_ boxes: [CGRect]) -> [CGRect] {
    boxes.sorted { reads($0, before: $1) }
  }
}

/// The page drawn to grayscale, which finds lines and boxes however the PDF happens to encode them.
/// Reads pixels through raw pointers: this runs over millions of them whenever a form first opens,
/// and checked array access would take seconds in an unoptimized build.
private struct Raster {
  let width: Int
  let height: Int
  let scale: CGFloat
  private let pixels: [UInt8]
  /// Hairline rules render as pale gray, so the cutoff stays well above the page's mid-tones.
  private static let inkCutoff: UInt8 = 225

  init?(page: PDFPage) {
    let size = FormRenderer.displaySize(of: page)
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(Raster.pixelsPerPoint, 4800 / max(size.width, size.height))
    let width = Int(size.width * scale), height = Int(size.height * scale)
    var pixels = [UInt8](repeating: 255, count: width * height)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.scaleBy(x: scale, y: scale)
      page.draw(with: .cropBox, to: context)
      return true
    }
    guard drawn else { return nil }
    self.width = width
    self.height = height
    self.scale = scale
    self.pixels = pixels
  }
  private static let pixelsPerPoint: CGFloat = 3

  /// Long, thin runs of ink, as display rectangles.
  func lines(horizontal: Bool) -> [CGRect] {
    let minimumLength = Int((horizontal ? 16 : 14) * scale)
    let maximumThickness = Int(3 * scale)
    let cutoff = Self.inkCutoff
    let outerCount = horizontal ? height : width
    let innerCount = horizontal ? width : height
    let step = horizontal ? 1 : width
    let rowStep = horizontal ? width : 1
    struct Line {
      var start: Int, end: Int, first: Int, last: Int
    }
    var open: [Line] = []
    var closed: [Line] = []
    pixels.withUnsafeBufferPointer { buffer in
      let ink = buffer.baseAddress!
      for outer in 0..<outerCount {
        let row = ink + outer * rowStep
        var inner = 0
        while inner < innerCount {
          if row[inner * step] >= cutoff {
            inner += 1
            continue
          }
          let start = inner
          // Rules are often drawn in pieces. Bridging more than a pixel would join letters into lines.
          var end = inner + 1
          inner += 1
          while inner < innerCount {
            if row[inner * step] < cutoff {
              end = inner + 1
            } else if inner - end >= 1 {
              break
            }
            inner += 1
          }
          inner = end
          guard end - start >= minimumLength else { continue }
          // Only runs of similar length are the same line, so a rule crossing a shaded band stays a rule.
          if let index = open.firstIndex(where: {
            $0.last >= outer - 1
              && (min($0.end, end) - max($0.start, start)) * 5 >= max($0.end - $0.start, end - start) * 4
          }) {
            open[index].start = min(open[index].start, start)
            open[index].end = max(open[index].end, end)
            open[index].last = outer
          } else {
            open.append(Line(start: start, end: end, first: outer, last: outer))
          }
        }
        if !open.isEmpty {
          closed += open.filter { $0.last < outer - 1 }
          open.removeAll { $0.last < outer - 1 }
        }
      }
    }
    return (closed + open).filter { $0.last - $0.first < maximumThickness }.map { line in
      horizontal
        ? rect(minX: line.start, maxX: line.end, minRow: line.first, maxRow: line.last + 1)
        : rect(minX: line.first, maxX: line.last + 1, minRow: line.start, maxRow: line.end)
    }
  }

  /// Small hollow squares: separate shapes with ink along all four sides and an empty middle.
  func squares() -> [CGRect] {
    let minimumSide = Int(5 * scale), maximumSide = Int(22 * scale)
    let (width, height, cutoff) = (width, height, Self.inkCutoff)
    var found: [CGRect] = []
    pixels.withUnsafeBufferPointer { buffer in
      let ink = buffer.baseAddress!
      let seen = UnsafeMutablePointer<Bool>.allocate(capacity: width * height)
      seen.initialize(repeating: false, count: width * height)
      defer { seen.deallocate() }
      var stack: [Int] = []
      for y in 0..<height {
        for x in 0..<width {
          let origin = y * width + x
          if ink[origin] >= cutoff || seen[origin] { continue }
          var (minX, maxX, minY, maxY) = (x, x, y, y)
          seen[origin] = true
          stack.append(origin)
          while let index = stack.popLast() {
            let px = index % width, py = index / width
            if px < minX { minX = px }
            if px > maxX { maxX = px }
            if py < minY { minY = py }
            if py > maxY { maxY = py }
            // A diagonal touch counts, or a thin corner would split a box into separate shapes.
            let left = px > 0, right = px < width - 1
            if py > 0 {
              let above = index - width
              if left, ink[above - 1] < cutoff, !seen[above - 1] { seen[above - 1] = true; stack.append(above - 1) }
              if ink[above] < cutoff, !seen[above] { seen[above] = true; stack.append(above) }
              if right, ink[above + 1] < cutoff, !seen[above + 1] { seen[above + 1] = true; stack.append(above + 1) }
            }
            if left, ink[index - 1] < cutoff, !seen[index - 1] { seen[index - 1] = true; stack.append(index - 1) }
            if right, ink[index + 1] < cutoff, !seen[index + 1] { seen[index + 1] = true; stack.append(index + 1) }
            if py < height - 1 {
              let below = index + width
              if left, ink[below - 1] < cutoff, !seen[below - 1] { seen[below - 1] = true; stack.append(below - 1) }
              if ink[below] < cutoff, !seen[below] { seen[below] = true; stack.append(below) }
              if right, ink[below + 1] < cutoff, !seen[below + 1] { seen[below + 1] = true; stack.append(below + 1) }
            }
          }
          let w = maxX - minX + 1, h = maxY - minY + 1
          guard w >= minimumSide, w <= maximumSide, h >= minimumSide, h <= maximumSide,
            abs(w - h) * 4 <= max(w, h), Self.isHollowSquare(ink, width, minX, minY, w, h, cutoff)
          else { continue }
          found.append(rect(minX: minX, maxX: maxX + 1, minRow: minY, maxRow: maxY + 1))
        }
      }
    }
    return found
  }

  private static func isHollowSquare(
    _ ink: UnsafePointer<UInt8>, _ stride: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ cutoff: UInt8
  ) -> Bool {
    // The empty middle rejects most letters cheaply, so check it before the four sides.
    var filled = 0
    for py in (y + h / 4)..<(y + h - h / 4) {
      for px in (x + w / 4)..<(x + w - w / 4) where ink[py * stride + px] < cutoff { filled += 1 }
    }
    guard filled * 20 <= (w - w / 4 * 2) * (h - h / 4 * 2) else { return false }
    let band = max(2, min(w, h) / 6)
    func inked(_ xs: Range<Int>, _ ys: Range<Int>) -> Bool {
      for py in ys { for px in xs where ink[py * stride + px] < cutoff { return true } }
      return false
    }
    var (top, bottom, left, right) = (0, 0, 0, 0)
    for px in x..<(x + w) {
      if inked(px..<(px + 1), y..<(y + band)) { top += 1 }
      if inked(px..<(px + 1), (y + h - band)..<(y + h)) { bottom += 1 }
    }
    for py in y..<(y + h) {
      if inked(x..<(x + band), py..<(py + 1)) { left += 1 }
      if inked((x + w - band)..<(x + w), py..<(py + 1)) { right += 1 }
    }
    return min(top, bottom) * 10 >= w * 9 && min(left, right) * 10 >= h * 9
  }

  /// Pixel rows run down from the top of the page; display points run up from the bottom.
  private func rect(minX: Int, maxX: Int, minRow: Int, maxRow: Int) -> CGRect {
    CGRect(
      x: CGFloat(minX) / scale, y: CGFloat(height - maxRow) / scale,
      width: CGFloat(maxX - minX) / scale, height: CGFloat(maxRow - minRow) / scale)
  }
}
