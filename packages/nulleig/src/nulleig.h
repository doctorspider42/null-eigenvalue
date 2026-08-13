/* nulleig.h - the whole engine, as flat C so Dart's FFI can call it.
 *
 * There is one object, `ne_engine`, and it owns everything: the synthesis, the
 * effects and (on a phone) the audio device. Dart never sees a sample. It sets
 * a handful of scalars and reads back a small block of numbers to draw with.
 *
 * Threading contract, which is the only subtle thing here:
 *   - ne_create / ne_destroy / ne_start / ne_stop are called from one thread
 *     (Dart's) and are not reentrant.
 *   - every ne_set_* and ne_get_vis is safe to call from any thread at any
 *     time. They touch nothing but atomics, so the audio callback can never be
 *     blocked by a UI that is busy laying out a frame. This is why the setters
 *     take plain floats rather than a struct pointer: a struct copy would need
 *     a lock or a sequence counter, and the parameter set is small enough that
 *     per-field atomics are simpler and strictly better.
 *   - ne_render is called from the audio thread (or from a test harness) and
 *     allocates nothing.
 */
#ifndef NULLEIG_H
#define NULLEIG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// `used` as well as `visible`: on iOS these sources are linked statically into
// the app, and Dart resolves them at run time out of the process image. To the
// linker that looks like a symbol nobody calls, and -dead_strip would throw
// the entire engine away - a build that succeeds and then cannot find
// ne_create on the device.
#if defined(_WIN32)
#define NE_API __declspec(dllexport)
#else
#define NE_API __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Number of aura bands published for the visuals. One per register slice; the
 * UI turns them into the drifting orbs. */
#define NE_BANDS 8

typedef struct ne_engine ne_engine;

/* What the UI needs to draw a picture of what it is hearing. Everything is
 * already smoothed for display - the caller can use these values raw at 60 Hz
 * without filtering them again. */
typedef struct ne_vis {
    float level;              /* 0..1, smoothed peak of the master bus       */
    float centroid;           /* 0..1, brightness (log spectral centre)      */
    float band[NE_BANDS];     /* 0..1, energy per register slice, low first  */
    float spark;              /* 0..1, decays after each bell strike         */
    float root_hz;            /* current drone fundamental                   */
    float motion;             /* 0..1, how much the harmony is moving now    */
    float gate;               /* 0..1, master fade (0 paused, 1 playing)     */
    int   chord_change;       /* increments on every harmonic move           */
} ne_vis;

/* ---------------------------------------------------------------- lifecycle */

/* `sample_rate` may be 0, meaning "whatever the device wants" - the real rate
 * is then decided by ne_start(). Pass a real rate when rendering offline. */
NE_API ne_engine* ne_create(int sample_rate);
NE_API void ne_destroy(ne_engine* e);

/* Opens the sound card and starts pulling audio. Returns 0 on success.
 * A no-op that returns 0 if the device is already running. */
NE_API int ne_start(ne_engine* e);
NE_API void ne_stop(ne_engine* e);

/* The actual sample rate in use (after ne_start may differ from the request). */
NE_API int ne_sample_rate(const ne_engine* e);

/* Interleaved stereo. `frames` is the per-channel count. Used by the audio
 * callback and by the offline harness; safe to call directly when the device
 * is not running. */
NE_API void ne_render(ne_engine* e, float* out, int frames);

/* ---------------------------------------------------------------- parameters */

#define NE_MOOD_COUNT 5

/* 0 Kernel, 1 Manifold, 2 Halo, 3 Torsion, 4 Limit. Out-of-range is clamped.
 * A change is not instant: the new mood's harmony is walked into over the next
 * minute or so rather than cut to, because a drone that jump-cuts is a
 * different piece rather than the same one in a new light. */
NE_API void ne_set_mood(ne_engine* e, int mood);
NE_API int  ne_mood(const ne_engine* e);

/* The 2D field, both 0..1. x is brightness (dark .. airy), y is density
 * (sparse and low .. dense and wide). Smoothed internally over seconds. */
NE_API void ne_set_field(ne_engine* e, float x, float y);

/* The finger itself, as distinct from where it left the field: `speed` is in
 * screen-widths per second and feeds a short excitation that makes fast moves
 * audible as shimmer rather than only as a parameter change. */
NE_API void ne_set_touch(ne_engine* e, int active, float speed);

/* Master fade. Anything non-zero fades up over ~1.2 s, zero fades down and
 * then idles the synthesis. The device keeps running either way so that the
 * OS does not reclaim the audio session mid-pause. */
NE_API void ne_set_playing(ne_engine* e, int playing);
NE_API int  ne_playing(const ne_engine* e);

/* 0..1 linear, applied last. */
NE_API void ne_set_gain(ne_engine* e, float gain);

/* Re-seeds every random stream. Same seed + same parameters = same piece,
 * which is what makes the thing testable at all. */
NE_API void ne_set_seed(ne_engine* e, uint32_t seed);

/* ------------------------------------------------------------- introspection */

NE_API void ne_get_vis(ne_engine* e, ne_vis* out);

/* Human-readable name of a mood, for the UI. Static storage, never null. */
NE_API const char* ne_mood_name(int mood);

/* Seconds of audio produced since ne_create. */
NE_API double ne_elapsed(const ne_engine* e);

#ifdef __cplusplus
}
#endif
#endif /* NULLEIG_H */
