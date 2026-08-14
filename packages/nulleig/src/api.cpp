// api.cpp - the flat C surface Dart calls, plus the audio device.
//
// The device lives here rather than on the Dart side on purpose. Everything
// that matters about this app happens with the screen off: iOS keeps the
// process alive only while an audio session is actually producing samples, and
// a Flutter engine in the background is not a place to be generating them
// from. Owning the device natively means the render callback is the OS's
// audio thread talking straight to the synthesizer, with Dart nowhere in the
// path - it can be paused, janked or garbage-collecting and the drone does not
// notice.

#include "nulleig.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <new>

#include "engine.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && defined(__OBJC__)
#import <AVFoundation/AVFoundation.h>
#endif
#endif

#ifdef NE_WITH_MINIAUDIO
#include <chrono>
#include <thread>

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#endif

namespace {

constexpr int kDefaultRate = 48000;

struct Holder {
    ne::Engine engine;
    // Every step of opening the device records its result, because on a
    // sideloaded build there is no console and "no sound" has to be
    // diagnosable from inside the app.
    std::atomic<int> r_context{-999};
    std::atomic<int> r_device_init{-999};
    std::atomic<int> r_device_start{-999};
    std::atomic<int> started{0};
    std::atomic<unsigned int> callbacks{0};
#ifdef NE_WITH_MINIAUDIO
    ma_context context{};
    ma_device device{};
    bool context_ok = false;
    bool device_ok = false;
    std::atomic<bool> want_running{false};
    std::atomic<bool> watchdog_quit{false};
    std::thread watchdog;
#endif
    explicit Holder(int sr) : engine(sr) {}
};

#ifdef NE_WITH_MINIAUDIO
void data_callback(ma_device* dev, void* out, const void* in, ma_uint32 frames) {
    (void)in;
    Holder* h = (Holder*)dev->pUserData;
    if (h == nullptr) return;
    h->callbacks.fetch_add(1, std::memory_order_relaxed);
    h->engine.render((float*)out, (int)frames);
}

// The device is restarted from here rather than from the notification
// callback, which miniaudio explicitly forbids re-entering. A poll also covers
// the cases that arrive without a notification at all - a route change that
// silently stops the unit, an interruption that ends while the app is
// suspended - so it is the more honest mechanism anyway.
void watchdog_main(Holder* h) {
    while (!h->watchdog_quit.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        if (!h->want_running.load(std::memory_order_relaxed)) continue;
        if (!h->device_ok) continue;
        // Only from `stopped`, not from "anything that is not started".
        // `starting` and `stopping` are transient states the backend passes
        // through on its own, and restarting a device that is mid-start turns
        // a working device into a permanent stutter.
        if (ma_device_get_state(&h->device) == ma_device_state_stopped) {
            ma_device_start(&h->device);  // fails harmlessly during a call
        }
    }
}
#endif

}  // namespace

