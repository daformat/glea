// Entry point for the Chromium helper processes (renderer, GPU, network...).

#include <map>
#include <string>

#include "include/base/cef_logging.h"
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/cef_command_line.h"
#include "include/cef_parser.h"
#include "internal.h"

namespace {

// Exposes `__gleaNative.post(name, json)` to the content script.
// Tells the app whether a frame plays sound: a <video>/<audio> playing, not
// muted and with sound (a stream with an audio track, a file with decoded
// audio: a camera preview has none), or a running Web Audio context with
// something connected to the speakers (analysing the microphone isn't
// playing). It posts "audible" (with an id for the frame) when that changes.
const char kAudibleScript[] = R"JS((() => {
  if (window.__gleaAudible) return;
  window.__gleaAudible = true;
  const native = window.__gleaNative;
  if (!native) return;
  const frame = Math.random().toString(36).slice(2);
  const media = new Set();
  const contexts = new Set();
  let audible = false;
  const hasSound = (m) => {
    if (m.srcObject instanceof MediaStream) return m.srcObject.getAudioTracks().some((t) => t.enabled && t.readyState === 'live');
    return m.webkitAudioDecodedByteCount === undefined || m.webkitAudioDecodedByteCount > 0;
  };
  const playing = (m) => !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2 && hasSound(m);
  // Contexts with something connected to their speakers.
  const outputs = new WeakSet();
  const connect = AudioNode.prototype.connect;
  AudioNode.prototype.connect = function (target) {
    if (target instanceof AudioDestinationNode) {
      outputs.add(target.context);
      setTimeout(check, 50);
    }
    return connect.apply(this, arguments);
  };
  function check() {
    for (const m of document.querySelectorAll('video, audio')) media.add(m);
    let now = false;
    for (const m of media) if (playing(m)) { now = true; break; }
    if (!now) for (const c of contexts) if (c.state === 'running' && outputs.has(c)) { now = true; break; }
    if (now !== audible) {
      audible = now;
      native.post('audible', JSON.stringify({ frame, audible }));
    }
  }
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    media.add(this);
    const result = play.apply(this, arguments);
    setTimeout(check, 50);
    return result;
  };
  for (const name of ['AudioContext', 'webkitAudioContext']) {
    const Original = window[name];
    if (!Original) continue;
    const Wrapped = function (...args) {
      const context = new Original(...args);
      contexts.add(context);
      context.addEventListener('statechange', () => {
        if (context.state === 'closed') contexts.delete(context);
        check();
      });
      setTimeout(check, 50);
      return context;
    };
    Wrapped.prototype = Original.prototype;
    Object.setPrototypeOf(Wrapped, Original);
    window[name] = Wrapped;
  }
  for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'canplay']) {
    document.addEventListener(type, check, true);
  }
  setInterval(check, 2000);
  window.addEventListener('pagehide', () => {
    if (audible) native.post('audible', JSON.stringify({ frame, audible: false }));
    audible = false;
  });
})();)JS";

class PostHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.size() < 2 || !arguments[0]->IsString() || !arguments[1]->IsString()) {
      exception = "__gleaNative.post(name, json) expects two strings";
      return true;
    }
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context->GetFrame();
    // Subframes only say whether they play sound.
    if (!frame || (!frame->IsMain() && arguments[0]->GetStringValue() != "audible")) return true;

    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(glea::kPostMessageName);
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    args->SetString(0, arguments[0]->GetStringValue());
    args->SetString(1, arguments[1]->GetStringValue());
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(PostHandler);
};

// The tab content script, passed on the command line (base64).
const CefString& TabScript() {
  static CefString script = [] {
    CefRefPtr<CefCommandLine> line = CefCommandLine::GetGlobalCommandLine();
    std::string encoded = line ? line->GetSwitchValue(glea::kTabScriptSwitch).ToString() : "";
    CefRefPtr<CefBinaryValue> decoded = encoded.empty() ? nullptr : CefBase64Decode(encoded);
    if (!decoded) return CefString();
    std::string text(decoded->GetSize(), '\0');
    decoded->GetData(text.data(), text.size(), 0);
    return CefString(text);
  }();
  return script;
}

class RendererApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info && extra_info->HasKey(glea::kContentScriptKey)) {
      scripts_[browser->GetIdentifier()] = extra_info->GetString(glea::kContentScriptKey);
    }
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    scripts_.erase(browser->GetIdentifier());
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    auto it = scripts_.find(browser->GetIdentifier());
    std::string url = frame->GetURL().ToString();
    bool web = url.rfind("http", 0) == 0 || url.rfind("file:", 0) == 0 || url.rfind("chrome-error:", 0) == 0;
    // Every web frame says whether it plays sound; subframes (embedded
    // players) only that.
    bool audibleWatched = url.rfind("http", 0) == 0 || url.rfind("file:", 0) == 0;
    if (!frame->IsMain()) {
      if (!audibleWatched) return;
      InstallNative(context);
      Evaluate(context, kAudibleScript);
      return;
    }
    CefString script;
    if (it != scripts_.end()) {
      script = it->second;
    } else if (web) {
      // A Chrome tab: the tab script, on web pages (and Chromium's error page).
      script = TabScript();
    }
    if (getenv("GLEA_CEF_LOG")) {
      LOG(WARNING) << "glea: context created for " << frame->GetURL().ToString()
                   << " script=" << (it != scripts_.end());
    }
    if (script.empty() && !audibleWatched) return;

    InstallNative(context);
    if (!script.empty()) Evaluate(context, script);
    if (audibleWatched) Evaluate(context, kAudibleScript);
  }

  /// `__gleaNative.post(name, json)`, for the scripts.
  static void InstallNative(CefRefPtr<CefV8Context> context) {
    CefRefPtr<CefV8Value> native = CefV8Value::CreateObject(nullptr, nullptr);
    native->SetValue("post", CefV8Value::CreateFunction("post", new PostHandler),
                     V8_PROPERTY_ATTRIBUTE_READONLY);
    context->GetGlobal()->SetValue(
        "__gleaNative", native,
        static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY |
                                                V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                V8_PROPERTY_ATTRIBUTE_DONTDELETE));
  }

  static void Evaluate(CefRefPtr<CefV8Context> context, const CefString& script) {
    CefRefPtr<CefV8Value> retval;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(script, "glea://content-script.js", 1, retval, exception) && exception) {
      LOG(WARNING) << "glea: content script failed: " << exception->GetMessage().ToString();
    }
  }

 private:
  std::map<int, CefString> scripts_;

  IMPLEMENT_REFCOUNTING(RendererApp);
};

}  // namespace

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) return 1;

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) return 1;

  CefMainArgs main_args(argc, argv);
  CefRefPtr<RendererApp> app(new RendererApp);
  return CefExecuteProcess(main_args, app, nullptr);
}
