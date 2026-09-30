// Objective-C interface to the CEF (Chromium Embedded Framework) layer.
//
// This header is plain Objective-C so it can be imported from Swift through
// the `GleaBridge` module. All C++ lives in the .mm implementation files.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the browser process: loads the CEF framework, initializes Chromium,
/// installs an instance of `delegateClassName` as the NSApplication delegate
/// and runs the message loop until `GleaCEF.requestQuit` completes.
#ifdef __cplusplus
extern "C"
#endif
int GleaMain(int argc, char* _Nullable* _Nonnull argv, NSString* delegateClassName);

NS_SWIFT_UI_ACTOR
@interface GleaCEF : NSObject
/// Called once when the user asks to quit, before browsers are closed.
@property(class, nonatomic, copy, nullable) void (^willQuitHandler)(void);
/// Closes every browser and exits the message loop once they are all gone.
+ (void)requestQuit;
/// Chromium's profile folder (holds installed extensions and their settings).
@property(class, nonatomic, readonly) NSString* profilePath;
/// Chrome sometimes opens a Chrome window of its own (after an extension is
/// installed, or when an extension opens a tab). Glea hides and closes it
/// and calls this with the first address it showed (its New Tab page, or a
/// page to reopen as a Glea tab).
@property(class, nonatomic, copy, nullable) void (^chromeWindowHandler)(NSString* url);
@end

typedef NS_ENUM(NSInteger, GleaContextCommand) {
  GleaContextCommandOpenLinkInNewTab,
  GleaContextCommandCopyLink,
  GleaContextCommandCollectSelection,
  GleaContextCommandSearchSelection,
  GleaContextCommandCollectImage,
  GleaContextCommandOpenImageInNewTab,
  GleaContextCommandCollectPage,
};

typedef NS_ENUM(NSInteger, GleaDevToolsDock) {
  GleaDevToolsDockRight,
  GleaDevToolsDockBottom,
  GleaDevToolsDockWindow,
  GleaDevToolsDockLeft,
};

@class GleaBrowserView;

/// Where browsers keep cookies, caches and site data. Views without one use
/// the profile on disk.
NS_SWIFT_UI_ACTOR
@interface GleaBrowsingSession : NSObject
/// A new off-the-record session: everything stays in memory, shared by the
/// browsers created with it, and is gone once the last of them closes.
+ (instancetype)incognitoSession;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A window created by Chromium (CEF Views): the only way to host a
/// Chrome-style browser (and so Chrome extensions), one per window. Glea uses
/// borderless panels of these for each Chrome-style page. With
/// GLEA_ALLOY_TABS=1 set it's a plain NSWindow.
NS_SWIFT_UI_ACTOR
@interface GleaBrowserWindow : NSObject
- (instancetype)initWithContentRect:(NSRect)rect titlebarHeight:(CGFloat)titlebarHeight;
/// A borderless panel (extension popups): no title bar, not resizable.
- (instancetype)initPanelWithContentRect:(NSRect)rect;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSWindow* window;
/// YES when tabs are Chrome-style browsers drawn by Chromium in this window.
@property(nonatomic, readonly) BOOL hostsChromeTabs;
/// The view Chromium draws web content into, below the app's views. Animate
/// its layer (fades, scales) to animate the web content itself.
@property(nonatomic, readonly, nullable) NSView* webContentView;
/// Shown where no web content is (Chrome-hosted windows only).
@property(nonatomic, strong) NSColor* backgroundColor;
/// Asked when the user closes the window; return NO to keep it open.
@property(nonatomic, copy, nullable) BOOL (^shouldClose)(void);
/// The window hosting `window`, if any.
+ (nullable GleaBrowserWindow*)hostOfWindow:(NSWindow*)window;
/// NO when GLEA_ALLOY_TABS is set: pages are then Alloy-style (no extensions).
@property(class, nonatomic, readonly) BOOL chromeTabsEnabled;
@end

NS_SWIFT_UI_ACTOR
@protocol GleaBrowserViewDelegate <NSObject>
@optional
- (void)browserViewDidChangeState:(GleaBrowserView*)view;
/// All the page's icon candidates, in the page's order.
- (void)browserView:(GleaBrowserView*)view didChangeFaviconURLs:(NSArray<NSString*>*)urls;
- (void)browserView:(GleaBrowserView*)view didCommitNavigationToURL:(NSString*)url;
- (void)browserView:(GleaBrowserView*)view
    didFailLoadWithError:(NSString*)error
                     url:(NSString*)url;
- (void)browserView:(GleaBrowserView*)view
    requestsNewTabWithURL:(NSString*)url
               background:(BOOL)background;
/// Before the main frame navigates: return NO to cancel.
- (BOOL)browserView:(GleaBrowserView*)view
    shouldNavigateToURL:(NSString*)url
            userGesture:(BOOL)userGesture;
/// A message posted from page script via `__gleaNative.post(name, json)`.
- (void)browserView:(GleaBrowserView*)view
    didReceiveMessage:(NSString*)name
              payload:(NSString*)json;
/// With auto-resize on: the page's preferred size (points), as Chrome sizes
/// extension popups.
- (void)browserView:(GleaBrowserView*)view didAutoResizeToSize:(NSSize)size;
- (void)browserView:(GleaBrowserView*)view
    contextCommand:(GleaContextCommand)command
          argument:(NSString*)argument;
- (void)browserView:(GleaBrowserView*)view
    findResultCount:(NSInteger)count
       activeMatch:(NSInteger)active;
