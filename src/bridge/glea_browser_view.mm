#import "GleaBridge.h"
#import <objc/message.h>

#include <map>
#include <set>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_ids.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_panel.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "internal.h"

@interface GleaBrowserView ()
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserWillClose;
- (void)browserClosed;
- (void)setURLValue:(NSString*)url;
- (void)setTitleValue:(NSString*)title;
- (void)setLoading:(BOOL)loading canGoBack:(BOOL)back canGoForward:(BOOL)forward;
- (void)setProgressValue:(double)progress;
- (void)requestInspectAt:(CefPoint)point;
- (void)detachedDevToolsClosed;
- (void)devToolsMessageReceived:(NSString*)json;
@property(nonatomic, readonly) BOOL isChromeHosted;
/// The URL `servedHTML` answers (the initial one).
@property(nonatomic, readonly, copy) NSString* servedURL;
- (CefBrowserSettings)browserSettings;
- (void)updateChromePlacement;
@end



namespace {

NSString* ToNS(const CefString& s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}

CefString ToCef(NSString* s) {
  return CefString(s.UTF8String ?: "");
}

// Every live GleaBrowserView, so they can all be closed on quit.
NSHashTable<GleaBrowserView*>* LiveViews() {
  static NSHashTable* views = [NSHashTable weakObjectsHashTable];
  return views;
}

int g_live_browsers = 0;

// Browsers counted in g_live_browsers.
std::set<int>& CountedBrowsers() {
  static std::set<int> ids;
  return ids;
}

// Every browser's view, by browser identifier.
std::map<int, __weak GleaBrowserView*>& TabViews() {
  static std::map<int, __weak GleaBrowserView*> views;
  return views;
}

GleaBrowserView* TabView(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nil;
  auto it = TabViews().find(browser->GetIdentifier());
  return it == TabViews().end() ? nil : it->second;
}

// The tab view waiting for the browser a Chrome "new tab" command creates.

std::function<void()> g_on_all_closed;

enum MenuId {
  kMenuOpenLinkInNewTab = MENU_ID_USER_FIRST,
  kMenuCopyLink,
  kMenuCollectSelection,
  kMenuSearchSelection,
  kMenuCollectImage,
  kMenuOpenImageInNewTab,
  kMenuCollectPage,
  kMenuInspect,
};

bool ForwardMenuShortcut(const CefKeyEvent& event, CefEventHandle os_event);

bool IsNewTabDisposition(cef_window_open_disposition_t d) {
  return d == CEF_WOD_NEW_FOREGROUND_TAB || d == CEF_WOD_NEW_BACKGROUND_TAB ||
         d == CEF_WOD_NEW_WINDOW || d == CEF_WOD_NEW_POPUP;
}

// Receives all browser events for one GleaBrowserView. Runs on the UI thread,
// which on macOS is the main thread.
class BrowserClient : public CefClient,
                      public CefContextMenuHandler,
                      public CefDisplayHandler,
                      public CefDownloadHandler,
                      public CefFindHandler,
                      public CefKeyboardHandler,
                      public CefLifeSpanHandler,
                      public CefLoadHandler,
                      public CefRequestHandler,
                      public CefResourceRequestHandler,
                      public CefCommandHandler,
                      public CefPermissionHandler {
 public:
  explicit BrowserClient(GleaBrowserView* view) : owner_(view) {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  // CefCommandHandler (Chrome style): Chrome's own commands (new window,
  // bookmarks, its find bar...) have Glea equivalents in the main menu, which
  // gets Command shortcuts first (OnPreKeyEvent). Never run Chrome's.
  bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id,
                       cef_window_open_disposition_t disposition) override {
    // Chrome matches its keyboard shortcuts before Glea's menu sees them
    // (⌥⌘→ is Chrome's "next tab" too): hand the key to Glea's menu instead.
    NSEvent* event = NSApp.currentEvent;
    if (event.type == NSEventTypeKeyDown) [[NSApp mainMenu] performKeyEquivalent:event];
    return true;
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() != glea::kPostMessageName) return false;
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (args->GetSize() < 2) return true;
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:didReceiveMessage:payload:)]) {
      [view.delegate browserView:view
               didReceiveMessage:ToNS(args->GetString(0))
                         payload:ToNS(args->GetString(1))];
    }
    return true;
  }

  // CefLifeSpanHandler

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (browser->IsPopup()) return;  // DevTools windows.
    GleaBrowserView* view = owner_;
    if (!view) return;
    TabViews()[browser->GetIdentifier()] = view;
    CountedBrowsers().insert(browser->GetIdentifier());
    ++g_live_browsers;
    [view browserCreated:browser];
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    // DevTools' own helper pages (device mode frame...) are never tabs.
    if (target_url.ToString().rfind("devtools://", 0) == 0) return true;
    // Every popup becomes a tab in our own tab strip.
    RequestNewTab(browser, ToNS(target_url), target_disposition == CEF_WOD_NEW_BACKGROUND_TAB);
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    if (browser->IsPopup()) return false;
    // A Chrome-style tab: returning false closes its own (borderless) window,
    // which destroys the browser.
    if ([View(browser) isChromeHosted]) return false;
    // Tear down the view hierarchy ourselves; the browser is destroyed along
    // with its host view, which triggers OnBeforeClose().
    [View(browser) browserWillClose];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (browser->IsPopup()) return;
    GleaBrowserView* view = TabView(browser);
    TabViews().erase(browser->GetIdentifier());
    [view browserClosed];
    // Counted when created, whether or not its view is still around.
    if (!CountedBrowsers().erase(browser->GetIdentifier())) return;
    if (--g_live_browsers == 0 && g_on_all_closed) {
      auto callback = std::move(g_on_all_closed);
      g_on_all_closed = nullptr;
      callback();
    }
  }

  // CefDisplayHandler

  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool has_video_access, bool has_audio_access) override {
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:didChangeMediaAccessCamera:microphone:)]) {
      [view.delegate browserView:view didChangeMediaAccessCamera:has_video_access microphone:has_audio_access];
    }
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) return;
    [View(browser) setURLValue:ToNS(url)];
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:didCommitNavigationToURL:)]) {
      [view.delegate browserView:view didCommitNavigationToURL:ToNS(url)];
    }
  }

  bool OnAutoResize(CefRefPtr<CefBrowser> browser, const CefSize& new_size) override {
    GleaBrowserView* view = View(browser);
    if (![view.delegate respondsToSelector:@selector(browserView:didAutoResizeToSize:)]) return false;
    [view.delegate browserView:view didAutoResizeToSize:NSMakeSize(new_size.width, new_size.height)];
    return true;
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    [View(browser) setTitleValue:ToNS(title)];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    GleaBrowserView* view = View(browser);
    if (icon_urls.empty() ||
        ![view.delegate respondsToSelector:@selector(browserView:didChangeFaviconURLs:)]) {
      return;
    }
    NSMutableArray<NSString*>* urls = [NSMutableArray array];
    for (const auto& url : icon_urls) [urls addObject:ToNS(url)];
    [view.delegate browserView:view didChangeFaviconURLs:urls];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    [View(browser) setProgressValue:progress];
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [View(browser) setLoading:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (!frame->IsMain() || errorCode == ERR_ABORTED) return;
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:didFailLoadWithError:url:)]) {
      [view.delegate browserView:view
            didFailLoadWithError:ToNS(errorText)
                             url:ToNS(failedUrl)];
    }
  }

  // CefRequestHandler

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    if (!frame->IsMain() || is_redirect) return false;
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:shouldNavigateToURL:userGesture:)]) {
      return ![view.delegate browserView:view shouldNavigateToURL:ToNS(request->GetURL()) userGesture:user_gesture];
    }
    return false;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    // Cmd-click and middle-click on links.
    if (!IsNewTabDisposition(target_disposition)) return false;
    RequestNewTab(browser, ToNS(target_url), target_disposition == CEF_WOD_NEW_BACKGROUND_TAB);
    return true;
  }

  // Referrer override for frame navigations (see GleaBrowserView).

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    GleaBrowserView* view = View(browser);
    if (!is_navigation) return nullptr;
    return view.referrerOverride.length || view.servedHTML ? this : nullptr;
  }

  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override {
    // A generated page answered locally, at a real https URL.
    GleaBrowserView* view = View(browser);
    NSString* html = view.servedHTML;
    if (!html || !frame->IsMain() || ![ToNS(request->GetURL()) isEqualToString:view.servedURL]) return nullptr;
    NSData* data = [html dataUsingEncoding:NSUTF8StringEncoding];
    return new CefStreamResourceHandler(
        "text/html", CefStreamReader::CreateForData(const_cast<void*>(data.bytes), data.length));
  }

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    GleaBrowserView* view = View(browser);
    if (view.referrerOverride.length && request->GetReferrerURL().empty()) {
      request->SetReferrer(ToCef(view.referrerOverride), REFERRER_POLICY_NEVER_CLEAR_REFERRER);
    }
    return RV_CONTINUE;
  }

  // CefKeyboardHandler

  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent& event,
                     CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override {
    // Give the main menu first pick at Command shortcuts so tab, omnibox and
    // journal commands work while a page has focus.
    return ForwardMenuShortcut(event, os_event);
  }

  // CefContextMenuHandler

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    std::vector<std::pair<int, std::string>> top;
    const int flags = params->GetTypeFlags();
    if (flags & CM_TYPEFLAG_LINK) {
      top.push_back({kMenuOpenLinkInNewTab, "Open Link in New Tab"});
      top.push_back({kMenuCopyLink, "Copy Link Address"});
    }
    if (flags & CM_TYPEFLAG_SELECTION) {
      top.push_back({kMenuCollectSelection, "Collect Selection…"});
      std::string text = params->GetSelectionText().ToString();
      if (text.size() > 24) text = text.substr(0, 24) + "…";
      top.push_back({kMenuSearchSelection, "Search for “" + text + "”"});
    }
    if (params->GetMediaType() == CM_MEDIATYPE_IMAGE && params->HasImageContents()) {
      top.push_back({kMenuCollectImage, "Collect Image…"});
      top.push_back({kMenuOpenImageInNewTab, "Open Image in New Tab"});
    }
    if (!top.empty()) {
      model->InsertSeparatorAt(0);
      for (auto it = top.rbegin(); it != top.rend(); ++it) {
        model->InsertItemAt(0, it->first, it->second);
      }
    }
    if (model->GetCount() > 0) model->AddSeparator();
    model->AddItem(kMenuCollectPage, "Collect Page…");
    model->AddItem(kMenuInspect, "Inspect Element");
  }

  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override {
    switch (command_id) {
      case kMenuOpenLinkInNewTab:
        SendContextCommand(browser, GleaContextCommandOpenLinkInNewTab, params->GetLinkUrl());
        return true;
      case kMenuCopyLink:
        SendContextCommand(browser, GleaContextCommandCopyLink, params->GetLinkUrl());
        return true;
      case kMenuCollectSelection:
        SendContextCommand(browser, GleaContextCommandCollectSelection, params->GetSelectionText());
        return true;
      case kMenuSearchSelection:
        SendContextCommand(browser, GleaContextCommandSearchSelection, params->GetSelectionText());
        return true;
      case kMenuCollectImage:
        SendContextCommand(browser, GleaContextCommandCollectImage, params->GetSourceUrl());
        return true;
      case kMenuOpenImageInNewTab:
        SendContextCommand(browser, GleaContextCommandOpenImageInNewTab, params->GetSourceUrl());
        return true;
      case kMenuCollectPage:
        SendContextCommand(browser, GleaContextCommandCollectPage, params->GetPageUrl());
        return true;
      case kMenuInspect:
        [View(browser) requestInspectAt:CefPoint(params->GetXCoord(), params->GetYCoord())];
        return true;
    }
    return false;
  }

  // CefDownloadHandler

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString* downloads = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory,
                                                               NSUserDomainMask, YES) firstObject];
    NSString* name = ToNS(suggested_name);
    if (name.length == 0) name = @"download";
    NSString* path = [downloads stringByAppendingPathComponent:name];
    // Avoid overwriting: "file.zip" -> "file 2.zip".
    NSString* base = [name stringByDeletingPathExtension];
    NSString* ext = [name pathExtension];
    for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; ++i) {
      NSString* candidate = [NSString stringWithFormat:@"%@ %d", base, i];
      if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
      path = [downloads stringByAppendingPathComponent:candidate];
    }
    callback->Continue(ToCef(path), false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!download_item->IsComplete()) return;
    NSString* path = ToNS(download_item->GetFullPath());
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"com.apple.DownloadFileFinished"
                      object:path];
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:didFinishDownloadAtPath:)]) {
      [view.delegate browserView:view didFinishDownloadAtPath:path];
    }
  }

  // CefPermissionHandler
  //
  // Chrome's own permission prompts would draw in the Chromium window below
  // the app's views, out of sight: the app asks for the camera and
  // microphone instead.

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    const uint32_t devices = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    // Only the camera and microphone (screen sharing keeps the default).
    if (requested_permissions == 0 || (requested_permissions & ~devices) != 0) return false;
    bool asked = AskMediaAccess(browser, requesting_origin,
                                requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE,
                                requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE, ^(BOOL allowed) {
      if (allowed) {
        callback->Continue(requested_permissions);
      } else {
        callback->Cancel();
      }
    });
    return asked;
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t prompt_id,
                              const CefString& requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    const uint32_t streams = CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM;
    if (requested_permissions == 0 || (requested_permissions & ~streams) != 0) return false;
    return AskMediaAccess(browser, requesting_origin,
                          requested_permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM,
                          requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM, ^(BOOL allowed) {
      callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    });
  }

  /// Asks the view's delegate; false if it doesn't handle it.
  bool AskMediaAccess(CefRefPtr<CefBrowser> browser, const CefString& origin, bool camera, bool microphone,
                      void (^completion)(BOOL allowed)) {
    GleaBrowserView* view = View(browser);
    SEL selector = @selector(browserView:requestsMediaAccessForOrigin:camera:microphone:completion:);
    if (![view.delegate respondsToSelector:selector]) return false;
    [view.delegate browserView:view
        requestsMediaAccessForOrigin:ToNS(origin)
                              camera:camera
                          microphone:microphone
                          completion:completion];
    return true;
  }

  // CefFindHandler

  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:findResultCount:activeMatch:)]) {
      [view.delegate browserView:view findResultCount:count activeMatch:activeMatchOrdinal];
    }
  }

 private:
  void RequestNewTab(CefRefPtr<CefBrowser> browser, NSString* url, BOOL background) {
    GleaBrowserView* view = View(browser);
    if ([view.delegate respondsToSelector:@selector(browserView:requestsNewTabWithURL:background:)]) {
      [view.delegate browserView:view requestsNewTabWithURL:url background:background];
    }
  }

  void SendContextCommand(CefRefPtr<CefBrowser> browser, GleaContextCommand command, const CefString& argument) {
    GleaBrowserView* view = View(browser);
    NSString* arg = ToNS(argument);
    // Defer so the menu is fully dismissed before any UI is shown.
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([view.delegate respondsToSelector:@selector(browserView:contextCommand:argument:)]) {
        [view.delegate browserView:view contextCommand:command argument:arg];
      }
    });
  }

  // The view that created this client. Chrome-style tabs opened in the same
  // window share one client, so events are routed by browser (TabView()).
  __weak GleaBrowserView* owner_;

  GleaBrowserView* View(CefRefPtr<CefBrowser> browser) {
    if (GleaBrowserView* view = TabView(browser)) return view;
    return owner_;
  }

  IMPLEMENT_REFCOUNTING(BrowserClient);
};

