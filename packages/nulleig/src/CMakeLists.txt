# Android only. iOS compiles these same sources through the podspec instead
# (see ../ios/Classes), and the desktop harness through ../../../tools/render.
#
# Do not raise the minimum: the Flutter tooling only guarantees CMake 3.10.
cmake_minimum_required(VERSION 3.10)

project(nulleig_library VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(nulleig SHARED
  "api.cpp"
  "engine.cpp"
)

target_include_directories(nulleig PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
)

set_target_properties(nulleig PROPERTIES
  PUBLIC_HEADER nulleig.h
  OUTPUT_NAME "nulleig"
)

target_compile_definitions(nulleig PRIVATE DART_SHARED_LIB NE_WITH_MINIAUDIO)

# -ffast-math without -fno-finite-math-only would let the compiler assume no
# infinities, and a feedback delay network that has just been handed a NaN
# would then never recover from it.
target_compile_options(nulleig PRIVATE -O3 -ffast-math -fno-finite-math-only)

if (ANDROID)
  # Android 15 ships 16 KB pages on some devices; a .so aligned to 4 KB will
  # not load there at all.
  target_link_options(nulleig PRIVATE "-Wl,-z,max-page-size=16384")
  # miniaudio reaches AAudio and OpenSL ES through dlopen, so the only thing
  # to link is the log channel it reports backend failures on.
  find_library(ANDROID_LOG_LIB log)
  target_link_libraries(nulleig ${ANDROID_LOG_LIB})
endif()
