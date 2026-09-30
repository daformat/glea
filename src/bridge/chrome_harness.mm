// Chrome-style feasibility harness.
//
// Glea's tabs are Alloy-style browsers parented to its own NSViews. Chrome
// extensions only work with Chrome-style browsers, which CEF only creates in
// its own Views windows (a parent NSView forces Alloy style). This harness
// builds the closest equivalent of Glea's window that way and checks, with
// screenshots and pixel samples, whether Glea's design and animations would
// survive:
//
//   1. a frameless CEF window with Glea's 52pt title bar and traffic lights
//   2. native NSViews composited above the web content
//   3. spring / fade animations on those native views
//   4. transforms (scale) and fades applied to the web content itself
//   5. animated resizing of the web content (DevTools docking, split views)
//   6. a native "notes" page crossfading over the web
//   7. an unpacked Chrome extension (MV3 content script) loading and running
//
// Run with GLEA_CHROME_HARNESS=<output dir> (see scripts/chrome-harness.sh).
// Results go to <output dir>/report.json and report.html, with screenshots.
// Variants: GLEA_HARNESS_TOOLBAR=none|location|normal (Chrome's toolbar),
// GLEA_HARNESS_FRAMED=1 (standard title bar), GLEA_HARNESS_NO_EXTENSION=1.
//
// Findings so far: Chromium draws a Views window's contents with its own
// compositor into a ViewsCompositorSuperview; transforms and fades must go on
// that view's layer (NSViews like RenderWidgetHostViewCocoa only take input),
// and they apply to every browser in the window at once. Children are placed
// through layouts (a Window and a Panel fill by default), not SetBounds. And
// --disable-features must not be passed: it replaces CEF's own list and
// crashes window creation.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <functional>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_window.h"

namespace {

NSString* g_out;
NSMutableArray<NSDictionary*>* g_results;
CefRefPtr<CefWindow> g_window;
CefRefPtr<CefBrowserView> g_browser_view;
std::function<void()> g_on_load_end;
std::function<void(const std::string&)> g_on_console;

const CGFloat kTopBar = 52;

// MARK: - CEF plumbing

class HarnessClient : public CefClient, public CefLoadHandler, public CefDisplayHandler {
 public:
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override {
    fprintf(stderr, "HARNESS load end %d (main %d)\n", status, frame->IsMain());
    if (frame->IsMain() && g_on_load_end) {
      auto callback = g_on_load_end;
      g_on_load_end = nullptr;
      callback();
    }
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString& message,
                        const CefString&, int) override {
    std::string text = message.ToString();
    if (text.rfind("HARNESS ", 0) == 0 && g_on_console) g_on_console(text.substr(8));
    return false;
  }

 private:
  IMPLEMENT_REFCOUNTING(HarnessClient);
};

class HarnessBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override {
    const char* toolbar = getenv("GLEA_HARNESS_TOOLBAR");
    if (toolbar && strcmp(toolbar, "normal") == 0) return CEF_CTT_NORMAL;
    if (toolbar && strcmp(toolbar, "location") == 0) return CEF_CTT_LOCATION;
    return CEF_CTT_NONE;
  }

 private:
  IMPLEMENT_REFCOUNTING(HarnessBrowserViewDelegate);
};

void RunSteps();