bool ForwardMenuShortcut(const CefKeyEvent& event, CefEventHandle os_event) {
  NSEvent* ns_event = (__bridge NSEvent*)os_event;
  if (event.type != KEYEVENT_RAWKEYDOWN || !ns_event) return false;
  if (!(ns_event.modifierFlags & NSEventModifierFlagCommand)) return false;
  return [[NSApp mainMenu] performKeyEquivalent:ns_event];
}

// Tabs in Chrome-hosted windows: Chrome style, without Chrome's toolbar.
class ChromeViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }

 private:
  IMPLEMENT_REFCOUNTING(ChromeViewDelegate);
};

// Chromium's DevTools in their own window.
class DevToolsClient : public CefClient, public CefLifeSpanHandler {
 public:
  explicit DevToolsClient(GleaBrowserView* view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    GleaBrowserView* view = view_;
    dispatch_async(dispatch_get_main_queue(), ^{ [view detachedDevToolsClosed]; });
  }

 private:
  __weak GleaBrowserView* view_;

  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

// Receives DevTools method results (used for screenshots).
class DevToolsObserver : public CefDevToolsMessageObserver {
 public:
  using Callback = void (^)(NSData*);

  DevToolsObserver() = default;
  explicit DevToolsObserver(GleaBrowserView* view) : view_(view) {}

  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message, size_t message_size) override {
    GleaBrowserView* view = view_;
    if (view) {
      NSString* json = [[NSString alloc] initWithBytes:message length:message_size encoding:NSUTF8StringEncoding];
      if (json) [view devToolsMessageReceived:json];
    }
    return false;  // Still deliver method results to OnDevToolsMethodResult.
  }

