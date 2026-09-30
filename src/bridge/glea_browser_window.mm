#import "GleaBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include "include/views/cef_fill_layout.h"
#include "include/views/cef_window.h"
#include "internal.h"

@interface GleaBrowserWindow ()
- (BOOL)windowShouldClose;
- (void)windowDestroyed;
- (CefRefPtr<CefWindow>)cefWindow;
- (BOOL)isPanel;
@end

namespace glea {
bool UsesChromeTabs() {
  static bool chrome = getenv("GLEA_ALLOY_TABS") == nullptr;
  return chrome;
}
}  // namespace glea

namespace {
using glea::UsesChromeTabs;

NSMapTable<NSWindow*, GleaBrowserWindow*>* Hosts() {
  static NSMapTable* hosts = [NSMapTable weakToStrongObjectsMapTable];
  return hosts;
}

// The Chromium (Views) window behind a GleaBrowserWindow: frameless, with the
// standard window buttons centered in a taller title bar.
class WindowDelegate : public CefWindowDelegate {
 public:
  WindowDelegate(GleaBrowserWindow* owner, NSRect rect, CGFloat titlebar, bool panel)
      : owner_(owner), rect_(rect), titlebar_(titlebar), panel_(panel) {}

  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool WithStandardWindowButtons(CefRefPtr<CefWindow>) override { return !panel_; }
  bool GetTitlebarHeight(CefRefPtr<CefWindow>, float* height) override {
    if (panel_) return false;
    *height = (float)titlebar_;
    return true;
  }
  bool CanResize(CefRefPtr<CefWindow>) override { return !panel_; }
  bool CanMaximize(CefRefPtr<CefWindow>) override { return !panel_; }
  bool CanMinimize(CefRefPtr<CefWindow>) override { return !panel_; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override {
    return CefRect((int)rect_.origin.x, (int)rect_.origin.y, (int)rect_.size.width, (int)rect_.size.height);
  }
  cef_state_t AcceptsFirstMouse(CefRefPtr<CefWindow>) override { return STATE_ENABLED; }

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window_ = window;
    // Each tab adds a full-size "slot" panel that positions its browser.
    window->SetToFillLayout();
  }

  bool CanClose(CefRefPtr<CefWindow>) override {
    if (glea::IsQuitting()) return true;
    GleaBrowserWindow* owner = owner_;
    return owner ? [owner windowShouldClose] : true;
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    window_ = nullptr;
    [owner_ windowDestroyed];
  }

  CefRefPtr<CefWindow> window() const { return window_; }

 private:
  __weak GleaBrowserWindow* owner_;
  NSRect rect_;
  CGFloat titlebar_;
  bool panel_;
  CefRefPtr<CefWindow> window_;
  IMPLEMENT_REFCOUNTING(WindowDelegate);
};

// Panels (pages drawn over a Glea window) take keyboard focus but must
// never become main: the Glea window they sit on stays main, so its title
// bar and traffic lights keep their active look. Chromium's NSWindow class
// answers for itself, so its canBecomeMainWindow is swizzled once to say no
// for windows flagged as panels (changing a window's class would break KVO).
char kNeverMainKey;
IMP g_can_become_main = nullptr;

BOOL GleaCanBecomeMain(id self, SEL cmd) {
  if (objc_getAssociatedObject(self, &kNeverMainKey)) return NO;
  return g_can_become_main ? ((BOOL(*)(id, SEL))g_can_become_main)(self, cmd) : YES;
}

// macOS clips windows to rounded corners (even borderless ones, here);
// pages must be plain rectangles, flush with the Glea window around them.
// Only flagged page windows answer "no corners"; others keep NSWindow's.
IMP g_corner_mask = nullptr;
IMP g_round_surface = nullptr;
IMP g_corner_radius = nullptr;

id GleaCornerMask(id self, SEL cmd) {
  if (objc_getAssociatedObject(self, &kNeverMainKey)) return nil;
  return ((id(*)(id, SEL))g_corner_mask)(self, cmd);
}

BOOL GleaRoundSurface(id self, SEL cmd) {
  if (objc_getAssociatedObject(self, &kNeverMainKey)) return NO;
  return ((BOOL(*)(id, SEL))g_round_surface)(self, cmd);
}

CGFloat GleaCornerRadius(id self, SEL cmd) {
  if (objc_getAssociatedObject(self, &kNeverMainKey)) return 0;
  return ((CGFloat(*)(id, SEL))g_corner_radius)(self, cmd);
}

void Override(Class cls, NSString* name, IMP replacement, IMP* original) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) return;
  *original = method_getImplementation(method);
  if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
    method_setImplementation(method, replacement);
  }
}

void MakeSquare(NSWindow* window) {
  static dispatch_once_t once;
  Class cls = [window class];
  dispatch_once(&once, ^{
    Override(cls, @"_cornerMask", (IMP)GleaCornerMask, &g_corner_mask);
    Override(cls, @"_shouldRoundCornersForSurface", (IMP)GleaRoundSurface, &g_round_surface);
    Override(cls, @"_cornerRadius", (IMP)GleaCornerRadius, &g_corner_radius);
  });
  SEL changed = NSSelectorFromString(@"_cornerMaskChanged");
  if ([window respondsToSelector:changed]) ((void (*)(id, SEL))objc_msgSend)(window, changed);
}