extern "C" {

NE_API ne_engine* ne_create(int sample_rate) {
    int sr = sample_rate > 8000 ? sample_rate : kDefaultRate;
    Holder* h = new (std::nothrow) Holder(sr);
    return (ne_engine*)h;
}

NE_API void ne_destroy(ne_engine* e) {
    Holder* h = (Holder*)e;
    if (!h) return;
#ifdef NE_WITH_MINIAUDIO
    h->want_running.store(false, std::memory_order_relaxed);
    h->watchdog_quit.store(true, std::memory_order_relaxed);
    if (h->watchdog.joinable()) h->watchdog.join();
    if (h->device_ok) ma_device_uninit(&h->device);
    if (h->context_ok) ma_context_uninit(&h->context);
#endif
    delete h;
}

NE_API int ne_start(ne_engine* e) {
#ifdef NE_WITH_MINIAUDIO
    Holder* h = (Holder*)e;
    if (!h) return -1;
    if (h->device_ok && ma_device_get_state(&h->device) == ma_device_state_started) {
        h->want_running.store(true, std::memory_order_relaxed);
        return 0;
    }

    if (!h->context_ok) {
        ma_context_config cfg = ma_context_config_init();
        // Playback, not ambient: this is the app's reason to be running, it
        // should interrupt whatever was playing, it must ignore the ringer
        // switch, and - the part that actually matters - only the playback
        // category keeps the process alive with the screen off.
        //
        // The AppDelegate sets the same category and activates the session
        // before Flutter starts, so this is a second, agreeing voice rather
        // than a competing one. Both saying "playback" means the order they
        // run in cannot change the answer.
        cfg.coreaudio.sessionCategory = ma_ios_session_category_playback;
        // No category options. AllowBluetoothA2DP and AllowAirPlay are
        // documented as valid only with playAndRecord - with playback both
        // routes are already allowed by default, so at best the flags are
        // noise and at worst they are the reason setCategory refuses on some
        // OS version, which here would surface as ctx failing.
        cfg.coreaudio.sessionCategoryOptions = 0;
        // Leave the session active when the device is torn down. Deactivating
        // it is what makes the lock-screen controls disappear.
        cfg.coreaudio.noAudioSessionDeactivate = MA_TRUE;
        int r = (int)ma_context_init(nullptr, 0, &cfg, &h->context);
        h->r_context.store(r, std::memory_order_relaxed);
        if (r != MA_SUCCESS) return -2;
        h->context_ok = true;
    }

    if (!h->device_ok) {
        ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
        cfg.playback.format = ma_format_f32;
        cfg.playback.channels = 2;
        cfg.sampleRate = (ma_uint32)h->engine.sample_rate();
        cfg.dataCallback = data_callback;
        cfg.pUserData = h;
        // ~20 ms. Long enough that a scheduling hiccup on a phone cannot
        // starve it, short enough that dragging a finger still feels connected
        // to the sound.
        cfg.periodSizeInMilliseconds = 20;
        cfg.performanceProfile = ma_performance_profile_conservative;
        int r = (int)ma_device_init(&h->context, &cfg, &h->device);
        h->r_device_init.store(r, std::memory_order_relaxed);
        if (r != MA_SUCCESS) return -3;
        h->device_ok = true;
    }

    int rs = (int)ma_device_start(&h->device);
    h->r_device_start.store(rs, std::memory_order_relaxed);
    if (rs != MA_SUCCESS) return -4;
    h->started.store(1, std::memory_order_relaxed);
    h->want_running.store(true, std::memory_order_relaxed);
    if (!h->watchdog.joinable()) {
        h->watchdog_quit.store(false, std::memory_order_relaxed);
        h->watchdog = std::thread(watchdog_main, h);
    }
    return 0;
#else
    (void)e;
    return -100;  // built without a device (offline harness)
#endif
}

NE_API void ne_stop(ne_engine* e) {
#ifdef NE_WITH_MINIAUDIO
    Holder* h = (Holder*)e;
    if (!h) return;
    h->want_running.store(false, std::memory_order_relaxed);
    if (h->device_ok) ma_device_stop(&h->device);
#else
    (void)e;
#endif
}

NE_API int ne_sample_rate(const ne_engine* e) {
    const Holder* h = (const Holder*)e;
    return h ? h->engine.sample_rate() : 0;
}

NE_API void ne_render(ne_engine* e, float* out, int frames) {
    Holder* h = (Holder*)e;
    if (!h || !out || frames <= 0) return;
    h->engine.render(out, frames);
}

NE_API void ne_set_mood(ne_engine* e, int mood) {
    if (e) ((Holder*)e)->engine.set_mood(mood);
}
NE_API int ne_mood(const ne_engine* e) {
    return e ? ((const Holder*)e)->engine.mood() : 0;
}
NE_API void ne_set_field(ne_engine* e, float x, float y) {
    if (e) ((Holder*)e)->engine.set_field(x, y);
}
NE_API void ne_set_touch(ne_engine* e, int active, float speed) {
    if (e) ((Holder*)e)->engine.set_touch(active != 0, speed);
}
NE_API void ne_set_playing(ne_engine* e, int playing) {
    if (e) ((Holder*)e)->engine.set_playing(playing != 0);
}
NE_API int ne_playing(const ne_engine* e) {
    return e ? (((const Holder*)e)->engine.playing() ? 1 : 0) : 0;
}
NE_API void ne_set_gain(ne_engine* e, float gain) {
    if (e) ((Holder*)e)->engine.set_gain(gain);
}
NE_API void ne_set_seed(ne_engine* e, uint32_t seed) {
    if (e) ((Holder*)e)->engine.set_seed(seed);
}
NE_API void ne_get_vis(ne_engine* e, ne_vis* out) {
    if (e && out) ((Holder*)e)->engine.get_vis(out);
}

NE_API void ne_get_status(ne_engine* e, ne_status* out) {
    if (!out) return;
    Holder* h = (Holder*)e;
    if (!h) {
        *out = ne_status{};
        return;
    }
    out->started = h->started.load(std::memory_order_relaxed);
    out->ma_context = h->r_context.load(std::memory_order_relaxed);
    out->ma_device_init = h->r_device_init.load(std::memory_order_relaxed);
    out->ma_device_start = h->r_device_start.load(std::memory_order_relaxed);
    out->callbacks = h->callbacks.load(std::memory_order_relaxed);
    out->elapsed = h->engine.elapsed();
    out->sample_rate = h->engine.sample_rate();
#ifdef NE_WITH_MINIAUDIO
    out->device_state = h->device_ok ? (int)ma_device_get_state(&h->device) : -1;
    if (h->device_ok) out->sample_rate = (int)h->device.sampleRate;
#else
    out->device_state = -1;
#endif
}
NE_API void ne_session_info(char* out, int cap) {
    if (out == nullptr || cap <= 0) return;
    out[0] = '\0';
#if defined(__APPLE__) && TARGET_OS_IPHONE && defined(__OBJC__)
    // Compiled as Objective-C++ on iOS (the pod pulls this file in through an
    // .mm forwarder), so the session can simply be asked. Everything here is
    // a read; nothing below can change the audio state.
    @autoreleasepool {
        AVAudioSession* session = [AVAudioSession sharedInstance];
        NSString* c = session.category;
        const char* cat = "othercat";
        if ([c isEqualToString:AVAudioSessionCategoryPlayback]) {
            cat = "playback";
        } else if ([c isEqualToString:AVAudioSessionCategoryAmbient]) {
            cat = "ambient";
        } else if ([c isEqualToString:AVAudioSessionCategorySoloAmbient]) {
            cat = "soloambient";
        } else if ([c isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
            cat = "playandrecord";
        }
        NSMutableArray<NSString*>* ports = [NSMutableArray array];
        for (AVAudioSessionPortDescription* p in session.currentRoute.outputs) {
            [ports addObject:p.portType];
        }
        // Port types read well raw: "Speaker", "Headphones",
        // "BluetoothA2DPOutput", "AirPlay". No route at all is itself a
        // diagnosis - an active session should always have one.
        NSString* route =
            ports.count ? [ports componentsJoinedByString:@"+"] : @"noroute";
        std::snprintf(out, (size_t)cap, "%s %s vol%.2f%s", cat,
                      route.UTF8String, (double)session.outputVolume,
                      session.otherAudioPlaying ? " other" : "");
        out[cap - 1] = '\0';
    }
#endif
}

NE_API const char* ne_mood_name(int mood) { return ne::mood_at(mood).name; }
NE_API double ne_elapsed(const ne_engine* e) {
    return e ? ((const Holder*)e)->engine.elapsed() : 0.0;
}

}  // extern "C"