  void Expect(int message_id, Callback callback) { callbacks_[message_id] = [callback copy]; }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override {
    auto it = callbacks_.find(message_id);
    if (it == callbacks_.end()) return;
    Callback callback = it->second;
    callbacks_.erase(it);
    NSData* png = nil;
    if (success) {
      CefRefPtr<CefValue> value = CefParseJSON(result, result_size, JSON_PARSER_RFC);
      if (value && value->GetType() == VTYPE_DICTIONARY) {
        std::string data = value->GetDictionary()->GetString("data").ToString();
        png = [[NSData alloc] initWithBase64EncodedString:@(data.c_str()) options:0];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ callback(png); });
  }

 private:
  std::map<int, Callback> callbacks_;
  __weak GleaBrowserView* view_ = nil;

  IMPLEMENT_REFCOUNTING(DevToolsObserver);
};

}  // namespace

namespace glea {

int LiveBrowserCount() {
  return g_live_browsers;
}

void CloseAllBrowsers(std::function<void()> on_all_closed) {
  if (g_live_browsers == 0) {
    on_all_closed();
    return;
  }
  g_on_all_closed = std::move(on_all_closed);
  for (GleaBrowserView* view in LiveViews().allObjects) {
    [view close];
  }
}

}  // namespace glea

@implementation GleaBrowsingSession {
 @public
  CefRefPtr<CefRequestContext> _context;
}

