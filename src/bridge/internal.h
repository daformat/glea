// Declarations shared between the bridge's implementation files.

#ifndef GLEA_BRIDGE_INTERNAL_H_
#define GLEA_BRIDGE_INTERNAL_H_

#include <functional>

#include "include/cef_client.h"

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#include "include/views/cef_window.h"
#endif

namespace glea {

// Name of the process message carrying `__gleaNative.post(name, json)`.
inline constexpr char kPostMessageName[] = "glea.post";
// Key in the CreateBrowser() extra_info dictionary holding the content script.
inline constexpr char kContentScriptKey[] = "contentScript";
// Renderer switch with the tab content script (base64), injected into every
// main frame whose browser has no content script entry of its own.
inline constexpr char kTabScriptSwitch[] = "glea-tab-script";

// Number of browsers created and not yet destroyed.
int LiveBrowserCount();

// Closes all browsers. |on_all_closed| runs once none remain.
void CloseAllBrowsers(std::function<void()> on_all_closed);

// False when GLEA_ALLOY_TABS is set (tabs then use Alloy style).
bool UsesChromeTabs();

// True once the user asked to quit.
bool IsQuitting();

#ifdef __OBJC__
// The Chromium (Views) window behind an app window that hosts Chrome-style
// tabs, or null (glea_browser_window.mm).
CefRefPtr<CefWindow> ChromeWindowFor(NSWindow* window);
#endif

// Closes every Chromium-created window.
void CloseAllWindows();

// Client for browser windows Chrome creates through its own UI.
CefRefPtr<CefClient> ChromeUIClient();

}  // namespace glea

#endif  // GLEA_BRIDGE_INTERNAL_H_
