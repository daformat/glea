import AppKit

/// One heading in a page's table of contents.
struct TocEntry: Equatable {
  /// Depth in the heading tree (0 = top level), not the Markdown heading level.
  var depth: Int
  var title: String
}

/// Builds tree depths from heading levels, tolerating skipped levels:
/// `# > ### > #####` nests the same way as `# > ## > ###`.
func tocDepths(forHeadingLevels levels: [Int]) -> [Int] {
  var stack: [Int] = []
  return levels.map { level in
    while let last = stack.last, last >= level { stack.removeLast() }
    let depth = stack.count
    stack.append(level)
    return depth
  }
}

/// Headings of a Markdown document: (character offset of the line, level, text).
func markdownHeadings(in text: String) -> [(offset: Int, level: Int, title: String)] {
  var result: [(Int, Int, String)] = []
  var inFence = false
  let ns = text as NSString
  ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
    guard let line else { return }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
      inFence.toggle()
      return
    }
    guard !inFence, line.hasPrefix("#") else { return }
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes <= 6, line.dropFirst(hashes).first == " " else { return }
    let title = NoteStore.plainText(String(line.dropFirst(hashes))).trimmingCharacters(in: .whitespaces)
    if !title.isEmpty { result.append((range.location, hashes, title)) }
  }
  return result
}

/// A scroll-aware table of contents, after hello-mat.com's component.
///
/// Idle, it shows one dash per heading (longer for top-level ones, brighter
/// and longer for the active one). Hovering reveals the titles: dashes shrink
/// away while labels spring in from the left.
final class TableOfContentsView: NSView {
  var onSelect: ((Int) -> Void)?
  /// Horizontal room available for labels before they'd overlap the text.
  var labelRoom: CGFloat = 200 { didSet { if labelRoom != oldValue { needsLayout = true } } }
  /// How many levels down its top entries are drawn: 1 gives them a
  /// heading 2's shorter dashes.
  var dashLevel = 0
  /// Entries come in (and go) animated even from none or to none; a note's
  /// headings show at once when it opens.
  var animatesAllChanges = false

  private(set) var entries: [TocEntry] = []
  private var activeIndex: Int?
  private var hoveredIndex: Int?
  private var expanded = false
  private var rows: [(dash: CALayer, label: CATextLayer)] = []
  private var tracking: NSTrackingArea?
  /// Holds the rows; scrolled by `scrollOffset` and edge-faded when the list
  /// is taller than the view (there is never a scroll bar).
  private let content = CALayer()
  private let fade = CAGradientLayer()
  private var scrollOffset: CGFloat = 0

  private let rowHeight: CGFloat = 24
  private let dashX: CGFloat = 26
  private let indent: CGFloat = 10
  private let fontSize: CGFloat = 12

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(content)
    fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  // MARK: Content

  func setEntries(_ newEntries: [TocEntry]) {
    guard newEntries != entries else { return }
    // Keep the rows of entries that are still there (matched in order), so
    // only added and removed headings animate; everything else slides.
    let animate = window != nil && (!rows.isEmpty || animatesAllChanges) && !Motion.reduceMotion
    var used = Array(repeating: false, count: rows.count)
    var kept: [(dash: CALayer, label: CATextLayer)] = []
    var inserted: [Int] = []
    var searchFrom = 0
    for (index, entry) in newEntries.enumerated() {
      let match = (searchFrom..<entries.count).first { !used[$0] && entries[$0] == entry }
        ?? entries.indices.first { !used[$0] && entries[$0] == entry }
      if let match {
        used[match] = true
        kept.append(rows[match])
        searchFrom = match + 1
      } else {
        kept.append(makeRow(entry))
        inserted.append(index)
      }
    }
    let removed = rows.indices.filter { !used[$0] }.map { rows[$0] }
    entries = newEntries
    rows = kept
    if activeIndex.map({ $0 >= entries.count }) ?? false { activeIndex = nil }
    // One heading: nothing to navigate. (Going, its rows leave first.)
    if entries.count >= 2 || !(animate && animatesAllChanges) {
      isHidden = entries.count < 2
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self, self.entries.count < 2 else { return }
        self.isHidden = true
      }
    }