+ (instancetype)incognitoSession {
  GleaBrowsingSession* session = [super new];
  // No cache path: Chromium keeps this context's storage in memory only.
  CefRequestContextSettings settings;
  session->_context = CefRequestContext::CreateContext(settings, nullptr);
  return session;
}

@end

@implementation GleaBrowserView {
  CefRefPtr<CefBrowser> _browser;
  BOOL _autoResize;
  NSSize _autoResizeMin;
  NSSize _autoResizeMax;
  CefRefPtr<BrowserClient> _client;
  CefRefPtr<DevToolsObserver> _devToolsObserver;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSView* _pageContainer;
  // Strong reference to self while a browser exists: Chromium closes
  // asynchronously and still uses this view (its parent) until
  // OnBeforeClose, so the view must outlive its browser.
  GleaBrowserView* _keepAlive;
  NSView* _devToolsPane;
  NSView* _devToolsHost;
  NSString* _contentScript;
  NSString* _pendingURL;
  BOOL _creating;
  BOOL _closeRequested;
  BOOL _closed;
  // Chrome style: Chromium allows one Chrome-style browser per window, so
  // each such view gets a borderless Chromium window of its own, attached to
  // this view's window and kept over this view (the page area).
  GleaBrowserWindow* _chromeWindow;
  CefRefPtr<CefBrowserView> _chromeView;
  BOOL _chromeWindowShown;
  // Hidden from view but running (keepsRunningWhenHidden).
  BOOL _keptRunning;
}

- (instancetype)initWithURL:(NSString*)url contentScript:(NSString*)contentScript {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) {
    _url = [url copy];
    _title = @"";
    _pendingURL = [url copy];
    _servedURL = [url copy];
    _contentScript = [contentScript copy];
    self.wantsLayer = YES;
    _pageContainer = [[NSView alloc] initWithFrame:self.bounds];
    [self addSubview:_pageContainer];
    [self buildDevToolsPane];
    [LiveViews() addObject:self];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !_creating && !_browser && !_closed) [self createBrowser];
  [self updateChromePlacement];
}

- (BOOL)isChromeHosted {
  return _chromeWindow != nil;
}

- (NSWindow*)chromeWindow {
  return _chromeWindow.window;
}

- (void)createBrowser {
  _creating = YES;
  _keepAlive = self;
  _client = new BrowserClient(self);
  if (self.prefersChromeStyle) {
    if (glea::UsesChromeTabs()) {
      [self createChromeBrowser];
      return;
    }
  }

  NSRect bounds = self.bounds;
  CefWindowInfo window_info;
  window_info.SetAsChild((__bridge void*)_pageContainer,
                         CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));

  CefBrowserSettings settings = [self browserSettings];

  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  // Always set (even empty): browsers without an entry get the tab script.
  extra->SetString(glea::kContentScriptKey, ToCef(_contentScript ?: @""));

  NSString* url = _pendingURL ?: @"about:blank";
  _pendingURL = nil;
  CefBrowserHost::CreateBrowser(window_info, _client, ToCef(url), settings, extra, [self requestContext]);
}