- (void)browserView:(GleaBrowserView*)view didFinishDownloadAtPath:(NSString*)path;
/// A page asks for the camera and/or microphone: call `completion` (on the
/// main thread, now or later) with the answer.
- (void)browserView:(GleaBrowserView*)view
    requestsMediaAccessForOrigin:(NSString*)origin
                          camera:(BOOL)camera
                      microphone:(BOOL)microphone
                      completion:(void (^)(BOOL allowed))completion;
/// The page started or stopped using the camera and/or microphone.
- (void)browserView:(GleaBrowserView*)view didChangeMediaAccessCamera:(BOOL)camera microphone:(BOOL)microphone;
- (void)browserViewDidClose:(GleaBrowserView*)view;
- (void)browserViewDidChangeDevTools:(GleaBrowserView*)view;
- (void)browserView:(GleaBrowserView*)view didReceiveDevToolsMessage:(NSString*)json;
/// The docked pane's header buttons, and "Inspect Element".
- (void)browserView:(GleaBrowserView*)view requestsDevToolsDock:(GleaDevToolsDock)dock;
- (void)browserViewRequestsDevToolsClose:(GleaBrowserView*)view;
- (void)browserView:(GleaBrowserView*)view requestsInspectElementAt:(NSPoint)point;
@end

/// An NSView hosting one Chromium browser (one tab).
NS_SWIFT_UI_ACTOR
@interface GleaBrowserView : NSView

/// `contentScript` is evaluated in every main-frame JavaScript context before
/// page scripts run. It can call `__gleaNative.post(name, json)`.
- (instancetype)initWithURL:(NSString*)url
              contentScript:(nullable NSString*)contentScript NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<GleaBrowserViewDelegate> delegate;

/// Tabs set this: in a Chrome-hosted window the page is then a Chrome-style
/// browser (extensions work) drawn by Chromium below the app's views, and this
/// view is a transparent placeholder whose frame and visibility it follows.
/// Otherwise (and for embeds, DevTools) it's an Alloy-style child browser.
/// Set before the view is shown.
@property(nonatomic) BOOL prefersChromeStyle;
/// The browser's cookies and storage (nil: the profile on disk). Set before
/// the view is shown.
@property(nonatomic, strong, nullable) GleaBrowsingSession* session;
/// With Chrome style, the borderless window the page is drawn in: a child
/// window of this view's window, kept over this view. Animate its alphaValue
/// to fade the page. Nil otherwise.
@property(nonatomic, readonly, nullable) NSWindow* chromeWindow;
/// Rounds all corners of `chromeWindow` (popups). 0: only where the page
/// meets the bottom corners of the window.
@property(nonatomic) CGFloat chromeCornerRadius;

/// Sent as the Referer of this browser's frame navigations. Some embeds
/// (YouTube) refuse to play without one. Set before the view is shown.
@property(nonatomic, copy, nullable) NSString* referrerOverride;
/// HTML answered, without a network request, for the navigation to the
/// view's initial URL: gives a generated page a real origin (embeds refuse
/// to be framed by a data: URL). Set before the view is shown.
@property(nonatomic, copy, nullable) NSString* servedHTML;
/// Color shown before the page paints. Set before the view is shown.
@property(nonatomic, strong, nullable) NSColor* pageBackgroundColor;
/// Asks Chromium for the page's preferred size between these bounds (see
/// `browserView:didAutoResizeToSize:`). Can be called before the browser exists.
- (void)enableAutoResizeWithMinSize:(NSSize)minSize maxSize:(NSSize)maxSize;

@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) double loadProgress;
@property(nonatomic, readonly) double zoomLevel;
/// Silences the page (kept for a browser created later).
@property(nonatomic) BOOL audioMuted;
/// Out of sight, the page keeps running (shown to Chromium, its window
/// transparent and click-through): it plays sound, which animation frames
/// and timers may drive.
@property(nonatomic) BOOL keepsRunningWhenHidden;
/// Out of sight and running now (its window is transparent: leave it so).
@property(nonatomic, readonly, getter=isKeptRunning) BOOL keptRunning;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)executeJavaScript:(NSString*)script;
- (void)focusPage;

- (void)findText:(NSString*)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding;

- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
/// Where DevTools open by default (remembered across launches).
@property(class, nonatomic) GleaDevToolsDock preferredDevToolsDock;

// Docked DevTools, laid out like Chrome: the app supplies a view (a DevTools
// frontend) that fills the whole browser view, underneath the page, and the
// page is placed over the area the frontend reserves for it.
@property(nonatomic, strong, nullable) NSView* dockedDevToolsView;
/// Where the page goes while DevTools are docked, in this view's (flipped)
/// coordinates, as reported by the frontend. Empty = the whole view.
@property(nonatomic) NSRect inspectedPageBounds;

// DevTools in a separate window (Chromium's own).
@property(nonatomic, readonly) BOOL isDetachedDevToolsOpen;
- (void)showDetachedDevToolsInspectingPoint:(NSPoint)point;
- (void)closeDetachedDevTools;

/// Sends a raw Chrome DevTools Protocol message to this page.
- (void)sendDevToolsMessage:(NSString*)json;
/// When YES, every protocol message from the page (results and events) is
/// passed to `browserView:didReceiveDevToolsMessage:`.
@property(nonatomic) BOOL forwardsDevToolsMessages;

/// Captures a region of the page as PNG. `rect` is in CSS pixels, in document
/// coordinates (viewport position plus scroll offset); an empty rect captures
/// the viewport as displayed, without re-rendering (no flash).
- (void)captureScreenshotOfPageRect:(NSRect)rect
                         completion:(void (^)(NSData* _Nullable png))completion;

/// Closes the browser. `browserViewDidClose:` is sent once it is gone.
- (void)close;

@end

NS_ASSUME_NONNULL_END