class HarnessWindowDelegate : public CefWindowDelegate {
 public:
  explicit HarnessWindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}

  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return getenv("GLEA_HARNESS_FRAMED") == nullptr; }
  bool WithStandardWindowButtons(CefRefPtr<CefWindow>) override { return true; }
  bool GetTitlebarHeight(CefRefPtr<CefWindow>, float* height) override {
    *height = kTopBar;
    return true;
  }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(120, 120, 1100, 720); }

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    fprintf(stderr, "HARNESS window created\n");
    g_window = window;
    window->AddChildView(view_);
    SetInsets(0);
    LayoutBrowser(window->GetBounds().width, window->GetBounds().height);
    window->Show();
  }

  void OnWindowBoundsChanged(CefRefPtr<CefWindow>, const CefRect& bounds) override {
    LayoutBrowser(bounds.width, bounds.height);
  }

  bool CanClose(CefRefPtr<CefWindow>) override {
    CefRefPtr<CefBrowser> browser = view_->GetBrowser();
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    g_window = nullptr;
    g_browser_view = nullptr;
    view_ = nullptr;
    CefQuitMessageLoop();
  }

  static void LayoutBrowser(int width, int height) { SetInsets(0); }

  /// The web area sits below the top bar, `right` points short of the right
  /// edge (a docked panel). Views only positions children through layouts.
  static void SetInsets(int right) {
    if (!g_window) return;
    CefBoxLayoutSettings settings;
    settings.horizontal = false;
    settings.inside_border_insets = CefInsets((int)kTopBar, 0, 0, right);
    CefRefPtr<CefBoxLayout> layout = g_window->SetToBoxLayout(settings);
    if (g_browser_view) layout->SetFlexForView(g_browser_view, 1);
    g_window->Layout();
  }

 private:
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(HarnessWindowDelegate);
};

// MARK: - Helpers

NSWindow* HarnessNSWindow() {
  if (!g_window) return nil;
  id handle = (__bridge id)(void*)g_window->GetWindowHandle();
  if ([handle isKindOfClass:NSWindow.class]) return handle;
  if ([handle isKindOfClass:NSView.class]) return ((NSView*)handle).window;
  return nil;
}

void Record(NSString* check, BOOL pass, NSString* detail, NSString* screenshot = nil) {
  NSMutableDictionary* entry = [@{@"check" : check, @"pass" : @(pass), @"detail" : detail ?: @""} mutableCopy];
  if (screenshot) entry[@"screenshot"] = screenshot;
  [g_results addObject:entry];
  fprintf(stderr, "HARNESS %s %s — %s\n", pass ? "PASS" : "FAIL", check.UTF8String, detail.UTF8String);
}

/// Captures the window (only) with screencapture; returns the file name.
NSString* Screenshot(NSString* name) {
  NSWindow* window = HarnessNSWindow();
  NSString* file = [name stringByAppendingPathExtension:@"png"];
  NSTask* task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
  task.arguments = @[ @"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)window.windowNumber],
                      [g_out stringByAppendingPathComponent:file] ];
  [task launchAndReturnError:nil];
  [task waitUntilExit];
  return file;
}