- (CefRefPtr<CefRequestContext>)requestContext {
  return _session ? _session->_context : nullptr;
}

- (CefBrowserSettings)browserSettings {
  CefBrowserSettings settings;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  if (NSColor* color = [self.pageBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace]) {
    settings.background_color = CefColorSetARGB(255, (int)(color.redComponent * 255), (int)(color.greenComponent * 255),
                                                (int)(color.blueComponent * 255));
  }
  return settings;
}

- (void)createChromeBrowser {
  _chromeWindow = [[GleaBrowserWindow alloc] initPanelWithContentRect:[self chromeWindowFrame]];
  NSWindow* window = _chromeWindow.window;
  window.releasedWhenClosed = NO;
  window.backgroundColor = NSColor.clearColor;
  window.opaque = NO;
  window.hasShadow = NO;
  window.contentView.wantsLayer = YES;
  _chromeWindow.backgroundColor = self.pageBackgroundColor ?: NSColor.whiteColor;
  CefRefPtr<CefWindow> cef = glea::ChromeWindowFor(window);
  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  extra->SetString(glea::kContentScriptKey, ToCef(_contentScript ?: @""));
  NSString* url = _pendingURL ?: @"about:blank";
  _pendingURL = nil;
  _chromeView = CefBrowserView::CreateBrowserView(_client, ToCef(url), [self browserSettings], extra, [self requestContext],
                                                  new ChromeViewDelegate);
  cef->AddChildView(_chromeView);
  // Chromium shows new windows itself; ours appear only over a visible view.
  [window orderOut:nil];
  _chromeWindowShown = NO;
  [self updateChromePlacement];
}

/// The width of the Glea window's border, left visible around the page.
static const CGFloat kChromeWindowBorderInset = 1;

/// The page area (this view, or the part docked DevTools leave), on screen.
- (NSRect)chromeWindowFrame {
  NSRect page = self.bounds;
  if (_dockedDevToolsView) {
    NSRect reserved = NSIntersectionRect(_inspectedPageBounds, self.bounds);
    if (!NSIsEmptyRect(reserved)) page = reserved;
  }
  NSWindow* parent = self.window;
  if (!parent) return NSMakeRect(0, 0, 800, 600);
  NSRect frame = [parent convertRectToScreen:[self convertRect:page toView:nil]];
  // Stay inside the Glea window's hairline border: a child window draws
  // over it.
  if (_chromeCornerRadius <= 0 && !(parent.styleMask & NSWindowStyleMaskFullScreen)) {
    frame = NSIntersectionRect(frame, NSInsetRect(parent.frame, kChromeWindowBorderInset, kChromeWindowBorderInset));
  }
  return frame;
}

/// Keeps the browser's window over this view, shown only while it's visible.
- (void)updateChromePlacement {
  if (!_chromeWindow) return;
  NSWindow* window = _chromeWindow.window;
  NSWindow* parent = self.window;
  BOOL visible = parent && !self.isHiddenOrHasHiddenAncestor && !_closeRequested && parent.isVisible;
  if (visible) {
    NSRect frame = [self chromeWindowFrame];
    if (!NSEqualRects(frame, window.frame)) [window setFrame:frame display:YES];
    [self roundChromeWindowCorners];
    if (window.parentWindow != parent) {
      [window.parentWindow removeChildWindow:window];
      [parent addChildWindow:window ordered:NSWindowAbove];
    }
    if (_keptRunning) {
      // Back from running out of sight: seen and clickable again.
      _keptRunning = NO;
      window.alphaValue = 1;
      window.ignoresMouseEvents = NO;
    }
    if (!_chromeWindowShown) {
      _chromeWindowShown = YES;
      [window orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
      if (_browser) _browser->GetHost()->WasHidden(false);
      [[NSNotificationCenter defaultCenter] postNotificationName:@"GleaChromeWindowShown" object:parent];
    }
  } else if (_keepsRunningWhenHidden && _chromeWindowShown && parent && parent.isVisible && !_closeRequested) {
    // Out of sight but still running: the window stays (Chromium would
    // otherwise stop the page), transparent and click-through.
    _keptRunning = YES;
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
  } else {
    if (_keptRunning) {
      _keptRunning = NO;
      window.alphaValue = 1;
      window.ignoresMouseEvents = NO;
    }
    if (_chromeWindowShown && _browser) _browser->GetHost()->WasHidden(true);
    _chromeWindowShown = NO;
    if (window.isVisible) [window orderOut:nil];
  }
}

/// Where the page meets the bottom of the (rounded) window, round it too.
/// The mask goes on the window's frame view: its layer is the root of the
/// window's layer tree, so it isn't flipped (Chromium's content view is).
- (void)roundChromeWindowCorners {
  NSWindow* parent = self.window;
  NSView* frameView = _chromeWindow.window.contentView.superview;
  if (!parent || !frameView) return;
  frameView.wantsLayer = YES;
  CALayer* layer = frameView.layer;
  BOOL atBottom = NSMinY(_chromeWindow.window.frame) <= NSMinY(parent.frame) + kChromeWindowBorderInset + 1 &&
                  !(parent.styleMask & NSWindowStyleMaskFullScreen);
  // The Glea window's own corner radius (larger on recent macOS).
  CGFloat windowRadius = 10;
  SEL cornerRadius = NSSelectorFromString(@"_cornerRadius");
  if ([parent respondsToSelector:cornerRadius]) {
    CGFloat value = ((CGFloat(*)(id, SEL))objc_msgSend)(parent, cornerRadius);
    if (value > 0) windowRadius = value;
  }
  CGFloat radius = _chromeCornerRadius > 0 ? _chromeCornerRadius : (atBottom ? windowRadius - kChromeWindowBorderInset : 0);
  CACornerMask all = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
  CACornerMask bottom = layer.geometryFlipped ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
                                              : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
  CACornerMask corners = _chromeCornerRadius > 0 ? all : bottom;
  if (layer.cornerRadius != radius || layer.maskedCorners != corners) {
    layer.cornerRadius = radius;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.maskedCorners = corners;
    layer.masksToBounds = radius > 0;
  }
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self updateChromePlacement];
}

