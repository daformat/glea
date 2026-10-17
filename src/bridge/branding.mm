// Glea's name and icon on Chromium's own pages (chrome://settings,
// chrome://extensions...), in place of Chromium's: a resource bundle handler
// that rewrites Chromium's strings and serves Glea's icon for its logos.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <map>
#include <mutex>
#include <optional>
#include <string>

#include "include/cef_id_mappers.h"
#include "include/cef_resource_bundle.h"
#include "include/cef_resource_bundle_handler.h"
#include "internal.h"

namespace {

// Set while asking the bundle for its own resource, so that lookup isn't
// answered by this handler again.
thread_local bool g_looking_up = false;

struct OwnLookup {
  OwnLookup() { g_looking_up = true; }
  ~OwnLookup() { g_looking_up = false; }
};

// Chromium's logos, from chrome/grit/theme_resources.h and
// chrome_unscaled_resources.h (not in CEF's headers, so their ids are those
// of this build): each is only replaced while the original is a PNG of its
// size, so an id that moved in another build is left alone.
struct Logo {
  int resource_id;
  int size;  // Points (scaled logos) or pixels (unscaled ones).
  bool scaled;
};
constexpr Logo kLogos[] = {
    {14305, 32, true},    // IDR_PRODUCT_LOGO_32 (chrome://theme/current-channel-logo)
    {356, 16, true},      // IDR_PRODUCT_LOGO_16
    {14150, 64, false},   // IDR_PRODUCT_LOGO_64
    {336, 128, false},    // IDR_PRODUCT_LOGO_128
    {14151, 256, false},  // IDR_PRODUCT_LOGO_256
};

// The width of a PNG, or 0.
int PNGWidth(CefRefPtr<CefBinaryValue> data) {
  unsigned char header[24];
  if (!data || data->GetSize() < sizeof(header) || data->GetData(header, sizeof(header), 0) != sizeof(header)) return 0;
  static const unsigned char kSignature[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  if (memcmp(header, kSignature, sizeof(kSignature)) != 0) return 0;
  return (header[16] << 24) | (header[17] << 16) | (header[18] << 8) | header[19];
}

// Glea's icon: in the app's bundle, which also holds the helpers' (renderers
// serve some of Chromium's images).
NSURL* IconURL() {
  if (NSURL* url = [NSBundle.mainBundle URLForResource:@"AppIcon" withExtension:@"icns"]) return url;
  for (NSURL* dir = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent; dir.path.length > 1;
       dir = dir.URLByDeletingLastPathComponent) {
    if (![dir.pathExtension isEqualToString:@"app"]) continue;
    NSURL* url = [dir URLByAppendingPathComponent:@"Contents/Resources/AppIcon.icns"];
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return url;
  }
  return nil;
}

// Glea's icon, as a PNG of |pixels| square.
std::optional<std::string> IconPNG(int pixels) {
  NSURL* url = IconURL();
  if (!url || pixels <= 0) return std::nullopt;
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  if (!source) return std::nullopt;
  // The smallest image at least |pixels| wide (else the largest).
  CGImageRef best = nullptr;
  for (size_t i = 0, count = CGImageSourceGetCount(source); i < count; i++) {
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, i, nullptr);
    if (!image) continue;
    size_t width = CGImageGetWidth(image);
    size_t bestWidth = best ? CGImageGetWidth(best) : 0;
    bool better = !best || (bestWidth < (size_t)pixels ? width > bestWidth : (width >= (size_t)pixels && width < bestWidth));
    if (better) {
      if (best) CGImageRelease(best);
      best = image;
    } else {
      CGImageRelease(image);
    }
  }
  CFRelease(source);
  if (!best) return std::nullopt;

  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(nullptr, pixels, pixels, 8, 0, space, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!context) {
    CGImageRelease(best);
    return std::nullopt;
  }
  CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  CGContextDrawImage(context, CGRectMake(0, 0, pixels, pixels), best);
  CGImageRelease(best);
  CGImageRef scaled = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (!scaled) return std::nullopt;

  NSMutableData* png = [NSMutableData data];
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, nullptr);
  bool written = false;
  if (destination) {
    CGImageDestinationAddImage(destination, scaled, nullptr);
    written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(scaled);
  if (!written) return std::nullopt;
  return std::string((const char*)png.bytes, png.length);
}

class BrandingHandler : public CefResourceBundleHandler {
 public:
  bool GetLocalizedString(int string_id, CefString& string) override {
    if (g_looking_up) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = strings_.find(string_id);
    if (it == strings_.end()) it = strings_.emplace(string_id, Rebranded(string_id)).first;
    if (!it->second) return false;
    string = *it->second;
    return true;
  }

  bool GetDataResource(int resource_id, void*& data, size_t& data_size) override {
    return Resource(resource_id, SCALE_FACTOR_NONE, data, data_size);
  }

  bool GetDataResourceForScale(int resource_id, ScaleFactor scale_factor, void*& data, size_t& data_size) override {
    return Resource(resource_id, scale_factor, data, data_size);
  }