/// The color of a screenshot at a point given in window points from the top left.
NSColor* PixelAt(NSString* file, CGFloat x, CGFloat y) {
  NSBitmapImageRep* rep = (NSBitmapImageRep*)[NSBitmapImageRep imageRepWithContentsOfFile:[g_out stringByAppendingPathComponent:file]];
  if (!rep) return nil;
  CGFloat scale = rep.pixelsWide / HarnessNSWindow().frame.size.width;
  return [[rep colorAtX:(NSInteger)(x * scale) y:(NSInteger)(y * scale)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

BOOL IsRed(NSColor* c) { return c && c.redComponent > 0.7 && c.greenComponent < 0.55 && c.blueComponent < 0.5; }
BOOL IsGreen(NSColor* c) { return c && c.greenComponent > 0.6 && c.redComponent < 0.6 && c.blueComponent < 0.6; }
BOOL IsBlue(NSColor* c) { return c && c.blueComponent > 0.7 && c.redComponent < 0.4; }
BOOL IsPurple(NSColor* c) { return c && c.blueComponent > 0.7 && c.redComponent > 0.35 && c.greenComponent < c.redComponent; }
BOOL IsDark(NSColor* c) { return c && c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25; }

NSString* Describe(NSColor* c) {
  if (!c) return @"(no pixel)";
  return [NSString stringWithFormat:@"rgb(%.0f,%.0f,%.0f)", c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255];
}

void After(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

/// The NSView Chromium renders the web contents into, and its topmost
/// ancestor below the window's content view (what we'd animate).
NSView* FindView(NSView* root, NSString* classFragment) {
  if ([NSStringFromClass(root.class) containsString:classFragment]) return root;
  for (NSView* child in root.subviews) {
    if (NSView* found = FindView(child, classFragment)) return found;
  }
  return nil;
}

void DumpHierarchy(NSView* view, int depth, NSMutableString* out) {
  [out appendFormat:@"%@%@ %@%@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
                    NSStringFromClass(view.class), NSStringFromRect(view.frame), view.wantsLayer ? @" [layer]" : @""];
  if (depth < 7) for (NSView* child in view.subviews) DumpHierarchy(child, depth + 1, out);
}

// A deterministic page: red left half, green right half, a blue band on top.
NSString* TestPageURL() {
  NSString* html = @"<!doctype html><html><body style=\"margin:0;height:100vh;display:grid;"
                   @"grid-template-rows:80px 1fr;grid-template-columns:1fr 1fr\">"
                   @"<div style=\"grid-column:1/3;background:#0a64ff\"></div>"
                   @"<div style=\"background:#ff3b30\"></div><div style=\"background:#34c759\"></div>"
                   @"<script>console.log('HARNESS page-ready')</script></body></html>";
  return [@"data:text/html;charset=utf-8," stringByAppendingString:
          [html stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
}

// MARK: - Native UI standing in for Glea's

/// A frame given from the top left, in a view that may or may not be flipped.
NSRect FromTop(NSView* view, CGFloat x, CGFloat top, CGFloat width, CGFloat height) {
  CGFloat y = view.isFlipped ? top : view.bounds.size.height - top - height;
  return NSMakeRect(x, y, width, height);
}

NSView* g_topBar;
NSView* g_card;

void AddNativeChrome() {
  NSWindow* window = HarnessNSWindow();
  NSView* content = window.contentView;
  // Glea's top bar: its own color, above the web content.
  g_topBar = [[NSView alloc] initWithFrame:FromTop(content, 0, 0, content.bounds.size.width, kTopBar)];
  g_topBar.autoresizingMask = NSViewWidthSizable | (content.isFlipped ? NSViewMaxYMargin : NSViewMinYMargin);
  g_topBar.wantsLayer = YES;
  g_topBar.layer.backgroundColor = [NSColor colorWithSRGBRed:0.14 green:0.14 blue:0.15 alpha:1].CGColor;
  NSTextField* title = [NSTextField labelWithString:@"Glea · Chrome-style harness"];
  title.textColor = NSColor.secondaryLabelColor;
  title.frame = NSMakeRect(90, 17, 300, 18);
  [g_topBar addSubview:title];
  [content addSubview:g_topBar positioned:NSWindowAbove relativeTo:nil];
  // The standard window buttons must stay above the bar.
  for (NSWindowButton kind : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
    NSButton* button = [window standardWindowButton:kind];
    [button.superview addSubview:button positioned:NSWindowAbove relativeTo:nil];
  }
}

// MARK: - Steps

void Finish();

void StepLayout() {
  NSString* shot = Screenshot(@"1-layout");
  NSColor* bar = PixelAt(shot, 600, 30);
  NSColor* band = PixelAt(shot, 600, kTopBar + 40);
  NSColor* left = PixelAt(shot, 200, 400);
  NSColor* right = PixelAt(shot, 900, 400);
  BOOL pass = IsDark(bar) && IsBlue(band) && IsRed(left) && IsGreen(right);
  Record(@"Frameless window, native 52pt top bar above Chrome-style web content", pass,
         [NSString stringWithFormat:@"bar %@, page top %@, left %@, right %@", Describe(bar), Describe(band), Describe(left), Describe(right)], shot);
  NSMutableString* tree = [NSMutableString string];
  DumpHierarchy(HarnessNSWindow().contentView, 0, tree);
  [tree writeToFile:[g_out stringByAppendingPathComponent:@"view-hierarchy.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void StepOverlayAnimation(dispatch_block_t next) {
  NSView* content = HarnessNSWindow().contentView;
  g_card = [[NSView alloc] initWithFrame:FromTop(content, 350, 290, 400, 180)];
  g_card.wantsLayer = YES;
  g_card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.44 green:0.345 blue:1 alpha:1].CGColor;
  g_card.layer.cornerRadius = 16;
  g_card.layer.shadowOpacity = 0.35;
  g_card.layer.shadowRadius = 24;
  g_card.layer.shadowOffset = CGSizeMake(0, -8);
  [content addSubview:g_card positioned:NSWindowBelow relativeTo:g_topBar];

  // Beam-style entrance: scale from 0.9 with a spring, fade in.
  CALayer* layer = g_card.layer;
  layer.anchorPoint = CGPointMake(0.5, 0.5);
  layer.position = CGPointMake(NSMidX(g_card.frame), NSMidY(g_card.frame));
  CASpringAnimation* spring = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
  spring.fromValue = @0.9;
  spring.toValue = @1;
  spring.stiffness = 380;
  spring.damping = 26;
  spring.duration = spring.settlingDuration;
  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @0;
  fade.toValue = @1;
  fade.duration = 0.2;
  [layer addAnimation:spring forKey:@"scale"];
  [layer addAnimation:fade forKey:@"fade"];

  // Sample the running animation and the main thread's responsiveness.
  NSMutableArray<NSNumber*>* scales = [NSMutableArray array];
  __block CFTimeInterval last = CACurrentMediaTime();
  __block double worstGap = 0;
  NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer*) {
    CFTimeInterval now = CACurrentMediaTime();
    worstGap = MAX(worstGap, now - last);
    last = now;
    NSNumber* scale = [layer.presentationLayer valueForKeyPath:@"transform.scale"];
    if (scale) [scales addObject:scale];
  }];
  After(0.06, ^{ Screenshot(@"2-overlay-mid"); });
  After(0.6, ^{
    [timer invalidate];
    NSString* shot = Screenshot(@"3-overlay-end");
    NSColor* center = PixelAt(shot, 550, 380);
    NSSet* distinct = [NSSet setWithArray:[scales valueForKey:@"stringValue"]];
    BOOL pass = IsPurple(center) && distinct.count > 5;
    Record(@"Native card composited over web content, spring + fade animation", pass,
           [NSString stringWithFormat:@"card center %@; %lu animation frames sampled (%lu distinct scales, first %.3f); worst main-thread gap %.1f ms",
                                      Describe(center), (unsigned long)scales.count, (unsigned long)distinct.count,
                                      scales.firstObject.doubleValue, worstGap * 1000],
           shot);
    [g_card removeFromSuperview];
    next();
  });
}

void DumpLayers(CALayer* layer, int depth, NSMutableString* out) {
  [out appendFormat:@"%@%@ %@%@%@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
                    NSStringFromClass(layer.class), NSStringFromRect(NSRectFromCGRect(layer.frame)),
                    layer.delegate ? [NSString stringWithFormat:@" delegate=%@", NSStringFromClass([(NSObject*)layer.delegate class])] : @"",
                    layer.contents ? @" [contents]" : @""];
  if (depth < 8) for (CALayer* child in layer.sublayers) DumpLayers(child, depth + 1, out);
}

/// Chromium draws the Views tree (and the web contents in it) with its own
/// compositor into CALayers under the window's content view; NSViews like
/// RenderWidgetHostViewCocoa only take input. The drawing layer is the
/// content view's sublayer that isn't one of its subviews' layers.
CALayer* CompositorLayer() {
  NSView* host = FindView(HarnessNSWindow().contentView, @"ViewsCompositorSuperview");
  return host.layer;
}

void StepWebTransform(dispatch_block_t next) {
  NSMutableString* tree = [NSMutableString string];
  DumpLayers(HarnessNSWindow().contentView.layer, 0, tree);
  [tree writeToFile:[g_out stringByAppendingPathComponent:@"layer-tree.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

  CALayer* layer = CompositorLayer();
  if (!layer) {
    Record(@"Scale transform on the web content (anchored top-left)", NO, @"no compositor layer found (see layer-tree.txt)");
    next();
    return;
  }
  // Scale to 70% from the top-left corner, like Glea's media expand/collapse.
  CGPoint oldAnchor = layer.anchorPoint, oldPosition = layer.position;
  CGRect frame = layer.frame;
  BOOL flipped = layer.superlayer.geometryFlipped;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.anchorPoint = CGPointMake(0, flipped ? 0 : 1);
  layer.position = CGPointMake(CGRectGetMinX(frame), flipped ? CGRectGetMinY(frame) : CGRectGetMaxY(frame));
  [CATransaction commit];
  CABasicAnimation* scale = [CABasicAnimation animationWithKeyPath:@"transform"];
  scale.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
  scale.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.7, 0.7, 1)];
  scale.duration = 0.3;
  scale.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.42 :0 :0.25 :1];
  layer.transform = CATransform3DMakeScale(0.7, 0.7, 1);
  [layer addAnimation:scale forKey:@"harness"];
  After(0.15, ^{ Screenshot(@"4-web-scale-mid"); });
  After(0.6, ^{
    NSString* shot = Screenshot(@"5-web-scale-end");
    CGFloat w = HarnessNSWindow().frame.size.width, h = HarnessNSWindow().frame.size.height;
    // Scaled to 70% from the top left: the bottom-right corner no longer shows the page.
    NSColor* farRight = PixelAt(shot, w - 40, h - 40);
    NSColor* stillLeft = PixelAt(shot, 150, kTopBar + 200);
    Record(@"Scale transform on the web content (anchored top-left)", !IsGreen(farRight) && IsRed(stillLeft),
           [NSString stringWithFormat:@"bottom-right after scaling %@ (green = not scaled), top-left %@; layer %@ %@",
                                      Describe(farRight), Describe(stillLeft), NSStringFromClass(layer.class),
                                      NSStringFromRect(NSRectFromCGRect(frame))],
           shot);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DIdentity;
    layer.anchorPoint = oldAnchor;
    layer.position = oldPosition;
    [CATransaction commit];

    // Fade the web content to 30%.
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0.3;
    fade.duration = 0.25;
    layer.opacity = 0.3;
    [layer addAnimation:fade forKey:@"fade"];
    After(0.5, ^{
      NSString* faded = Screenshot(@"6-web-fade");
      NSColor* left = PixelAt(faded, 200, 400);
      Record(@"Fading the web content (opacity 0.3, e.g. web ↔ notes crossfade)", left && !IsRed(left),
             [NSString stringWithFormat:@"red half at 30%% opacity: %@", Describe(left)], faded);
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      layer.opacity = 1;
      [CATransaction commit];
      next();
    });
  });
}

void StepResizeAnimation(dispatch_block_t next) {
  // Animate the web content's width like DevTools docking: 60 steps of SetBounds.
  CefRect full = g_window->GetBounds();
  int from = full.width, to = (int)(full.width * 0.6);
  __block int step = 0;
  NSMutableArray<NSNumber*>* costs = [NSMutableArray array];
  NSTimer* __block timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer* t) {
    step++;
    double p = MIN(1.0, step / 18.0);
    double eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2;
    int width = (int)(from + (to - from) * eased);
    CFTimeInterval start = CACurrentMediaTime();
    HarnessWindowDelegate::SetInsets(full.width - width);
    [costs addObject:@((CACurrentMediaTime() - start) * 1000)];
    if (step == 9) Screenshot(@"7-resize-mid");
    if (p >= 1) [t invalidate];
  }];
  (void)timer;
  After(0.9, ^{
    NSString* shot = Screenshot(@"8-resize-end");
    // The page reflows: the red/green split sits at 30% of the window now.
    NSColor* atOldSplit = PixelAt(shot, 500, 400);
    NSColor* beyond = PixelAt(shot, 900, 400);
    double worst = [[costs valueForKeyPath:@"@max.doubleValue"] doubleValue];
    double average = [[costs valueForKeyPath:@"@avg.doubleValue"] doubleValue];
    BOOL reflowed = IsGreen(atOldSplit) && !IsGreen(beyond);
    Record(@"Animated resize of the web content (relayout each frame)", reflowed,
           [NSString stringWithFormat:@"after: x=500 %@ (green = reflowed), x=900 %@ (outside); relayout avg %.2f ms, worst %.2f ms over %lu frames",
                                      Describe(atOldSplit), Describe(beyond), average, worst, (unsigned long)costs.count],
           shot);
    HarnessWindowDelegate::LayoutBrowser(full.width, full.height);
    next();
  });
}

void StepNotesCrossfade(dispatch_block_t next) {
  NSView* content = HarnessNSWindow().contentView;
  NSView* notes = [[NSView alloc] initWithFrame:FromTop(content, 0, kTopBar, content.bounds.size.width, content.bounds.size.height - kTopBar)];
  notes.wantsLayer = YES;
  notes.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:1].CGColor;
  NSTextField* heading = [NSTextField labelWithString:@"Today"];
  heading.font = [NSFont systemFontOfSize:30 weight:NSFontWeightBold];
  heading.textColor = NSColor.whiteColor;
  heading.frame = FromTop(notes, 300, 60, 300, 40);
  [notes addSubview:heading];
  [content addSubview:notes positioned:NSWindowBelow relativeTo:g_topBar];
  CABasicAnimation* fadeIn = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fadeIn.fromValue = @0;
  fadeIn.toValue = @1;
  // Slow enough that a screenshot (~150 ms to take) lands mid-fade.
  fadeIn.duration = 1.6;
  [notes.layer addAnimation:fadeIn forKey:@"fade"];
  After(0.35, ^{
    NSString* mid = Screenshot(@"9-notes-crossfade-mid");
    NSColor* blend = PixelAt(mid, 200, 400);
    After(1.6, ^{
      NSString* end = Screenshot(@"10-notes-crossfade-end");
      NSColor* covered = PixelAt(end, 200, 400);
      BOOL pass = blend && covered && blend.redComponent > covered.redComponent + 0.1 && IsDark(covered);
      Record(@"Native notes page crossfading over the web content", pass,
             [NSString stringWithFormat:@"mid-fade %@, end %@", Describe(blend), Describe(covered)], end);
      [notes removeFromSuperview];
      next();
    });
  });
}

void StepExtension(dispatch_block_t next) {
  static BOOL answered;
  answered = NO;
  g_on_console = [next](const std::string& message) {
    if (message.rfind("ext=", 0) != 0 || answered) return;
    answered = YES;
    NSString* value = [NSString stringWithUTF8String:message.substr(4).c_str()];
    NSString* shot = Screenshot(@"11-extension");
    Record(@"Unpacked MV3 extension loaded, its content script runs", [value hasPrefix:@"ran"],
           [NSString stringWithFormat:@"content script marker on example.com: %@", value], shot);
    next();
  };
  g_on_load_end = [] {
    After(1.5, ^{
      CefRefPtr<CefFrame> frame = g_browser_view->GetBrowser()->GetMainFrame();
      frame->ExecuteJavaScript(
          "console.log('HARNESS ext=' + (document.documentElement.dataset.gleaHarness ? "
          "'ran (' + document.documentElement.dataset.gleaHarness + ')' : 'not run'))",
          frame->GetURL(), 0);
    });
  };
  g_browser_view->GetBrowser()->GetMainFrame()->LoadURL("https://example.com/");
  After(15, ^{
    if (answered) return;
    answered = YES;
    Record(@"Unpacked MV3 extension loaded, its content script runs", NO, @"no answer from the page within 15 s",
           Screenshot(@"11-extension"));
    next();
  });
}

void WriteReport() {
  NSData* json = [NSJSONSerialization dataWithJSONObject:g_results options:NSJSONWritingPrettyPrinted error:nil];
  [json writeToFile:[g_out stringByAppendingPathComponent:@"report.json"] atomically:YES];
  NSMutableString* html = [NSMutableString stringWithString:
      @"<!doctype html><meta charset=utf-8><title>Chrome-style harness</title>"
      @"<style>body{font:14px -apple-system;margin:32px;background:#111;color:#eee}"
      @".r{margin:0 0 28px}.p{color:#34c759}.f{color:#ff453a}img{max-width:720px;border-radius:8px;display:block;margin-top:8px}"
      @"code{color:#aaa}</style><h1>Chrome-style browser: can Glea keep its design?</h1>"];
  for (NSDictionary* r in g_results) {
    BOOL pass = [r[@"pass"] boolValue];
    [html appendFormat:@"<div class=r><b class=%@>%@</b> %@<br><code>%@</code>%@</div>", pass ? @"p" : @"f",
                       pass ? @"PASS" : @"FAIL", r[@"check"], r[@"detail"],
                       r[@"screenshot"] ? [NSString stringWithFormat:@"<img src=\"%@\">", r[@"screenshot"]] : @""];
  }
  [html writeToFile:[g_out stringByAppendingPathComponent:@"report.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void Finish() {
  WriteReport();
  fprintf(stderr, "HARNESS done: %s/report.html\n", g_out.UTF8String);
  if (g_window) g_window->Close();
  After(3, ^{ CefQuitMessageLoop(); });
}

void RunSteps() {
  [NSApp activateIgnoringOtherApps:YES];
  AddNativeChrome();
  After(0.8, ^{
    StepLayout();
    StepOverlayAnimation(^{
      StepWebTransform(^{
        StepResizeAnimation(^{
          StepNotesCrossfade(^{
            StepExtension(^{ Finish(); });
          });
        });
      });
    });
  });
}

}  // namespace

// Writes the test extension, returns its folder.
NSString* GleaChromeHarnessExtensionPath(NSString* out) {
  NSString* dir = [out stringByAppendingPathComponent:@"test-extension"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSDictionary* files = @{
    @"manifest.json" : @"{\n  \"manifest_version\": 3,\n  \"name\": \"Glea harness\",\n  \"version\": \"1.0\",\n"
                       @"  \"background\": {\"service_worker\": \"background.js\"},\n"
                       @"  \"content_scripts\": [{\"matches\": [\"<all_urls>\"], \"js\": [\"content.js\"], \"run_at\": \"document_idle\"}]\n}\n",
    @"content.js" : @"chrome.runtime.sendMessage({hello: true}, (reply) => {\n"
                    @"  document.documentElement.dataset.gleaHarness = reply && reply.worker ? 'worker replied' : 'no worker reply';\n"
                    @"});\ndocument.documentElement.dataset.gleaHarness = 'content script';\n",
    @"background.js" : @"chrome.runtime.onMessage.addListener((message, sender, reply) => { reply({worker: true}); });\n",
  };
  for (NSString* name in files) {
    [files[name] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  return dir;
}

void GleaRunChromeHarness(NSString* out) {
  g_out = out;
  g_results = [NSMutableArray array];
  [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
  CefBrowserSettings settings;
  settings.background_color = CefColorSetARGB(255, 28, 28, 31);
  CefRefPtr<HarnessClient> client(new HarnessClient);
  g_browser_view = CefBrowserView::CreateBrowserView(client, TestPageURL().UTF8String, settings, nullptr, nullptr,
                                                     new HarnessBrowserViewDelegate);
  static BOOL started;
  g_on_load_end = [] {
    if (started) return;
    started = YES;
    After(0.3, ^{ RunSteps(); });
  };
  // Never wait forever on the first load.
  After(8, ^{
    if (started) return;
    fprintf(stderr, "HARNESS no load end after 8 s, running anyway\n");
    started = YES;
    g_on_load_end = nullptr;
    RunSteps();
  });
  CefWindow::CreateTopLevelWindow(new HarnessWindowDelegate(g_browser_view));
}
