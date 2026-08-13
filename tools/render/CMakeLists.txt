# Desktop harness. Builds the phone's engine, unchanged, into a program that
# renders a WAV and measures it - the only way the DSP gets checked on a
# machine with no Xcode and no Android SDK.
#
#   cmake -S tools/render -B tools/render/build -G Ninja
#   cmake --build tools/render/build
#   tools/render/build/nulleig_render out.wav 180 --mood 2
cmake_minimum_required(VERSION 3.18)
project(nulleig_render CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nulleig/src")

add_executable(nulleig_render
  "${NE_SRC}/api.cpp"
  "${NE_SRC}/engine.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")

target_include_directories(nulleig_render PRIVATE "${NE_SRC}" "${NE_SRC}/third_party")
target_compile_definitions(nulleig_render PRIVATE NE_WITH_MINIAUDIO)
target_compile_options(nulleig_render PRIVATE -O2)

find_package(Threads REQUIRED)
target_link_libraries(nulleig_render Threads::Threads)
if(WIN32)
  target_link_libraries(nulleig_render ole32 winmm)
else()
  # miniaudio finds ALSA/PulseAudio/JACK with dlopen at run time, so there is
  # no development package to install - but there is a dl to link.
  target_link_libraries(nulleig_render ${CMAKE_DL_LIBS} m)
endif()
