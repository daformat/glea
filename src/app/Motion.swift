import AppKit
import QuartzCore

/// Animation curves and helpers, tuned after Beam's: short ease-in-outs for
/// state changes and firm springs for things that move.
enum Motion {
  static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
  /// Beam's "default iOS easing".
  static let standard = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
  static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  static func spring(_ keyPath: String, stiffness: CGFloat = 400, damping: CGFloat = 28) -> CASpringAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = 1
    animation.stiffness = stiffness
    animation.damping = damping
    animation.duration = animation.settlingDuration
    return animation
  }

  static func basic(_ keyPath: String, duration: CFTimeInterval, timing: CAMediaTimingFunction = standard) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.duration = reduceMotion ? 0 : duration
    animation.timingFunction = timing
    return animation
  }

  /// Runs AppKit animator() changes with a duration and curve.
  static func animate(_ duration: TimeInterval, timing: CAMediaTimingFunction = standard,
                      _ changes: () -> Void, completion: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = reduceMotion ? 0 : duration
      context.timingFunction = timing
      context.allowsImplicitAnimation = true
      changes()
    }, completionHandler: completion)
  }

  /// Changes layer properties without implicit animations.
  static func withoutAnimation(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
  }
}

extension NSView {
  /// A scale around the view's center. (Layers backing NSViews are anchored
  /// at their origin, so a plain scale would grow from a corner.)
  /// A new icon pops in: it scales up from 60% with a short spring as it
  /// fades in (favicons, the copy button's checkmark).
  func popIn() {
    wantsLayer = true
    guard !Motion.reduceMotion, let layer else { return }
    let scale = Motion.spring("transform", stiffness: 520, damping: 22)
    scale.fromValue = centeredScale(0.6)
    scale.toValue = CATransform3DIdentity
    let fade = Motion.basic("opacity", duration: 0.14, timing: Motion.easeOut)
    fade.fromValue = 0
    fade.toValue = 1
    layer.add(scale, forKey: "glea.icon.pop")
    layer.add(fade, forKey: "glea.icon.fade")
  }

  func centeredScale(_ scale: CGFloat) -> CATransform3D {
    let cx = bounds.midX
    let cy = bounds.midY
    var t = CATransform3DMakeTranslation(cx, cy, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    return CATransform3DTranslate(t, -cx, -cy, 0)
  }

  /// A scale anchored at the view's top-left corner.
  func topLeftScale(_ scale: CGFloat) -> CATransform3D {
    // Layers of views in non-flipped superviews have y going up.
    let y = superview?.isFlipped == true ? 0 : bounds.height
    var t = CATransform3DMakeTranslation(0, y, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    return CATransform3DTranslate(t, 0, -y, 0)
  }

  /// Fades and scales the view in, like Beam's omnibox.
  func animateIn(scale: CGFloat = 0.96, offsetY: CGFloat = 0, fade: CFTimeInterval = 0.08,
                 duration: CFTimeInterval = 0.16, timing: CAMediaTimingFunction = Motion.easeOut, fromTopLeft: Bool = false) {
    wantsLayer = true
    // A previous animateOut() leaves its end state filled in; clear it.
    layer?.removeAnimation(forKey: "glea.out.opacity")
    layer?.removeAnimation(forKey: "glea.out.transform")
    guard let layer, !Motion.reduceMotion else { return }
    layoutSubtreeIfNeeded()
    let opacity = Motion.basic("opacity", duration: fade)
    opacity.fromValue = 0
    opacity.toValue = 1
    let transform = Motion.basic("transform", duration: duration, timing: timing)
    transform.fromValue = CATransform3DConcat(fromTopLeft ? topLeftScale(scale) : centeredScale(scale), CATransform3DMakeTranslation(0, offsetY, 0))
    transform.toValue = CATransform3DIdentity
    layer.add(opacity, forKey: "glea.in.opacity")
    layer.add(transform, forKey: "glea.in.transform")
  }

  /// Fades and scales the view out, then calls `completion`.
  func animateOut(scale: CGFloat = 0.94, offsetY: CGFloat = 0, fade: CFTimeInterval = 0.1,
                  duration: CFTimeInterval = 0.2, toTopLeft: Bool = false, completion: @escaping () -> Void) {
    wantsLayer = true
    guard let layer, !Motion.reduceMotion else {
      completion()
      return
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock(completion)
    let opacity = Motion.basic("opacity", duration: fade)
    opacity.fromValue = layer.presentation()?.opacity ?? 1
    opacity.toValue = 0
    opacity.fillMode = .forwards
    opacity.isRemovedOnCompletion = false
    let transform = Motion.basic("transform", duration: duration)
    transform.toValue = CATransform3DConcat(toTopLeft ? topLeftScale(scale) : centeredScale(scale), CATransform3DMakeTranslation(0, offsetY, 0))
    transform.fillMode = .forwards
    transform.isRemovedOnCompletion = false
    layer.add(opacity, forKey: "glea.out.opacity")
    layer.add(transform, forKey: "glea.out.transform")
    CATransaction.commit()
  }

  /// Moves/resizes the view to `frame` with a spring. `fromCurrentFrame`
  /// starts from its frame rather than what's on screen (right after moving
  /// it to another superview, the screen still has the old coordinates).
  func springFrame(to frame: NSRect, stiffness: CGFloat = 420, damping: CGFloat = 32, fromCurrentFrame: Bool = false) {
    wantsLayer = true
    guard let layer, !Motion.reduceMotion, !self.frame.isEmpty else {
      self.frame = frame
      return
    }
    let presentation = fromCurrentFrame ? nil : layer.presentation()
    let fromPosition = presentation?.position ?? layer.position
    let fromBounds = presentation?.bounds ?? layer.bounds
    self.frame = frame
    let position = Motion.spring("position", stiffness: stiffness, damping: damping)
    position.fromValue = fromPosition
    position.toValue = layer.position
    let bounds = Motion.spring("bounds", stiffness: stiffness, damping: damping)
    bounds.fromValue = fromBounds
    bounds.toValue = layer.bounds
    layer.add(position, forKey: "glea.spring.position")
    layer.add(bounds, forKey: "glea.spring.bounds")
  }

  func resolvedCGColor(_ color: NSColor) -> CGColor {
    var cg = color.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
    return cg
  }
}

/// A rounded background layer whose color changes cross-fade, for hover and
/// selection states.
final class HighlightLayer: CALayer {
  override init() {
    super.init()
    cornerRadius = 7
    cornerCurve = .continuous
  }

  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  override func action(forKey event: String) -> CAAction? {
    if event == "backgroundColor" || event == "opacity" || event == "borderColor" {
      let animation = Motion.basic(event, duration: 0.12, timing: Motion.easeInOut)
      return animation
    }
    if event == "bounds" || event == "position" { return NSNull() }
    return super.action(forKey: event)
  }
}
