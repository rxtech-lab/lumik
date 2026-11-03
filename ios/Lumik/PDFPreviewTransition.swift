import PDFKit
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Replacing a PDFView's document discards its painted pages, and the view shows its background
/// until PDFKit paints again, which can take a few hundred milliseconds. So pictures of both
/// revisions cover the view meanwhile: the changed answers are wiped from old to new as if being
/// written in, and the view is uncovered once it has had time to paint the same thing underneath.
extension PDFView {
  private static let coverName = "form-preview-cover"
  private static let fillDuration: CFTimeInterval = 0.35
  private static let fadeDuration: CFTimeInterval = 0.2
  /// Long enough for PDFKit to repaint a heavy page. The cover matches, so waiting is invisible.
  private static let paintWait: CFTimeInterval = 0.8

  private var reducesMotion: Bool {
    #if os(macOS)
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
      UIAccessibility.isReduceMotionEnabled
    #endif
  }
  private var hostLayer: CALayer? {
    #if os(macOS)
      wantsLayer = true
    #endif
    return layer
  }
  private var usesFlippedCoordinates: Bool {
    #if os(macOS)
      isFlipped
    #else
      true
    #endif
  }
  private var pixelsPerPoint: CGFloat {
    #if os(macOS)
      window?.backingScaleFactor ?? 2
    #else
      window?.screen.scale ?? contentScaleFactor
    #endif
  }
  private var resolvedBackground: CGColor {
    #if os(macOS)
      var color = NSColor.windowBackgroundColor.cgColor
      effectiveAppearance.performAsCurrentDrawingAppearance { color = backgroundColor.cgColor }
      return color
    #else
      return backgroundColor.resolvedColor(with: traitCollection).cgColor
    #endif
  }