- (void)setFrameOrigin:(NSPoint)newOrigin {
  [super setFrameOrigin:newOrigin];
  [self updateChromePlacement];
}

- (void)viewDidHide {
  [super viewDidHide];
  [self updateChromePlacement];
}

- (void)viewDidUnhide {
  [super viewDidUnhide];
  [self updateChromePlacement];
}

/// A Chrome-style page is drawn below the app's views: let clicks through to
/// it, except on a docked DevTools pane.
- (NSView*)hitTest:(NSPoint)point {
  NSView* hit = [super hitTest:point];
  if (_chromeWindow && (hit == self || hit == _pageContainer)) return nil;
  return hit;
}

- (void)enableAutoResizeWithMinSize:(NSSize)minSize maxSize:(NSSize)maxSize {
  _autoResize = YES;
  _autoResizeMin = minSize;
  _autoResizeMax = maxSize;
  if (_browser) {
    _browser->GetHost()->SetAutoResizeEnabled(true, CefSize((int)minSize.width, (int)minSize.height),
                                              CefSize((int)maxSize.width, (int)maxSize.height));
  }
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  _creating = NO;
  if (_audioMuted) _browser->GetHost()->SetAudioMuted(true);
  if (_autoResize) [self enableAutoResizeWithMinSize:_autoResizeMin maxSize:_autoResizeMax];
  if (_closeRequested) {
    _browser->GetHost()->CloseBrowser(true);
    return;
  }
  if (_pendingURL) {
    [self loadURL:_pendingURL];
    _pendingURL = nil;
  }
  [self layoutBrowserView];
  if (_chromeWindow) {
    if (!_chromeWindowShown) [_chromeWindow.window orderOut:nil];
    [self updateChromePlacement];
    _browser->GetHost()->WasHidden(!_chromeWindowShown);
  } else if (self.hidden) {
    _browser->GetHost()->WasHidden(true);
  }
}

- (NSView*)hostView {
  if (!_browser || _chromeWindow) return nil;
  return (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
}

- (void)layoutBrowserView {
  NSRect bounds = self.bounds;
  NSRect page = bounds;
  if (_dockedDevToolsView) {
    _devToolsPane.frame = bounds;
    [self layoutDevToolsPane];
    NSRect reserved = NSIntersectionRect(_inspectedPageBounds, bounds);
    if (!NSIsEmptyRect(reserved)) page = reserved;
    if (_chromeWindow) {
      // The page is drawn by Chromium below this view: show only the part of
      // the frontend outside the page area (it reserves that area for it).
      NSRect pane = bounds;
      if (NSMinX(page) > NSMinX(bounds) + 1) pane = NSMakeRect(NSMinX(bounds), NSMinY(bounds), NSMinX(page) - NSMinX(bounds), NSHeight(bounds));
      else if (NSMaxX(page) < NSMaxX(bounds) - 1) pane = NSMakeRect(NSMaxX(page), NSMinY(bounds), NSMaxX(bounds) - NSMaxX(page), NSHeight(bounds));
      else if (NSMaxY(page) < NSMaxY(bounds) - 1) pane = NSMakeRect(NSMinX(bounds), NSMaxY(page), NSWidth(bounds), NSMaxY(bounds) - NSMaxY(page));
      else if (NSMinY(page) > NSMinY(bounds) + 1) pane = NSMakeRect(NSMinX(bounds), NSMinY(bounds), NSWidth(bounds), NSMinY(page) - NSMinY(bounds));
      _devToolsPane.frame = pane;
      _devToolsPane.wantsLayer = YES;
      _devToolsPane.layer.masksToBounds = YES;
      _devToolsHost.frame = NSOffsetRect(bounds, -NSMinX(pane), -NSMinY(pane));
      _dockedDevToolsView.frame = _devToolsHost.bounds;
    }
  }
  [self updateChromePlacement];
  _pageContainer.frame = page;
  NSView* host = [self hostView];
  if (host) host.frame = _pageContainer.bounds;
}

- (void)layout {
  [super layout];
  [self layoutBrowserView];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutBrowserView];
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  if (_browser) _browser->GetHost()->WasHidden(hidden);
}

#pragma mark - State updates from the client

- (void)notifyStateChange {
  if ([self.delegate respondsToSelector:@selector(browserViewDidChangeState:)]) {
    [self.delegate browserViewDidChangeState:self];
  }
}

- (void)setURLValue:(NSString*)url {
  _url = [url copy];
  [self notifyStateChange];
}

- (void)setTitleValue:(NSString*)title {
  _title = [title copy];
  [self notifyStateChange];
}