 private:
  // The string with "Chromium" (the product) said "Glea", or nothing when
  // it doesn't name it. The authors, the open source project (also as a
  // link) and ChromiumOS stay Chromium.
  static std::optional<std::string> Rebranded(int string_id) {
    // Glea's own copyright (see LICENSE.md), not Chromium's authors'.
    static const int kCopyright = cef_id_for_pack_string_name("IDS_ABOUT_VERSION_COPYRIGHT");
    static const int kCompany = cef_id_for_pack_string_name("IDS_ABOUT_VERSION_COMPANY_NAME");
    if (string_id == kCopyright && kCopyright >= 0) {
      return std::string("Copyright \u00a9 {0,date,y} Mathieu Jouhet (CSS labs). All rights reserved.");
    }
    if (string_id == kCompany && kCompany >= 0) return std::string("Mathieu Jouhet (CSS labs)");
    // chrome://settings/help: Glea's version, then the Chromium it runs on
    // ($1, Chromium's version).
    static const int kVersion = cef_id_for_pack_string_name("IDS_SETTINGS_ABOUT_PAGE_BROWSER_VERSION");
    if (string_id == kVersion && kVersion >= 0) {
      NSString* version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
      if (version.length) return std::string([NSString stringWithFormat:@"Version %@ (Chromium $1)", version].UTF8String);
    }
    CefRefPtr<CefResourceBundle> bundle = CefResourceBundle::GetGlobal();
    if (!bundle) return std::nullopt;
    std::string original;
    {
      OwnLookup own;
      original = bundle->GetLocalizedString(string_id).ToString();
    }
    if (original.find("Chromium") == std::string::npos) return std::nullopt;
    NSString* text = [NSString stringWithUTF8String:original.c_str()];
    if (!text) return std::nullopt;
    static NSRegularExpression* product = [NSRegularExpression
        regularExpressionWithPattern:@"\\bChromium(?![\\w-]|(?:<[^>]*>)*\\s+(?:Authors|open[ -]source|project))"
                             options:0
                               error:nil];
    NSString* rebranded = [product stringByReplacingMatchesInString:text
                                                            options:0
                                                              range:NSMakeRange(0, text.length)
                                                       withTemplate:@"Glea"];
    if ([rebranded isEqualToString:text]) return std::nullopt;
    return std::string(rebranded.UTF8String);
  }

  bool Resource(int resource_id, cef_scale_factor_t factor, void*& data, size_t& data_size) {
    if (g_looking_up) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    auto key = std::make_pair(resource_id, (int)factor);
    auto it = resources_.find(key);
    if (it == resources_.end()) it = resources_.emplace(key, Replacement(resource_id, factor)).first;
    if (!it->second) return false;
    // Cached for good: the bundle doesn't copy it.
    data = it->second->data();
    data_size = it->second->size();
    return true;
  }

  static std::optional<std::string> Replacement(int resource_id, cef_scale_factor_t factor) {
    CefRefPtr<CefResourceBundle> bundle = CefResourceBundle::GetGlobal();
    if (!bundle) return std::nullopt;
    auto original = [&] {
      OwnLookup own;
      return factor == SCALE_FACTOR_NONE ? bundle->GetDataResource(resource_id)
                                         : bundle->GetDataResourceForScale(resource_id, factor);
    };
    // Chromium's logo on dark pages (chrome://extensions' toolbar...).
    static const int kDarkLogo = cef_id_for_pack_resource_name("IDR_WEBUI_IMAGES_CHROME_LOGO_DARK_SVG");
    // (Its id comes by name, and the original is compressed: no check.)
    if (resource_id == kDarkLogo && kDarkLogo >= 0) {
      std::optional<std::string> png = IconPNG(256);
      if (!png) return std::nullopt;
      NSString* base64 = [[NSData dataWithBytes:png->data() length:png->size()] base64EncodedStringWithOptions:0];
      NSString* svg = [NSString stringWithFormat:
          @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">"
           "<image width=\"256\" height=\"256\" href=\"data:image/png;base64,%@\"/></svg>", base64];
      return std::string(svg.UTF8String);
    }
    for (const Logo& logo : kLogos) {
      if (logo.resource_id != resource_id) continue;
      // Scaled logos come at the nearest scale the bundle has: as wide.
      int width = PNGWidth(original());
      bool matches = logo.scaled ? width > 0 && width % logo.size == 0 : width == logo.size;
      if (!matches) return std::nullopt;
      return IconPNG(width);
    }
    return std::nullopt;
  }

  std::mutex mutex_;
  std::map<int, std::optional<std::string>> strings_;
  std::map<std::pair<int, int>, std::optional<std::string>> resources_;

  IMPLEMENT_REFCOUNTING(BrandingHandler);
};

}  // namespace

namespace glea {

CefRefPtr<CefResourceBundleHandler> Branding() {
  static CefRefPtr<CefResourceBundleHandler> handler = new BrandingHandler;
  return handler;
}

}  // namespace glea
