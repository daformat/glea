#import "GleaBridge.h"

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "internal.h"

// CEF requires the NSApplication subclass to implement CefAppProtocol.
@interface GleaApplication : NSApplication <CefAppProtocol>
@end

@implementation GleaApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// Quitting must go through CEF so browsers shut down cleanly; the message loop
// then returns from GleaMain() which calls CefShutdown().
- (void)terminate:(id)sender {
  [GleaCEF requestQuit];
}

@end

// chrome_harness.mm
NSString* GleaChromeHarnessExtensionPath(NSString* out);
void GleaRunChromeHarness(NSString* out);

namespace {

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  // Tabs opened by Chrome ("new tab" command) carry no per-browser data, so
  // renderers get the tab content script at launch (they can't read files).
  void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {
    static NSString* encoded = [] {
      NSString* path = [NSBundle.mainBundle pathForResource:@"content-script" ofType:@"js"];
      NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
      return data ? [data base64EncodedStringWithOptions:0] : @"";
    }();
    if (encoded.length) command_line->AppendSwitchWithValue(glea::kTabScriptSwitch, encoded.UTF8String);
  }

  // Windows Chrome opens by itself (extension install, chrome.tabs.create):
  // Glea takes them over (see glea::ChromeUIClient).
  CefRefPtr<CefClient> GetDefaultClient() override { return glea::ChromeUIClient(); }

  // Chrome-style browsers can only be created once the context is ready.
  void OnContextInitialized() override {
    if (NSString* harness = NSProcessInfo.processInfo.environment[@"GLEA_CHROME_HARNESS"]) GleaRunChromeHarness(harness);
  }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    // GLEA_CEF_LOG=1 sends Chromium's logs (all processes) to stderr.
    if (getenv("GLEA_CEF_LOG") != nullptr) command_line->AppendSwitchWithValue("enable-logging", "stderr");
    if (!process_type.empty()) return;
    // Glea restores its own tabs: Chrome must never reopen (or offer to
    // reopen) windows from its last session, e.g. after the app was killed.
    command_line->AppendSwitch("no-startup-window");
    command_line->AppendSwitch("disable-session-crashed-bubble");
    // The Chrome-style harness loads its test extension from the command line.
    if (NSString* out = NSProcessInfo.processInfo.environment[@"GLEA_CHROME_HARNESS"];
        out && !NSProcessInfo.processInfo.environment[@"GLEA_HARNESS_NO_EXTENSION"]) {
      // Just the switch: a --disable-features here replaces CEF's own list and
      // crashes when the window is created.
      command_line->AppendSwitchWithValue("load-extension", GleaChromeHarnessExtensionPath(out).UTF8String);
    }
    // GLEA_LOAD_EXTENSION=<dir>[,<dir>…] loads unpacked extensions (development).
    if (const char* dirs = getenv("GLEA_LOAD_EXTENSION")) command_line->AppendSwitchWithValue("load-extension", dirs);
    // Without a stable code signature (local development builds) every
    // rebuild would trigger a Keychain access prompt for "Glea Safe Storage".
    if (getenv("GLEA_REAL_KEYCHAIN") == nullptr) {
      command_line->AppendSwitch("use-mock-keychain");
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserApp);
};

void (^g_will_quit_handler)(void);
void (^g_chrome_window_handler)(NSString*);
NSString* g_profile_path = @"";
BOOL g_quitting = NO;

}  // namespace

namespace glea {
bool IsQuitting() {
  return g_quitting;
}
}  // namespace glea

@implementation GleaCEF

+ (void (^)(void))willQuitHandler {
  return g_will_quit_handler;
}

+ (void)setWillQuitHandler:(void (^)(void))handler {
  g_will_quit_handler = [handler copy];
}

+ (void (^)(NSString*))chromeWindowHandler {
  return g_chrome_window_handler;
}

+ (void)setChromeWindowHandler:(void (^)(NSString*))handler {
  g_chrome_window_handler = [handler copy];
}

+ (NSString*)profilePath {
  return g_profile_path;
}