  /// Draws the visible pages directly, because a PDFView's own pages can't be captured on macOS.
  private func pagesImage() -> CGImage? {
    let scale = pixelsPerPoint
    guard bounds.width > 0, bounds.height > 0,
      let context = CGContext(
        data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(resolvedBackground)
    context.fill(CGRect(origin: .zero, size: bounds.size))
    // visiblePages stays empty until the next layout pass after a document changes.
    for index in 0..<(document?.pageCount ?? 0) {
      guard let page = document?.page(at: index) else { continue }
      var frame = convert(page.bounds(for: .cropBox), from: page)
      if usesFlippedCoordinates { frame.origin.y = bounds.height - frame.maxY }
      let size = FormRenderer.displaySize(of: page)
      guard frame.intersects(CGRect(origin: .zero, size: bounds.size)), size.width > 0, size.height > 0 else { continue }
      context.saveGState()
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(frame)
      context.translateBy(x: frame.minX, y: frame.minY)
      context.scaleBy(x: frame.width / size.width, y: frame.height / size.height)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    return context.makeImage()
  }

  /// Swaps in a new revision of the same PDF, staying on the same page, without blinking.
  func transition(to data: Data, filling boxes: [FormPlacement]) {
    let before = pagesImage()
    replaceDocument(with: data)
    guard let host = hostLayer, let before, let after = pagesImage() else { return }
    host.sublayers?.filter { $0.name == Self.coverName }.forEach { $0.removeFromSuperlayer() }

    let newRevision = cover(showing: after, at: 10)
    let oldRevision = cover(showing: before, at: 11)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    host.addSublayer(newRevision)
    host.addSublayer(oldRevision)
    CATransaction.commit()

    let now = CACurrentMediaTime()
    let holes = reducesMotion ? [] : boxes.compactMap(viewRect(of:)).filter { $0.intersects(bounds) }
    if holes.isEmpty {
      fadeOut(oldRevision, at: now)
    } else {
      // Anything else that changed, such as a page shifting, crossfades after the writing.
      fill(holes, through: oldRevision, at: now)
      highlight(holes)
      fadeOut(oldRevision, at: now + Self.fillDuration)
    }
    fadeOut(newRevision, at: now + Self.paintWait)
  }

  private func cover(showing image: CGImage, at depth: CGFloat) -> CALayer {
    let cover = CALayer()
    cover.name = Self.coverName
    cover.frame = bounds
    cover.contents = image
    cover.contentsGravity = .resize
    cover.zPosition = depth
    return cover
  }

  private func replaceDocument(with data: Data) {
    let pageIndex = currentPage.flatMap { document?.index(for: $0) }
    let destination = currentDestination
    let savedScale = scaleFactor
    let offset = scrollOffset
    document = PDFDocument(data: data)
    if pageIndex != nil { scaleFactor = savedScale }
    layoutDocumentView()
    // The same pages lay out identically, so the exact offset keeps the page perfectly still.
    if let offset {
      scrollOffset = offset
    } else if let pageIndex, let page = document?.page(at: pageIndex) {
      go(to: PDFDestination(page: page, at: destination?.point ?? .zero))
    }
  }

  private var scrollOffset: CGPoint? {
    get {
      #if os(macOS)
        documentView?.enclosingScrollView?.contentView.bounds.origin
      #else
        pageScrollView?.contentOffset
      #endif
    }
    set {
      guard let newValue else { return }
      #if os(macOS)
        guard let scrollView = documentView?.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: newValue)
        scrollView.reflectScrolledClipView(scrollView.contentView)
      #else
        pageScrollView?.setContentOffset(newValue, animated: false)
      #endif
    }
  }
  #if os(iOS)
    /// PDFView has no public scroll view, but its document view always sits inside one.
    private var pageScrollView: UIScrollView? {
      var view = documentView?.superview
      while let current = view {
        if let scrollView = current as? UIScrollView { return scrollView }
        view = current.superview
      }
      return nil
    }
  #endif

  private func viewRect(of placement: FormPlacement) -> CGRect? {
    guard let page = document?.page(at: placement.page) else { return nil }
    let displayed = FormRenderer.rect(of: placement, pageSize: FormRenderer.displaySize(of: page))
    return convert(displayed.applying(page.transform(for: .cropBox).inverted()), from: page)
  }

  /// Opens a window in the old revision over each changed box, from its leading edge across.
  private func fill(_ holes: [CGRect], through cover: CALayer, at start: CFTimeInterval) {
    func path(progress: CGFloat) -> CGPath {
      let path = CGMutablePath()
      path.addRect(cover.bounds)
      for hole in holes { path.addRect(CGRect(x: hole.minX, y: hole.minY, width: hole.width * progress, height: hole.height)) }
      return path
    }
    let mask = CAShapeLayer()
    mask.frame = cover.bounds
    mask.fillRule = .evenOdd
    mask.path = path(progress: 1)
    let wipe = CABasicAnimation(keyPath: "path")
    wipe.fromValue = path(progress: 0)
    wipe.toValue = path(progress: 1)
    wipe.beginTime = start
    wipe.duration = Self.fillDuration
    wipe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    wipe.fillMode = .backwards
    mask.add(wipe, forKey: "fill")
    cover.mask = mask
  }

  private func fadeOut(_ cover: CALayer, at start: CFTimeInterval) {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = start
    fade.duration = Self.fadeDuration
    fade.fillMode = .backwards
    cover.opacity = 0
    cover.add(fade, forKey: "reveal")
    let remaining = start + Self.fadeDuration - CACurrentMediaTime() + 0.05
    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak cover] in cover?.removeFromSuperlayer() }
  }

  /// A brief tint over what was just written.
  private func highlight(_ holes: [CGRect]) {
    guard let host = hostLayer else { return }
    let duration = Self.fillDuration + 0.5
    for hole in holes {
      let tint = CALayer()
      tint.name = Self.coverName
      tint.frame = hole
      tint.backgroundColor = CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 0.25)
      tint.cornerRadius = 3
      tint.zPosition = 12
      tint.opacity = 0
      host.addSublayer(tint)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      fade.duration = duration
      tint.add(fade, forKey: "filled")
      DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak tint] in tint?.removeFromSuperlayer() }
    }
  }
}
