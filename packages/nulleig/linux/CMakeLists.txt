# The engine, built as libnulleig.so and bundled into the app's lib/.
#
# Separate from ../src/CMakeLists.txt only because that one is invoked by the
# Android Gradle plugin and carries its NDK-specific link options. The
# compiler flags below are the same ones, for the same reasons.
cmake_minimum_required(VERSION 3.13)

project(nulleig LANGUAGES CXX)

set(NE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../src")

add_library(nulleig SHARED
  "${NE_SRC}/api.cpp"
  "${NE_SRC}/engine.cpp"
)

set_target_properties(nulleig PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  OUTPUT_NAME "nulleig"
)

target_include_directories(nulleig PRIVATE
  "${NE_SRC}"
  "${NE_SRC}/third_party"
)

target_compile_definitions(nulleig PRIVATE DART_SHARED_LIB NE_WITH_MINIAUDIO)

# -ffast-math without -fno-finite-math-only would let the compiler assume no
# infinities, and a feedback delay network that has just been handed a NaN
# would then never recover from it.
target_compile_options(nulleig PRIVATE -O3 -ffast-math -fno-finite-math-only)

# miniaudio reaches ALSA, PulseAudio, PipeWire and JACK through dlopen, which
# is what lets one binary run on a machine that has any of them and no
# development package installed for any of them. So there is nothing to find
# here but libdl itself.
find_package(Threads REQUIRED)
target_link_libraries(nulleig PRIVATE ${CMAKE_DL_LIBS} m Threads::Threads)

set(nulleig_bundled_libraries
  "$<TARGET_FILE:nulleig>"
  PARENT_SCOPE
)
