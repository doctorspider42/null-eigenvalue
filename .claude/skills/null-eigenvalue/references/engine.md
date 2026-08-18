# The engine

One C++ core, compiled five ways, playing on the OS audio thread. Dart never
generates a sample; it stores atomics and reads a few back.

## The files

| file | what is in it |
|---|---|
| `src/nulleig.h` | the public C API - the only thing Dart and the render harness see |
| `src/api.cpp` | the C entry points, the miniaudio device, the watchdog |
| `src/engine.h` | the engine object: parameters as atomics, the render entry |
| `src/engine.cpp` | voices, weather, the root walk, effects - the synthesis |
| `src/harmony.h` | scales, consonance weighting, which note a voice takes next |
| `src/dsp.h` | oscillators, filters, the FDN reverb, chorus, delays |
| `src/tables.h` | mip-mapped band-limited wavetables |
| `src/third_party/miniaudio.h` | the audio device, single header |

`lib/nulleig.dart` is the Dart side of `nulleig.h` and is the whole contract:
every call in it is a store to an atomic or a load of one - nanoseconds - which
is why the binding is synchronous and there is no isolate anywhere.

## The audio thread rules

`ne_render` and everything it reaches runs on the OS audio callback. A stall
there is an audible dropout on a device with no console attached, so:

- no allocation, no `new`, no container that might grow;
- no locks, no I/O, no logging;
- no unbounded loops - the work per callback must be bounded by the frame count;
- parameters arrive only as atomics, `memory_order_relaxed`, one store per
  setter (a finger moving at 120 Hz costs two stores, which is the point);
- anything that must be computed when a parameter changes (filter coefficients
  for the weather, the reverb's decay) is recomputed when the value has moved
  enough to matter, not on every callback and not on the Dart side.

The engine keeps playing while the Flutter engine is suspended. That is the
whole architecture: nothing about playback may depend on Dart running.

## Two design decisions worth not re-litigating

**Nothing repeats and no progression exists.** Fourteen voices over a fixed
root; twelve of them fade in and out on periods spaced by the golden ratio, so
the combination recurs on a timescale of days. A voice only changes pitch while
it is inaudible, which is why the harmony can move without anything gliding.
A chord progression would announce itself as a loop the second time round.

**Speed is a scaling of every clock, not a tempo.** It multiplies each `dt` in
the piece at once - breathing, drift, the root walk, the bells, the weather.
Because it scales a derivative rather than a value, changing it cannot click,
which is why it needs no smoothing. Pitch is added where a MIDI number becomes
a frequency and nowhere else, so the harmony, the registers and the scale all
stay in their own coordinates and every interval survives a transposition.

## Adding a parameter, end to end

The FFI boundary is easy to half-cross. All of these, in order:

1. `src/nulleig.h` - the setter (and getter, if the UI needs to read it back),
   with a comment saying what the units are and what the range means.
2. `src/engine.h` - an atomic, a clamped setter, a reader used by the render.
3. `src/engine.cpp` - use it. If it changes a filter coefficient rather than a
   `dt`, recompute on a threshold rather than per callback.
4. `src/api.cpp` - the `NE_API` function forwarding to the engine.
5. `packages/nulleig/lib/nulleig.dart` - the `lookupFunction` and the Dart
   setter. If it touches `ne_vis` or `ne_status`, update the `Struct` too:
   those are copied by layout, so a mismatch reads garbage rather than failing.
6. `lib/src/drone_controller.dart` - the app's own state, persistence in
   `_save`/`restore`, and the call into the engine. Note the pattern used by
   the field and the second field: what is persisted is the raw accumulator,
   and shaping (dead-bands, clamps) is applied on the way out.
7. The UI - a gesture, a key, or a control in the panel - and the picture, if
   the parameter is something you should be able to see.
8. `tools/render/main.cpp` - a flag for it, so it can be listened to offline
   without a device. Every parameter that changes the sound has one.
9. `test/widget_test.dart` - if the parameter has shaping worth pinning (the
   detent maths is the model to copy), pin it there.
10. The README, in `## Using it` and `## How the music works`.

## Checking a DSP change

```bash
cmake -S tools/render -B tools/render/build -DCMAKE_BUILD_TYPE=Release
cmake --build tools/render/build -j
./tools/render/build/nulleig_render out.wav 180 --mood 2
./tools/render/build/nulleig_render low.wav 120 --pitch -5 --speed 2.5
./tools/render/build/nulleig_render tour.wav 360 --tour
```

On Windows the generator is multi-config, so those last two lines are
`cmake --build tools/render/build --config Release` and the binary is at
`tools/render/build/Release/nulleig_render.exe`. The README's snippet is the
single-config path CI and a Mac take.

`--tour` walks both axes and every mood transition, which is where a
synthesizer usually breaks. The report is the test: peak (clipping), per-second
RMS spread (a swell is fine, a nine-to-one range is not), DC offset, NaN count,
dropouts, and how often the harmony moved. Non-zero exit means one of those is
out of bounds, and CI runs the same thing over all six moods and uploads the
WAVs as an artifact so a change can be listened to before it reaches a device.

A NaN is the one failure that never recovers: the FDN feeds back, so a single
NaN poisons the tail forever. That is also why the Android and Linux builds use
`-ffast-math -fno-finite-math-only` rather than plain fast-math, and why MSVC
takes the default floating point model - `/fp:fast` has no way to say "fast,
but infinities are real".
