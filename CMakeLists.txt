cmake_minimum_required(VERSION 3.21)

# CEF's minimal distribution only ships a Release framework.
set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
set(CMAKE_CONFIGURATION_TYPES Release CACHE STRING "Configurations" FORCE)

project(Glea VERSION 0.15.3 LANGUAGES C CXX Swift)
# Shown after the version (About, the update window): "0.15.0 Beta". The build
# number Sparkle compares (CFBundleVersion) is the plain version.
set(GLEA_VERSION_LABEL "Beta")
if(GLEA_VERSION_LABEL)
  set(GLEA_DISPLAY_VERSION "${PROJECT_VERSION} ${GLEA_VERSION_LABEL}")
else()
  set(GLEA_DISPLAY_VERSION "${PROJECT_VERSION}")
endif()

set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef")
if(NOT EXISTS "${CEF_ROOT}/cmake/FindCEF.cmake")
  message(FATAL_ERROR "CEF not found. Run ./scripts/setup_cef.sh first.")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

set(GLEA_BUNDLE_ID "app.glea.browser")
set(GLEA_APP "${CMAKE_CURRENT_BINARY_DIR}/Glea.app")

# --- Objective-C++ bridge around CEF ----------------------------------------

set(BRIDGE_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/src/bridge/include")

add_library(glea_bridge STATIC
  src/bridge/glea_browser_view.mm
  src/bridge/glea_main.mm
  src/bridge/chrome_harness.mm
  src/bridge/glea_browser_window.mm
)
SET_LIBRARY_TARGET_PROPERTIES(glea_bridge)
target_include_directories(glea_bridge PUBLIC ${BRIDGE_INCLUDE})
target_compile_options(glea_bridge PRIVATE -fobjc-arc -fobjc-weak -Wno-error)
add_dependencies(glea_bridge libcef_dll_wrapper)

# --- Helper apps (renderer, GPU, plugin, alerts processes) -------------------

set(HELPER_BASE_NAME "Glea Helper")
foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_target "glea_helper${_target_suffix}")
  set(HELPER_NAME "${HELPER_BASE_NAME}${_name_suffix}")
  set(HELPER_ID_SUFFIX "${_plist_suffix}")
  set(_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  configure_file(src/mac/helper-Info.plist.in ${_plist} @ONLY)

  add_executable(${_target} MACOSX_BUNDLE src/bridge/helper_main.mm)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_target})
  target_include_directories(${_target} PRIVATE src/bridge)
  target_compile_options(${_target} PRIVATE -Wno-error)
  add_dependencies(${_target} libcef_dll_wrapper)
  target_link_libraries(${_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${_plist}
    OUTPUT_NAME ${HELPER_NAME}
  )
  list(APPEND GLEA_HELPERS ${_target})
  list(APPEND GLEA_HELPER_NAMES "${HELPER_NAME}")
endforeach()

# --- SwiftMath (LaTeX math in notes; vendored, see third_party/SwiftMath) -----

file(GLOB_RECURSE SWIFTMATH_SOURCES CONFIGURE_DEPENDS third_party/SwiftMath/Sources/*.swift)
add_library(SwiftMath STATIC ${SWIFTMATH_SOURCES})
set_target_properties(SwiftMath PROPERTIES
  Swift_MODULE_NAME SwiftMath
  Swift_LANGUAGE_VERSION 5
)
target_compile_options(SwiftMath PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-O>" "$<$<COMPILE_LANGUAGE:Swift>:-suppress-warnings>")

# --- Sparkle (updates; downloaded by scripts/setup_sparkle.sh) ----------------

set(SPARKLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/sparkle")
if(NOT EXISTS "${SPARKLE_DIR}/Sparkle.framework")
  message(FATAL_ERROR "Sparkle not found. Run ./scripts/setup_sparkle.sh first.")
endif()

# --- Glea Clipper for Safari (an app extension embedded in Glea) -------------
#
# The browser extension's files (src/clipper/Resources, synced from
# glea-extensions by scripts/sync_clipper.sh) in a sandboxed .appex, plus
# Glea's own point-and-shoot script. Safari lists it once Glea has run.

set(CLIPPER_APPEX "${CMAKE_CURRENT_BINARY_DIR}/Glea Clipper.appex")
configure_file(src/clipper/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Clipper-Info.plist" @ONLY)
add_executable(GleaClipper src/clipper/SafariWebExtensionHandler.swift)
set_target_properties(GleaClipper PROPERTIES
  Swift_MODULE_NAME GleaClipper
  Swift_LANGUAGE_VERSION 5
  OUTPUT_NAME "Glea Clipper"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/clipper"
)
target_compile_options(GleaClipper PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-O>" "$<$<COMPILE_LANGUAGE:Swift>:-application-extension>")
# An app extension starts in NSExtensionMain, not main.
target_link_options(GleaClipper PRIVATE "SHELL:-Xlinker -e -Xlinker _NSExtensionMain"
  "SHELL:-application-extension" "SHELL:-framework SafariServices")
file(GLOB_RECURSE CLIPPER_RESOURCES CONFIGURE_DEPENDS src/clipper/Resources/*)
add_custom_command(TARGET GleaClipper POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${CLIPPER_APPEX}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CLIPPER_APPEX}/Contents/MacOS"
  COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:GleaClipper>" "${CLIPPER_APPEX}/Contents/MacOS/Glea Clipper"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_BINARY_DIR}/Clipper-Info.plist" "${CLIPPER_APPEX}/Contents/Info.plist"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/src/clipper/Resources" "${CLIPPER_APPEX}/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/src/resources/content-script.js"
          "${CLIPPER_APPEX}/Contents/Resources/vendor/glea-content-script.js"
  VERBATIM)

# --- The Swift application ---------------------------------------------------

file(GLOB GLEA_SWIFT_SOURCES CONFIGURE_DEPENDS src/app/*.swift)
set(GLEA_RESOURCES
  src/resources/content-script.js
  src/resources/AppIcon.icns  # src/mac/AppIcon-artwork.png wrapped by src/mac/wrap-icon.swift
)

configure_file(src/mac/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(Glea MACOSX_BUNDLE ${GLEA_SWIFT_SOURCES})
set_target_properties(Glea PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
  Swift_LANGUAGE_VERSION 5
)
target_compile_options(Glea PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${BRIDGE_INCLUDE}>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-F ${SPARKLE_DIR}>"
  "$<$<COMPILE_LANGUAGE:Swift>:-O>"
)
target_link_libraries(Glea PRIVATE glea_bridge SwiftMath libcef_dll_wrapper ${CEF_STANDARD_LIBS})
# (swiftc links: linker flags go through -Xlinker.)
target_link_options(Glea PRIVATE "SHELL:-F ${SPARKLE_DIR}" "SHELL:-framework Sparkle"
  "SHELL:-Xlinker -rpath -Xlinker @executable_path/../Frameworks")
add_dependencies(Glea ${GLEA_HELPERS} GleaClipper)

# Copy the CEF framework fresh each build. (CEF's COPY_MAC_FRAMEWORK macro uses
# `ln -sf`, which on rebuilds follows the existing directory symlinks and
# leaves self-referencing links that break code signing.)
set(CEF_FRAMEWORK_DIR "${GLEA_APP}/Contents/Frameworks/Chromium Embedded Framework.framework")
add_custom_command(TARGET Glea POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${CEF_FRAMEWORK_DIR}"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
          "${CEF_BINARY_DIR}/Chromium Embedded Framework.framework"
          "${CEF_FRAMEWORK_DIR}/Versions/A"
  COMMAND ln -sfn A "${CEF_FRAMEWORK_DIR}/Versions/Current"
  COMMAND ln -sfn "Versions/Current/Chromium Embedded Framework" "${CEF_FRAMEWORK_DIR}/Chromium Embedded Framework"
  COMMAND ln -sfn Versions/Current/Libraries "${CEF_FRAMEWORK_DIR}/Libraries"
  COMMAND ln -sfn Versions/Current/Resources "${CEF_FRAMEWORK_DIR}/Resources"
  VERBATIM)
# Sparkle, with ditto (it keeps the framework's symlinks). Its XPC services are
# for sandboxed apps; Glea isn't one.
set(SPARKLE_FRAMEWORK_DIR "${GLEA_APP}/Contents/Frameworks/Sparkle.framework")
add_custom_command(TARGET Glea POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${SPARKLE_FRAMEWORK_DIR}"
  COMMAND ditto "${SPARKLE_DIR}/Sparkle.framework" "${SPARKLE_FRAMEWORK_DIR}"
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${SPARKLE_FRAMEWORK_DIR}/Versions/B/XPCServices" "${SPARKLE_FRAMEWORK_DIR}/XPCServices"
  VERBATIM)
add_custom_command(TARGET Glea POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${GLEA_APP}/Contents/PlugIns/Glea Clipper.appex"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${GLEA_APP}/Contents/PlugIns"
  COMMAND ditto "${CLIPPER_APPEX}" "${GLEA_APP}/Contents/PlugIns/Glea Clipper.appex"
  VERBATIM)
foreach(_helper_name ${GLEA_HELPER_NAMES})
  add_custom_command(TARGET Glea POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${GLEA_APP}/Contents/Frameworks/${_helper_name}.app"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_BINARY_DIR}/${_helper_name}.app"
            "${GLEA_APP}/Contents/Frameworks/${_helper_name}.app"
    VERBATIM)
endforeach()
foreach(_resource ${GLEA_RESOURCES})
  get_filename_component(_name ${_resource} NAME)
  add_custom_command(TARGET Glea POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
            "${CMAKE_CURRENT_SOURCE_DIR}/${_resource}"
            "${GLEA_APP}/Contents/Resources/${_name}"
    VERBATIM)
endforeach()
add_custom_command(TARGET Glea POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${GLEA_APP}/Contents/Resources/mathFonts.bundle"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
          "${CMAKE_CURRENT_SOURCE_DIR}/third_party/SwiftMath/mathFonts.bundle"
          "${GLEA_APP}/Contents/Resources/mathFonts.bundle"
  COMMAND ${CMAKE_COMMAND} -E copy
          "${CMAKE_CURRENT_SOURCE_DIR}/third_party/SwiftMath/LICENSE"
          "${GLEA_APP}/Contents/Resources/SwiftMath-LICENSE.txt"
  VERBATIM)
# Bundles are assembled after linking, so re-sign them ad hoc, innermost first.
# swiftc leaves a dependency file next to the executable; codesign rejects it.
add_custom_command(TARGET Glea POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -f "${GLEA_APP}/Contents/MacOS/Glea.d"
  VERBATIM)
add_custom_command(TARGET Glea POST_BUILD
  COMMAND codesign --force --sign - "${GLEA_APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
  COMMAND codesign --force --sign - "${SPARKLE_FRAMEWORK_DIR}/Versions/B/Autoupdate"
  COMMAND codesign --force --sign - "${SPARKLE_FRAMEWORK_DIR}/Versions/B/Updater.app"
  COMMAND codesign --force --sign - "${SPARKLE_FRAMEWORK_DIR}"
  VERBATIM)
foreach(_helper_name ${GLEA_HELPER_NAMES})
  add_custom_command(TARGET Glea POST_BUILD
    COMMAND codesign --force --sign - "${GLEA_APP}/Contents/Frameworks/${_helper_name}.app"
    VERBATIM)
endforeach()
add_custom_command(TARGET Glea POST_BUILD
  COMMAND codesign --force --sign - --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/src/mac/entitlements/clipper.plist"
          "${GLEA_APP}/Contents/PlugIns/Glea Clipper.appex"
  COMMAND codesign --force --sign - "${GLEA_APP}"
  VERBATIM)