- (void)setLoading:(BOOL)loading canGoBack:(BOOL)back canGoForward:(BOOL)forward {
  _isLoading = loading;
  _canGoBack = back;
  _canGoForward = forward;
  [self notifyStateChange];
}

- (void)setProgressValue:(double)progress {
  _loadProgress = progress;
  [self notifyStateChange];
}

- (void)browserWillClose {
  // Removing the host view destroys the browser (see DoClose()).
  [[self hostView] removeFromSuperview];
}

- (void)browserClosed {
  // Let go of ourselves on the next turn, after CEF is done with us.
  GleaBrowserView* keep = _keepAlive;
  _keepAlive = nil;
  dispatch_async(dispatch_get_main_queue(), ^{ (void)keep; });
  _devToolsRegistration = nullptr;
  _devToolsObserver = nullptr;
  _browser = nullptr;
  _closed = YES;
  if (_chromeWindow) {
    NSWindow* window = _chromeWindow.window;
    [window.parentWindow removeChildWindow:window];
    [window orderOut:nil];
    _chromeView = nullptr;
    _chromeWindow = nil;
  }
  [LiveViews() removeObject:self];
  if ([self.delegate respondsToSelector:@selector(browserViewDidClose:)]) {
    [self.delegate browserViewDidClose:self];
  }
}

#pragma mark - Commands

- (void)loadURL:(NSString*)url {
  if (!_browser) {
    _pendingURL = [url copy];
    return;
  }
  _browser->GetMainFrame()->LoadURL(ToCef(url));
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}

- (void)goForward {
  if (_browser) _browser->GoForward();
}

- (void)reload {
  if (_browser) _browser->Reload();
}

- (void)stopLoading {
  if (_browser) _browser->StopLoad();
}

- (void)executeJavaScript:(NSString*)script {
  if (!_browser) return;
  CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
  frame->ExecuteJavaScript(ToCef(script), frame->GetURL(), 0);
}

- (void)focusPage {
  if (!_browser) return;
  if (_chromeWindow) {
    [_chromeWindow.window makeKeyWindow];
    _chromeView->RequestFocus();
    _browser->GetHost()->SetFocus(true);
    return;
  }
  NSView* host = [self hostView];
  if (host) [self.window makeFirstResponder:host];
  _browser->GetHost()->SetFocus(true);
}

- (void)findText:(NSString*)text forward:(BOOL)forward findNext:(BOOL)findNext {
  if (_browser) _browser->GetHost()->Find(ToCef(text), forward, false, findNext);
}

- (void)stopFinding {
  if (_browser) _browser->GetHost()->StopFinding(true);
}

- (double)zoomLevel {
  return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setKeepsRunningWhenHidden:(BOOL)keepsRunning {
  if (keepsRunning == _keepsRunningWhenHidden) return;
  _keepsRunningWhenHidden = keepsRunning;
  [self updateChromePlacement];
}

- (BOOL)isKeptRunning {
  return _keptRunning;
}

- (void)setAudioMuted:(BOOL)audioMuted {
  _audioMuted = audioMuted;
  if (_browser) _browser->GetHost()->SetAudioMuted(audioMuted);
}

- (void)zoomIn {
  if (_browser) _browser->GetHost()->SetZoomLevel(MIN(self.zoomLevel + 0.5, 5));
}

- (void)zoomOut {
  if (_browser) _browser->GetHost()->SetZoomLevel(MAX(self.zoomLevel - 0.5, -5));
}

- (void)resetZoom {
  if (_browser) _browser->GetHost()->SetZoomLevel(0);
}

#pragma mark - DevTools

static NSString* const kDockKey = @"GleaDevToolsDock";

+ (GleaDevToolsDock)preferredDevToolsDock {
  return (GleaDevToolsDock)[[NSUserDefaults standardUserDefaults] integerForKey:kDockKey];
}

+ (void)setPreferredDevToolsDock:(GleaDevToolsDock)dock {
  [[NSUserDefaults standardUserDefaults] setInteger:dock forKey:kDockKey];
}

// MARK: Protocol relay

- (void)ensureDevToolsObserver {
  if (_devToolsObserver || !_browser) return;
  _devToolsObserver = new DevToolsObserver(self);
  _devToolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_devToolsObserver);
}

- (void)sendDevToolsMessage:(NSString*)json {
  if (!_browser) return;
  [self ensureDevToolsObserver];
  NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
  _browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
}

- (void)setForwardsDevToolsMessages:(BOOL)forwards {
  _forwardsDevToolsMessages = forwards;
  if (forwards) [self ensureDevToolsObserver];
}

- (void)devToolsMessageReceived:(NSString*)json {
  if (!_forwardsDevToolsMessages) return;
  if ([self.delegate respondsToSelector:@selector(browserView:didReceiveDevToolsMessage:)]) {
    [self.delegate browserView:self didReceiveDevToolsMessage:json];
  }
}

// MARK: Separate window (Chromium's DevTools)

- (BOOL)isDetachedDevToolsOpen {
  return _browser && _browser->GetHost()->HasDevTools();
}

- (void)showDetachedDevToolsInspectingPoint:(NSPoint)point {
  if (!_browser) return;
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  _browser->GetHost()->ShowDevTools(info, new DevToolsClient(self), CefBrowserSettings(),
                                    CefPoint((int)point.x, (int)point.y));
  [self notifyDevToolsChange];
}

- (void)closeDetachedDevTools {
  if (self.isDetachedDevToolsOpen) _browser->GetHost()->CloseDevTools();
}

