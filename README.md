# Null Eigenvalue

A generative drone instrument for the phone. One screen, five moods, no end.

It synthesises continuously — nothing is streamed and nothing is a loop — and
it keeps playing with the screen off, with play, pause and mood change on the
lock screen.

<p align="center">
  <img src="ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png" width="180" alt="">
</p>

---

## Using it

Drag anywhere. The screen is a 2D field:

- **left ↔ right** is brightness — subterranean at one edge, glassy at the other;
- **down ↕ up** is density — a bare drone at the bottom, four octaves of moving
  voices at the top.

A fast drag is heard as well as seen: it briefly excites the instrument, so the
gesture has a sound of its own and not only a result.

Tap once to show the transport and the five moods; it hides itself again after
a few seconds. While it is silent, tapping anywhere starts it.

**Kernel** is the null space, as low and as still as the thing goes.
**Manifold** is the warm, wide default. **Halo** is lydian, high, shimmering,
and the only mood that rings. **Torsion** is tense and metallic. **Limit** is
the piece as it stops: the fewest voices, the longest breaths and a
thirty-second room. **Entropy** is the classic drone — something hums,
something hisses; the noise bed is the instrument and the pitched voices are
the accompaniment, on an open fifth with no third in it at all.

From a lock screen, a headphone remote or a car, **next / previous track**
changes mood.

## Installing it

Every push to `main` publishes a
[release](https://github.com/doctorspider42/null-eigenvalue/releases) with both
builds.

**iPhone.** The `.ipa` is unsigned. The least painful route is to add this
source to AltStore once:

```
https://doctorspider42.github.io/null-eigenvalue/altstore.json
```

From then on every push to `main` shows up on the phone as an update, with no
cable and no computer in the loop — CI regenerates that manifest and publishes
it as part of the same run that builds the release.

Otherwise sign and install the `.ipa` by hand with
[AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io) using
your own Apple ID. A free account works and costs nothing; the app then has to
be re-signed every seven days, which AltStore does by itself while it is on the
same network as its desktop half.

**Android.** The `.apk` installs directly. It is signed with a debug key, so
the phone will ask you to allow installs from wherever you downloaded it.

## How the music works

The hard part of a generative drone is not making a nice sound. It is making
one that is still interesting in twenty minutes without ever doing anything
sudden. Two obvious designs both fail: a fixed chord is a texture you have
heard all of within ninety seconds, and a chord *progression* announces itself
as a loop the second time round.

So there is no progression.

**A fixed root, and voices that breathe.** Fourteen voices sit above a drone
root. Two of them *are* the drone and never leave. The other twelve each fade
in and out on a period of their own, between 24 and 86 seconds, and those
periods are spaced by the golden ratio — no two alike, no two in any simple
ratio. The *combination* of which voices are sounding therefore has a
recurrence time measured in days. Nothing repeats, and no random number was
involved in the timing.

**Voices only change pitch while silent.** Every time a voice comes back in it
takes a new note. Because it is inaudible at that moment, nothing has to
crossfade or glide: the harmony can move as much as it likes and you never hear
a change happen. You notice, half a minute later, that the chord is somewhere
else.

**The new note is chosen by how it sounds.** Candidates come from the mood's
scale, weighted by consonance against the voices that are *currently audible*
(weighted by how audible each one is), by how well the note fits that voice's
preferred register, and against repeating what that voice played last time.
That is what keeps twelve independently wandering voices reading as one harmony
instead of a cluster.

**The root itself walks.** Every few minutes it moves by a fifth or a third,
with a restoring pull so it cannot wander out of its register. Voices keep
their offsets, so the whole field transposes at once — the one event in the
piece big enough to notice while it is happening.

**Weather.** Brightness, density and the size of the room are also pushed
around by pink noise, generated at a quarter of a hertz and smoothed over tens
of seconds. 1/f has structure at every timescale, which is why the piece gets
stretches of calm and then a swell, where an LFO would just have a visible
period.

Underneath all of that: mip-mapped band-limited wavetables (a drone gives you
all day to hear aliasing), a per-voice detuned unison with slow random drift,
an 8-line feedback delay network with a Hadamard mixing matrix for the tail — a
comb bank rings metallic long before the twenty seconds this needs — with
per-line damping, modulated line lengths and a pitch-shifted feedback path for
shimmer, a ping-pong delay, an ensemble chorus, and a bass sum to mono below
130 Hz because a wide low end collapses on a phone speaker.

## How the picture works

Everything glowing is one white blob texture, tinted and added. The composition
is a direct reading of the synthesizer: the core is the drone, the eight orbs
are the register slices the engine publishes, a slow ring expands each time a
voice takes a new pitch, and a point of light flashes for every bell. The
engine hands the UI eight numbers and a few scalars; there is no FFT and no
second thread.

## How it is built

```
lib/                     the app: one screen, one painter, one controller
packages/nulleig/        the engine
  src/                     C++: synthesis, harmony, effects, and the device
  ios/Classes/*.mm         forwarders, so CocoaPods compiles src/ into the app
  lib/nulleig.dart         the FFI binding
tools/render/            desktop harness: renders a WAV and measures it
tools/icons/             regenerates every launcher icon
```

The engine is one C++ core compiled three ways: into the iOS app binary by the
podspec, into `libnulleig.so` by CMake for Android, and into a desktop program
that renders WAV files. Audio is produced on the OS audio thread by
[miniaudio](https://miniaud.io) — Dart is never in the path, which is what lets
the drone survive a Flutter engine that has been suspended behind a locked
screen. Dart sets a handful of atomics and reads a few back for the visuals.

### Hearing a change without a phone

```bash
cmake -S tools/render -B tools/render/build -DCMAKE_BUILD_TYPE=Release
cmake --build tools/render/build
./tools/render/build/nulleig_render out.wav 180 --mood 2
./tools/render/build/nulleig_render tour.wav 360 --tour
```

It prints peak, per-second RMS spread, DC offset, a NaN count, a dropout count
and how often the harmony moved, and exits non-zero if any of those is wrong.
CI runs it over every mood on each push, and uploads the audio, so a change to
the DSP can be listened to before it reaches a device.

### Looking at the UI without a phone

```bash
flutter test tools/preview/preview_test.dart   # writes tools/preview/out/*.png
```

The widget tester rasterises with a real canvas, so those PNGs are what the
painter will actually draw. They are posed from hand-written engine snapshots,
which is the point: the field can be put in states that would take twenty
minutes of listening to catch by accident. (Text comes out as boxes — the test
environment has no real font. Layout and metrics are still true.)

### Building the app

```bash
flutter pub get
flutter build apk --release
flutter build ios --release --no-codesign
```

## Licence

MIT. Every dependency is permissive: Flutter (BSD-3), miniaudio (public domain
or MIT-0), `audio_service` (MIT), `shared_preferences` (BSD-3). Nothing here is
copyleft, so a build of this can be shipped under whatever terms you like.
