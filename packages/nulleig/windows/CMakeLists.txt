# The engine, built as nulleig.dll and bundled next to the app.
#
# This does not reuse ../src/CMakeLists.txt: that one is the Android build and
# its compiler flags are GCC's, which MSVC does not speak. The source list is
# the only thing worth sharing and it is two files long.
cmake_minimum_required(VERSION 3.14)

project(nulleig LANGUAGES CXX)

set(NE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../src")

add_library(nulleig SHARED
  "${NE_SRC}/api.cpp"
  "${NE_SRC}/engine.cpp"
)

# Deliberately not APPLY_STANDARD_SETTINGS. That helper is for the runner and
# for plugins that are all our own code; it turns on /W4 /WX, and miniaudio -
# thirty thousand lines of portable C we do not maintain - does not build
# warning-free under it. The app's own C++ is the runner, and that keeps the
# strict settings.
set_target_properties(nulleig PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OUTPUT_NAME "nulleig"
)

target_include_directories(nulleig PRIVATE
  "${NE_SRC}"
  "${NE_SRC}/third_party"
)

target_compile_definitions(nulleig PRIVATE
  DART_SHARED_LIB
  NE_WITH_MINIAUDIO
  # miniaudio pulls in windows.h, which defines min and max as macros and
  # would then rewrite std::min in anything included after it.
  NOMINMAX
  _CRT_SECURE_NO_WARNINGS
)

# /O2 and nothing else. The Android and Linux builds use -ffast-math with
# -fno-finite-math-only, because a feedback delay network handed a NaN never
# recovers if the compiler is allowed to assume NaNs cannot happen - and MSVC's
# nearest equivalent, /fp:fast, has no way to say "fast, but infinities are
# real". So this build takes the default floating point model. The synthesizer
# is fourteen voices and an eight-line reverb; /O2 alone leaves it about two
# percent of a core.
target_compile_options(nulleig PRIVATE /O2 /EHsc)

# WASAPI's device enumeration is COM, and miniaudio's fallback backend is
# WinMM. Everything else it needs it finds with LoadLibrary at run time.
target_link_libraries(nulleig PRIVATE ole32 winmm)

# What the Flutter tooling copies into the bundle. Without this the DLL is
# built and then left in the build tree, and the app launches and reports that
# the synthesis engine did not load.
set(nulleig_bundled_libraries
  "$<TARGET_FILE:nulleig>"
  PARENT_SCOPE
)