    guard animate else {
      for row in removed {
        row.dash.removeFromSuperlayer()
        row.label.removeFromSuperlayer()
      }
      Motion.withoutAnimation { layoutRows() }
      return
    }
    // New rows start where they'll be, a little to the left and transparent.
    Motion.withoutAnimation {
      for index in inserted {
        let row = rows[index]
        placeRow(row, at: index)
        row.dash.position.x -= 10
        row.label.position.x -= 10
        row.dash.opacity = 0
        row.label.opacity = 0
      }
    }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.28)
    CATransaction.setAnimationTimingFunction(Motion.easeOut)
    layoutRows()
    // Removed rows slide out to the left and fade.
    for row in removed {
      row.dash.opacity = 0
      row.label.opacity = 0
      row.dash.position.x -= 10
      row.label.position.x -= 10
    }
    CATransaction.commit()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      for row in removed {
        row.dash.removeFromSuperlayer()
        row.label.removeFromSuperlayer()
      }
    }
  }

  private func makeRow(_ entry: TocEntry) -> (dash: CALayer, label: CATextLayer) {
    let dash = CALayer()
    dash.cornerRadius = 1
    dash.anchorPoint = CGPoint(x: 0, y: 0.5)
    // Its width is the state's (applyState); placing a row only moves it.
    dash.bounds = CGRect(x: 0, y: 0, width: 26, height: 2)
    let label = CATextLayer()
    label.string = entry.title
    label.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    label.fontSize = fontSize
    label.truncationMode = .end
    label.contentsScale = window?.backingScaleFactor ?? 2
    label.anchorPoint = .zero
    content.addSublayer(dash)
    content.addSublayer(label)
    return (dash, label)
  }

  func setActiveIndex(_ index: Int?) {
    guard index != activeIndex else { return }
    activeIndex = index
    applyState(animated: true)
    if let index, hoveredIndex == nil { reveal(index) }
  }

  // MARK: Geometry

  private var listHeight: CGFloat { CGFloat(entries.count) * rowHeight }
  private let edgeMargin: CGFloat = 24
  private var overflows: Bool { listHeight + edgeMargin * 2 > bounds.height }
  private var maxScrollOffset: CGFloat { max(0, listHeight + edgeMargin * 2 - bounds.height) }
  /// Top of the list in view coordinates (scrolled when overflowing).
  private var listTop: CGFloat {
    overflows ? edgeMargin - scrollOffset : (bounds.height - listHeight) / 2
  }

  /// The hover area: the dashes when idle; when open, only as wide as the
  /// longest title, so moving off the titles closes it.
  private var listRect: NSRect {
    // When scrolling, the whole column is live so the wheel keeps working.
    if overflows {
      let width = expanded && canExpand ? (entries.indices.map { labelExtent($0) }.max() ?? dashX + 44) : dashX + 44
      return NSRect(x: 0, y: 0, width: width + 8, height: bounds.height)
    }
    let width: CGFloat
    if expanded && canExpand {
      width = entries.indices.map { labelExtent($0) }.max() ?? dashX + 44
    } else {
      width = dashX + 44
    }
    return NSRect(x: 0, y: listTop - 4, width: width + 8, height: listHeight + 8)
  }

  /// Right edge of an entry's title as displayed (truncated to its room).
  private func labelExtent(_ index: Int) -> CGFloat {
    let entry = entries[index]
    let x = dashX + CGFloat(entry.depth) * indent
    let room = max(10, labelRoom - CGFloat(entry.depth) * indent - 8)
    let text = (entry.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width
    return x + min(ceil(text), room)
  }

  private func dashWidth(_ entry: TocEntry, active: Bool) -> CGFloat {
    let width: CGFloat
    switch entry.depth + dashLevel {
    case 0: width = 26 + (active ? 4 : 0)
    case 1: width = 20 + (active ? 8 : 0)
    default: width = 14 + (active ? 10 : 0)
    }
    return max(1, width * markerScale)
  }

  /// Markers shrink with the margin (offset and length) so the widest one
  /// always stays 16pt clear of the note's text.
  private var markerScale: CGFloat {
    let columnX = labelRoom + 54
    let needed = dashX + 30 + 16
    return min(max((columnX - 16) / (needed - 16), 0), 1)
  }
  private var markerX: CGFloat { dashX * markerScale }

  override func layout() {
    super.layout()
    Motion.withoutAnimation { layoutRows() }
    updateTrackingAreas()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    for row in rows { row.label.contentsScale = window?.backingScaleFactor ?? 2 }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    Motion.withoutAnimation { applyState(animated: false) }
  }

  private var canExpand: Bool { labelRoom >= 70 }

  private func layoutRows() {
    scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
    content.frame = bounds
    if overflows {
      fade.frame = content.bounds
      let edge = NSNumber(value: Double(edgeMargin / max(bounds.height, 1)))
      fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
      content.mask = fade
    } else {
      content.mask = nil
    }
    positionRows()
    applyState(animated: false)
  }

  private func positionRows() {
    for (index, row) in rows.enumerated() { placeRow(row, at: index) }
  }

  private func placeRow(_ row: (dash: CALayer, label: CATextLayer), at index: Int) {
    let y = listTop + CGFloat(index) * rowHeight
    row.dash.position = CGPoint(x: markerX, y: y + rowHeight / 2)
    let x = dashX + CGFloat(entries[index].depth) * indent
    let width = max(10, labelRoom - CGFloat(entries[index].depth) * indent - 8)
    row.label.bounds = CGRect(x: 0, y: 0, width: width, height: fontSize * 1.3)
    row.label.position = CGPoint(x: x, y: y + (rowHeight - fontSize * 1.3) / 2)
  }

  /// Keeps `index` inside the visible part of an overflowing list.
  private func reveal(_ index: Int) {
    guard overflows else { return }
    let rowTop = edgeMargin + CGFloat(index) * rowHeight - scrollOffset
    let visibleTop = edgeMargin
    let visibleBottom = bounds.height - edgeMargin
    var offset = scrollOffset
    if rowTop < visibleTop { offset -= visibleTop - rowTop }
    if rowTop + rowHeight > visibleBottom { offset += rowTop + rowHeight - visibleBottom }
    offset = min(max(0, offset), maxScrollOffset)
    guard offset != scrollOffset else { return }
    scrollOffset = offset
    CATransaction.begin()
    CATransaction.setAnimationDuration(Motion.reduceMotion ? 0 : 0.3)
    CATransaction.setAnimationTimingFunction(Motion.easeOut)
    positionRows()
    CATransaction.commit()
  }

  /// Applies idle/expanded/active/hover visuals, springing when animated.
  private func applyState(animated: Bool) {
    let dashColor = resolvedCGColor(Theme.text)
    let labelColor = resolvedCGColor(Theme.secondaryText)
    let strongColor = resolvedCGColor(Theme.text)
    let open = expanded && canExpand

    for (index, row) in rows.enumerated() {
      let entry = entries[index]
      let isActive = index == activeIndex
      let isHovered = index == hoveredIndex

      // Dash: scaled via bounds so the rounded ends stay crisp.
      let width = dashWidth(entry, active: isActive || (isHovered && !open))
      let dashOpacity: Float = open ? 0 : (isActive || isHovered ? 1 : 0.35)
      let dashTransform = open ? CATransform3DMakeScale(0.5, 1, 1) : CATransform3DIdentity
      // Labels start two widths to the left, like translateX(-200%), and are
      // clipped by the view's left edge fade.
      let labelShift = open ? CATransform3DIdentity : CATransform3DMakeTranslation(-min(row.label.bounds.width, 120) * 1.2, 0, 0)
      let labelOpacity: Float = open ? 1 : 0

      if animated && !Motion.reduceMotion {
        spring(row.dash, "bounds.size.width", to: width, stiffness: 300, damping: 26)
        basic(row.dash, "opacity", to: dashOpacity, duration: open ? 0.1 : 0.2)
        basic(row.dash, "transform", to: dashTransform, duration: 0.3, timing: Motion.easeInOut)
        spring(row.label, "transform", to: labelShift, stiffness: 200, damping: 23)
        basic(row.label, "opacity", to: labelOpacity, duration: open ? 0.35 : 0.2, delay: open ? 0.04 : 0)
      } else {
        row.dash.bounds.size.width = width
        row.dash.opacity = dashOpacity
        row.dash.transform = dashTransform
        row.label.transform = labelShift
        row.label.opacity = labelOpacity
      }
      row.dash.backgroundColor = dashColor
      let emphasized = isHovered || (isActive && hoveredIndex == nil)
      CATransaction.begin()
      CATransaction.setAnimationDuration(animated ? 0.15 : 0)
      row.label.foregroundColor = emphasized ? strongColor : labelColor
      CATransaction.commit()
    }
  }

  private func spring(_ layer: CALayer, _ keyPath: String, to value: Any, stiffness: CGFloat, damping: CGFloat) {
    let animation = Motion.spring(keyPath, stiffness: stiffness, damping: damping)
    animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
    animation.toValue = value
    Motion.withoutAnimation { layer.setValue(value, forKeyPath: keyPath) }
    layer.add(animation, forKey: keyPath)
  }

  private func basic(_ layer: CALayer, _ keyPath: String, to value: Any, duration: CFTimeInterval,
                     timing: CAMediaTimingFunction = Motion.easeInOut, delay: CFTimeInterval = 0) {
    let animation = Motion.basic(keyPath, duration: duration, timing: timing)
    animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
    animation.toValue = value
    if delay > 0 {
      animation.beginTime = CACurrentMediaTime() + delay
      animation.fillMode = .backwards
    }
    Motion.withoutAnimation { layer.setValue(value, forKeyPath: keyPath) }
    layer.add(animation, forKey: keyPath)
  }

  // MARK: Interaction

  // MARK: Tucked away

  /// Slid out of the way (the page is too narrow for it): hidden, and not
  /// clickable.
  private(set) var isTucked = false

  /// How far right its dashes reach (the deepest entry's, fully drawn).
  var dashesExtent: CGFloat {
    let depth = entries.map(\.depth).max() ?? 0
    return dashX + CGFloat(depth) * indent + 30
  }

  /// Slides out to the left as it fades (or back in, the other way).
  func setTucked(_ tucked: Bool, animated: Bool) {
    guard tucked != isTucked else { return }
    isTucked = tucked
    guard let layer else { return }
    let away = CATransform3DMakeTranslation(-24, 0, 0)
    let current = layer.presentation()
    layer.removeAnimation(forKey: "glea.tuck.transform")
    layer.removeAnimation(forKey: "glea.tuck.opacity")
    guard animated, !Motion.reduceMotion else {
      if tucked {
        // Kept away (the transform alone would be reset by AppKit).
        let hold = CABasicAnimation(keyPath: "transform")
        hold.fromValue = away
        hold.toValue = away
        hold.duration = 1
        hold.fillMode = .forwards
        hold.isRemovedOnCompletion = false
        layer.add(hold, forKey: "glea.tuck.transform")
      }
      alphaValue = tucked ? 0 : 1
      return
    }
    let slide = Motion.basic("transform", duration: 0.32, timing: Motion.easeOut)
    slide.fromValue = current?.transform ?? (tucked ? CATransform3DIdentity : away)
    slide.toValue = tucked ? away : CATransform3DIdentity
    let fade = Motion.basic("opacity", duration: tucked ? 0.2 : 0.28, timing: Motion.easeOut)
    fade.fromValue = current?.opacity ?? (tucked ? 1 : 0)
    fade.toValue = tucked ? 0 : 1
    for animation in [slide, fade] {
      // Tucked, it stays away.
      animation.fillMode = .forwards
      animation.isRemovedOnCompletion = !tucked
    }
    layer.add(slide, forKey: "glea.tuck.transform")
    layer.add(fade, forKey: "glea.tuck.opacity")
    alphaValue = tucked ? 0 : 1
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, !isTucked, let superview else { return nil }
    let local = convert(point, from: superview)
    // A thin strip along the left edge also opens it when coming in fast.
    let edge = NSRect(x: 0, y: 0, width: 10, height: bounds.height)
    return listRect.contains(local) || (edge.contains(local) && !entries.isEmpty) ? self : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) { trackMouse(event) }
  override func mouseEntered(with event: NSEvent) { trackMouse(event) }

  override func mouseExited(with event: NSEvent) {
    setHover(expanded: false, index: nil)
  }

  private func trackMouse(_ event: NSEvent) { trackPointer(at: event.locationInWindow) }

  private func syncHoverWithPointer() {
    guard expanded, let window else { return }
    let pointer = window.mouseLocationOutsideOfEventStream
    if bounds.contains(convert(pointer, from: nil)) { trackPointer(at: pointer) } else { setHover(expanded: false, index: nil) }
  }

  private func trackPointer(at windowPoint: NSPoint) {
    let point = convert(windowPoint, from: nil)
    let edge = NSRect(x: 0, y: 0, width: 10, height: bounds.height)
    let inside = listRect.contains(point) || (edge.contains(point) && !expanded)
    let row = Int(floor((point.y - listTop) / rowHeight))
    let index = inside && entries.indices.contains(row) ? row : nil
    setHover(expanded: inside, index: index)
  }

  private func setHover(expanded newExpanded: Bool, index: Int?) {
    guard newExpanded != expanded || index != hoveredIndex else { return }
    expanded = newExpanded
    hoveredIndex = index
    applyState(animated: true)
    if index != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
  }

  /// Simulates hovering (for automated UI checks).
  func debugHover(_ index: Int?) {
    setHover(expanded: index != nil, index: index)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let row = Int(floor((point.y - listTop) / rowHeight))
    if entries.indices.contains(row) { onSelect?(row) }
  }

  /// How far a trackpad scroll has gone past an end (the raw distance; the
  /// list shows it with resistance, like a native scroll view's rubber band).
  private var overscroll: CGFloat = 0
  /// Springing back from past an end: momentum is ignored until the next
  /// gesture.
  private var settling = false

  private func rubberBand(_ distance: CGFloat) -> CGFloat {
    let range = max(bounds.height, 1)
    return (distance < 0 ? -1 : 1) * (1 - 1 / (abs(distance) * 0.55 / range + 1)) * range
  }

  private func setScrollOffset(_ offset: CGFloat, duration: CFTimeInterval = 0, completion: (() -> Void)? = nil) {
    scrollOffset = offset
    CATransaction.begin()
    CATransaction.setDisableActions(duration == 0 || Motion.reduceMotion)
    CATransaction.setAnimationDuration(duration)
    CATransaction.setAnimationTimingFunction(Motion.easeOut)
    // Rows moved under a still pointer (a bounce settling, no wheel event):
    // the hover follows once they're in place.
    CATransaction.setCompletionBlock { [weak self] in
      completion?()
      self?.syncHoverWithPointer()
    }
    positionRows()
    CATransaction.commit()
  }

  override func scrollWheel(with event: NSEvent) {
    guard overflows else {
      // Let the page keep scrolling underneath.
      (superview as? ColumnPageView)?.scrollView.scrollWheel(with: event)
      return
    }
    let limit = maxScrollOffset
    // A mouse wheel stops at the ends.
    guard event.hasPreciseScrollingDeltas else {
      let offset = min(max(0, scrollOffset - event.scrollingDeltaY * 12), limit)
      guard offset != scrollOffset else { return }
      setScrollOffset(offset)
      trackMouse(event)
      return
    }
    if event.phase == .began || event.phase == .mayBegin { settling = false }
    let momentum = !event.momentumPhase.isEmpty
    if momentum && settling { return }
    if event.phase == .ended || event.phase == .cancelled {
      // Let go past an end: back to it.
      if overscroll != 0 {
        overscroll = 0
        settling = true
        setScrollOffset(min(max(0, scrollOffset), limit), duration: 0.35)
      }
      return
    }
    let delta = event.scrollingDeltaY
    if momentum {
      let next = scrollOffset - delta
      guard next < 0 || next > limit else {
        setScrollOffset(next)
        trackMouse(event)
        return
      }
      // Momentum reaching an end: a short bounce past it, then back.
      let end: CGFloat = next < 0 ? 0 : limit
      settling = true
      setScrollOffset(end + (next < 0 ? -1 : 1) * min(abs(delta) * 4, 36), duration: 0.12) { [weak self] in
        self?.setScrollOffset(end, duration: 0.3)
      }
      return
    }
    // Fingers on the trackpad: past an end, the list follows with resistance.
    let raw = (overscroll == 0 ? scrollOffset : (overscroll < 0 ? 0 : limit) + overscroll) - delta
    if raw >= 0 && raw <= limit {
      overscroll = 0
      setScrollOffset(raw)
    } else {
      let end: CGFloat = raw < 0 ? 0 : limit
      overscroll = raw - end
      setScrollOffset(end + rubberBand(overscroll))
    }
    trackMouse(event)
  }

}