void MakeNeverMain(NSWindow* window) {
  static dispatch_once_t once;
  Class cls = [window class];  // the real class, not a KVO subclass
  dispatch_once(&once, ^{
    SEL sel = @selector(canBecomeMainWindow);
    Method method = class_getInstanceMethod(cls, sel);
    g_can_become_main = method_getImplementation(method);
    if (!class_addMethod(cls, sel, (IMP)GleaCanBecomeMain, method_getTypeEncoding(method))) {
      method_setImplementation(method, (IMP)GleaCanBecomeMain);
    }
  });
  objc_setAssociatedObject(window, &kNeverMainKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NSView* FindView(NSView* root, NSString* classFragment) {
  if ([NSStringFromClass(root.class) containsString:classFragment]) return root;
  for (NSView* child in root.subviews) {
    if (NSView* found = FindView(child, classFragment)) return found;
  }
  return nil;
}

cef_color_t ToCefColor(NSColor* color) {
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.whiteColor;
  return CefColorSetARGB(255, (int)(rgb.redComponent * 255), (int)(rgb.greenComponent * 255),
                         (int)(rgb.blueComponent * 255));
}

}  // namespace

@interface GleaBrowserWindow () <NSWindowDelegate>
@end

@implementation GleaBrowserWindow {
  CefRefPtr<WindowDelegate> _delegate;
  NSWindow* _window;
  BOOL _panel;
}

- (instancetype)initWithContentRect:(NSRect)rect titlebarHeight:(CGFloat)titlebarHeight {
  return [self initWithContentRect:rect titlebarHeight:titlebarHeight panel:NO];
}

- (instancetype)initPanelWithContentRect:(NSRect)rect {
  return [self initWithContentRect:rect titlebarHeight:0 panel:YES];
}

- (instancetype)initWithContentRect:(NSRect)rect titlebarHeight:(CGFloat)titlebarHeight panel:(BOOL)panel {
  if ((self = [super init])) {
    _panel = panel;
    _backgroundColor = NSColor.windowBackgroundColor;
    if (UsesChromeTabs()) {
      _hostsChromeTabs = YES;
      _delegate = new WindowDelegate(self, rect, titlebarHeight, panel);
      // Views creates the window (and calls OnWindowCreated) synchronously.
      CefWindow::CreateTopLevelWindow(_delegate);
      CefRefPtr<CefWindow> window = _delegate->window();
      id handle = window ? (__bridge id)(void*)window->GetWindowHandle() : nil;
      _window = [handle isKindOfClass:NSView.class] ? ((NSView*)handle).window : handle;
      _window.contentView.wantsLayer = YES;
      if (panel) {
        MakeNeverMain(_window);
        // Frameless Views windows are "titled" underneath, and macOS rounds
        // every corner of titled windows: pages must be plain rectangles.
        _window.styleMask = NSWindowStyleMaskBorderless;
        MakeSquare(_window);
      }
    } else {
      _window = [[NSWindow alloc]
          initWithContentRect:rect
                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                      backing:NSBackingStoreBuffered
                        defer:NO];
      _window.titlebarAppearsTransparent = YES;
      _window.titleVisibility = NSWindowTitleHidden;
      _window.delegate = self;
    }
    [Hosts() setObject:self forKey:_window];
  }
  return self;
}

+ (BOOL)chromeTabsEnabled {
  return UsesChromeTabs();
}

+ (GleaBrowserWindow*)hostOfWindow:(NSWindow*)window {
  return window ? [Hosts() objectForKey:window] : nil;
}

- (NSWindow*)window {
  return _window;
}

- (NSView*)webContentView {
  if (!_hostsChromeTabs) return nil;
  return FindView(_window.contentView, @"ViewsCompositorSuperview");
}

- (void)setBackgroundColor:(NSColor*)backgroundColor {
  _backgroundColor = backgroundColor;
  if (!_hostsChromeTabs) return;
  __block CGColorRef cg = nil;
  [_window.effectiveAppearance performAsCurrentDrawingAppearance:^{
    cg = CGColorRetain(backgroundColor.CGColor);
  }];
  // Behind the web content (seen while it fades) and where Chromium draws
  // no browser.
  _window.contentView.layer.backgroundColor = cg;
  if (CefRefPtr<CefWindow> window = _delegate ? _delegate->window() : nullptr) {
    window->SetBackgroundColor(ToCefColor([NSColor colorWithCGColor:cg]));
  }
  CGColorRelease(cg);
}

- (BOOL)windowShouldClose {
  return _shouldClose ? _shouldClose() : YES;
}

// NSWindowDelegate (plain windows only).
- (BOOL)windowShouldClose:(NSWindow*)sender {
  return [self windowShouldClose];
}

- (void)windowDestroyed {
  _delegate = nullptr;
}

- (CefRefPtr<CefWindow>)cefWindow {
  return _delegate ? _delegate->window() : nullptr;
}

- (BOOL)isPanel {
  return _panel;
}

@end

namespace glea {

CefRefPtr<CefWindow> ChromeWindowFor(NSWindow* window) {
  GleaBrowserWindow* host = [GleaBrowserWindow hostOfWindow:window];
  if (!host.hostsChromeTabs) return nullptr;
  return [host cefWindow];
}

bool IsPanelWindow(NSWindow* window) {
  return [[GleaBrowserWindow hostOfWindow:window] isPanel];
}

void CloseAllWindows() {
  for (GleaBrowserWindow* host in Hosts().objectEnumerator.allObjects) {
    if (CefRefPtr<CefWindow> window = [host cefWindow]) window->Close();
  }
}

}  // namespace glea
