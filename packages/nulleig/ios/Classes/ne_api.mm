// CocoaPods cannot reference sources outside the pod directory, so the shared
// C++ is pulled in by relative include from here. Same trick the plugin_ffi
// template uses, with one difference that matters: this file is Objective-C++
// rather than C++, because the translation unit that instantiates miniaudio
// also instantiates its Core Audio backend, and on iOS that backend talks to
// AVAudioSession in Objective-C.
#include "../../src/api.cpp"