- (void)detachedDevToolsClosed {
  [self notifyDevToolsChange];
}

- (void)notifyDevToolsChange {
  if ([self.delegate respondsToSelector:@selector(browserViewDidChangeDevTools:)]) {
    [self.delegate browserViewDidChangeDevTools:self];
  }
}

- (void)requestInspectAt:(CefPoint)point {
  if ([self.delegate respondsToSelector:@selector(browserView:requestsInspectElementAt:)]) {
    [self.delegate browserView:self requestsInspectElementAt:NSMakePoint(point.x, point.y)];
  } else {
    [self showDetachedDevToolsInspectingPoint:NSMakePoint(point.x, point.y)];
  }
}

// MARK: Docked pane


- (void)setDockedDevToolsView:(NSView*)view {
  if (view == _dockedDevToolsView) return;
  [_dockedDevToolsView removeFromSuperview];
  _dockedDevToolsView = view;
  _inspectedPageBounds = NSZeroRect;
  if (view) {
    [_devToolsHost addSubview:view];
    _devToolsPane.hidden = NO;
  } else {
    _devToolsPane.hidden = YES;
  }
  [self layoutBrowserView];
  [self notifyDevToolsChange];
}

- (void)setInspectedPageBounds:(NSRect)bounds {
  if (NSEqualRects(bounds, _inspectedPageBounds)) return;
  _inspectedPageBounds = bounds;
  [self layoutBrowserView];
}

- (void)buildDevToolsPane {
  _devToolsPane = [[NSView alloc] initWithFrame:NSZeroRect];
  _devToolsPane.hidden = YES;
  _devToolsHost = [[NSView alloc] initWithFrame:NSZeroRect];
  [_devToolsPane addSubview:_devToolsHost];
  // Below the page, which is laid over the frontend's placeholder.
  [self addSubview:_devToolsPane positioned:NSWindowBelow relativeTo:_pageContainer];
}

- (void)layoutDevToolsPane {
  _devToolsHost.frame = _devToolsPane.bounds;
  _dockedDevToolsView.frame = _devToolsHost.bounds;
}


- (void)captureScreenshotOfPageRect:(NSRect)rect completion:(void (^)(NSData*))completion {
  if (!_browser) {
    completion(nil);
    return;
  }
  [self ensureDevToolsObserver];
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  // An empty rect captures the viewport as displayed. A clip makes Chromium
  // re-render the page at the clip's scale, which flashes on screen.
  if (!NSIsEmptyRect(rect)) {
    CefRefPtr<CefDictionaryValue> clip = CefDictionaryValue::Create();
    clip->SetDouble("x", rect.origin.x);
    clip->SetDouble("y", rect.origin.y);
    clip->SetDouble("width", rect.size.width);
    clip->SetDouble("height", rect.size.height);
    clip->SetDouble("scale", self.window.backingScaleFactor ?: 2);
    params->SetDictionary("clip", clip);
  }
  int messageId = _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
  if (messageId == 0) {
    completion(nil);
    return;
  }
  _devToolsObserver->Expect(messageId, completion);
}

- (void)close {
  if (_closed || _closeRequested) return;
  _closeRequested = YES;
  // Out of sight now: Chromium paints its window white while it tears the
  // page down, which flashed over whatever the tab left showing.
  [self updateChromePlacement];
  if (_browser) {
    [self closeDetachedDevTools];
    _browser->GetHost()->CloseBrowser(true);
  } else if (!_creating) {
    // Never attached to a window, so there is no browser to tear down.
    _closed = YES;
    [LiveViews() removeObject:self];
    if ([self.delegate respondsToSelector:@selector(browserViewDidClose:)]) {
      [self.delegate browserViewDidClose:self];
    }
  }
}

@end

namespace {

// Browser windows Chrome opens through its own UI, with its tab strip and
// toolbar: after an extension is installed (to show its "added" bubble), or
// when an extension opens a tab (Glea's page windows can't hold tabs). They
// are hidden at once, their page (if any) reopens as a Glea tab, and they
// close.
class ChromeUIWindowClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    Hide(browser);
    // Hand over once the address is known, or close anyway.
    CefRefPtr<CefBrowser> keep = browser;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      TakeOver(keep, ToNS(keep->GetMainFrame() ? keep->GetMainFrame()->GetURL() : CefString()));
    });
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
    Hide(browser);
    if (!frame->IsMain() || url.empty()) return;
    NSString* address = ToNS(url);
    if ([address isEqualToString:@"about:blank"]) return;
    TakeOver(browser, address);
  }

 private:
  // Invisible even if Chrome orders it in again once its page is ready.
  static void Hide(CefRefPtr<CefBrowser> browser) {
    NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    NSWindow* window = view.window;
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
    [window orderOut:nil];
  }

  void TakeOver(CefRefPtr<CefBrowser> browser, NSString* url) {
    int id = browser->GetIdentifier();
    if (handled_.count(id)) return;
    handled_.insert(id);
    if (void (^handler)(NSString*) = GleaCEF.chromeWindowHandler) handler(url ?: @"");
    browser->GetHost()->CloseBrowser(true);
  }

  std::set<int> handled_;
  IMPLEMENT_REFCOUNTING(ChromeUIWindowClient);
};

}  // namespace

namespace glea {

CefRefPtr<CefClient> ChromeUIClient() {
  static CefRefPtr<CefClient> client = new ChromeUIWindowClient();
  return client;
}

}  // namespace glea