+ (void)requestQuit {
  if (g_quitting) return;
  g_quitting = YES;
  if (g_will_quit_handler) g_will_quit_handler();

  glea::CloseAllBrowsers([] {
    glea::CloseAllWindows();
    CefQuitMessageLoop();
  });
  // Never hang on quit if a browser fails to report its destruction.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (glea::LiveBrowserCount() > 0) {
      // Chrome keeps running while any of its windows is open.
      glea::CloseAllWindows();
      CefQuitMessageLoop();
    }
  });
}

@end

// The app used to be called Sleam, and Meam before that. Moves their folders
// and preferences over once, before anything reads them, newest name first.
// Never overwrites existing Glea data.
static void MigrateFromOldNames() {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  for (NSString* oldName in @[ @"Sleam", @"Meam" ]) {
    for (NSString* base in @[ support, documents ]) {
      NSString* from = [base stringByAppendingPathComponent:oldName];
      NSString* to = [base stringByAppendingPathComponent:@"Glea"];
      if ([fm fileExistsAtPath:from] && ![fm fileExistsAtPath:to]) {
        NSError* error = nil;
        if (![fm moveItemAtPath:from toPath:to error:&error]) NSLog(@"Glea: couldn't move %@: %@", from, error);
      }
    }
    // Preferences: copy the old domain once, renaming its keys.
    NSString* flag = [@"GleaMigratedFrom" stringByAppendingString:oldName];
    if ([defaults boolForKey:flag]) continue;
    NSString* domain = [NSString stringWithFormat:@"app.%@.browser", oldName.lowercaseString];
    NSDictionary* old = [defaults persistentDomainForName:domain];
    for (NSString* key in old) {
      if ([key containsString:@"MigratedFrom"]) continue;
      NSString* newKey = [key stringByReplacingOccurrencesOfString:oldName withString:@"Glea"];
      if ([defaults objectForKey:newKey] != nil) continue;
      id value = old[key];
      if ([value isKindOfClass:NSString.class]) {
        NSString* oldDocuments = [@"/Documents/" stringByAppendingString:oldName];
        value = [value stringByReplacingOccurrencesOfString:oldDocuments withString:@"/Documents/Glea"];
      }
      [defaults setObject:value forKey:newKey];
    }
    [defaults setBool:YES forKey:flag];
  }
}

int GleaMain(int argc, char** argv, NSString* delegateClassName) {
  if (!NSProcessInfo.processInfo.environment[@"GLEA_PROFILE_DIR"]) MigrateFromOldNames();
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) return 1;

  CefMainArgs main_args(argc, argv);

  @autoreleasepool {
    [GleaApplication sharedApplication];

    NSString* support = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString* profile = [support stringByAppendingPathComponent:@"Glea/Chromium"];
    if (NSString* override = NSProcessInfo.processInfo.environment[@"GLEA_PROFILE_DIR"]) {
      profile = override;
    }

    g_profile_path = [profile stringByAppendingPathComponent:@"Default"];
    // Glea restores its own tabs; Chrome's session files would reopen page
    // windows as Chrome windows (with a location bar). Never keep them.
    for (NSString* name in @[ @"Sessions", @"Current Session", @"Current Tabs", @"Last Session", @"Last Tabs" ]) {
      [NSFileManager.defaultManager removeItemAtPath:[g_profile_path stringByAppendingPathComponent:name] error:nil];
    }
    CefSettings settings;
    CefString(&settings.root_cache_path) = profile.UTF8String;
    CefString(&settings.cache_path) = [profile stringByAppendingPathComponent:@"Default"].UTF8String;
    settings.persist_session_cookies = true;
    settings.log_severity = LOGSEVERITY_WARNING;

    CefRefPtr<BrowserApp> app(new BrowserApp);
    if (!CefInitialize(main_args, settings, app, nullptr)) return CefGetExitCode();

    if (NSProcessInfo.processInfo.environment[@"GLEA_CHROME_HARNESS"]) {
      // Starts from OnContextInitialized().
      CefRunMessageLoop();
      CefShutdown();
      return 0;
    }

    // NSApplication holds its delegate weakly.
    static id delegate = [[NSClassFromString(delegateClassName) alloc] init];
    NSApp.delegate = delegate;

    CefRunMessageLoop();
    CefShutdown();
  }
  return 0;
}
