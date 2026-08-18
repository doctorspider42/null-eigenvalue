---
name: null-eigenvalue
description: How Null Eigenvalue is put together and how to change it safely - a Flutter app around a C++ synthesis engine over FFI, shipped to five platforms from one repository. Use this whenever you are working in this repository at all: editing the Dart UI or the picture, touching the C++ DSP, adding a parameter, changing a platform build, CI or the release flow, or answering "how do I run this locally", "what do I need installed", "why did my change not take effect". Do not skip it for small edits - the things that break silently here (the audio thread, the constants Dart and C++ both hold, the five builds, a release cut by every push to main) are exactly what a small edit touches.
---

# Working on Null Eigenvalue

A generative drone instrument: one screen, six moods, no end. It synthesises
continuously - nothing is streamed, nothing is a loop - and keeps playing with
the screen off, with play, pause and mood change on the lock screen. The same
code runs on a phone, a television, and three desktops.

Two properties shape almost every decision here, and knowing them saves you
from proposing things the design has already rejected:

- **The audio must survive the UI being suspended.** Sound is made on the OS
  audio thread inside C++. Dart is never in the audio path; it sets a handful
  of atomics and reads a few back. Any design that puts Dart between the
  synthesizer and the speaker is wrong here, however convenient.
- **The picture is a reading of the synthesizer, not a decoration.** Every
  glowing thing on screen corresponds to something the engine publishes. When
  you add a visual, connect it to a real quantity; when you add an engine
  parameter, ask what it looks like.

The README is the design document and is genuinely worth reading before a
substantial change - `## How the music works` and `## How the picture works`
explain why things are the way they are, and it is part of the deliverable
(see House style below).

## The map

```
lib/                       the app: one screen, one painter, one controller
  main.dart                  wiring: engine, media session, textures, TV check
  src/field_screen.dart      the screen: gestures, keyboard, D-pad, chrome
  src/nebula.dart            the picture: NebulaState (sim) + NebulaPainter
  src/drone_controller.dart  owns the engine and the durable state
  src/palette.dart           six moods as four colour stops each
  src/hud.dart               transport, mood dots, settings panel, TV rings
  src/audio_handler.dart     audio_service bridge (lock screen, media keys)
  src/platform.dart          the only file that asks which platform this is
  src/updater.dart           desktop-only: notices a new GitHub release
  src/textures.dart          the two generated textures (blob, grain)
packages/nulleig/          the engine, as a Flutter plugin
  src/*.h, *.cpp             the C++ core: synthesis, harmony, effects, device
  lib/nulleig.dart           the FFI binding - the whole Dart/C++ contract
  ios/, macos/               podspecs that compile src/ into the app
  android/, linux/, windows/ CMake, one target each, same sources
test/widget_test.dart      the constants and colour maths (no engine, no app)
tools/preview/             renders the real painter to PNGs, no phone needed
tools/render/              renders the real engine to WAV and measures it
tools/icons/               regenerates every launcher icon (Pillow + numpy)
tools/altstore/            builds altstore.json from the releases API
.github/workflows/         build.yml cuts a release from every push to main
```

## Running it locally

`flutter --version` must be **3.47.0** to match CI. Then `flutter pub get`.

| target | what you need beyond Flutter | command |
|---|---|---|
| Windows | Visual Studio with the C++ desktop workload | `flutter run -d windows` |
| macOS | Xcode + CocoaPods | `flutter run -d macos` |
| Linux | GTK 3 dev headers, ninja, clang, pkg-config | `flutter run -d linux` |
| Android / TV | Android SDK + **NDK 28.2.13676358** and cmake 3.22.1 | `flutter run -d <device>` |
| iOS | Xcode + CocoaPods; unsigned in CI, sign locally to run | `flutter run -d <device>` |

The desktop build is the fastest way to feel a change, and the one place you
can drive the app without a device. Two things about it that cost time if you
learn them the hard way:

- **The chrome hides itself.** Move the mouse to raise it; it goes away after
  four seconds. `D` toggles the diagnostics block, but that block lives inside
  the chrome, so a drag - which hides the chrome - hides the reading with it.
- **State outlives the process.** Mood, field position, volume, pitch and speed
  are all remembered in
  `%APPDATA%\Null Eigenvalue\Null Eigenvalue\shared_preferences.json` (and the
  platform equivalent elsewhere). An app that comes back transposed an octave
  and playing at 3x is remembering, not broken. Delete that file to get a
  first-launch app back.

## The loop: how to know a change works

In rough order of cost. Run the ones that can see your change; say which you
ran and what they said.

```bash
flutter analyze                              # zero issues is the standard here
flutter test                                 # constants, colour maths, updater logic
flutter test tools/preview/preview_test.dart # writes tools/preview/out/*.png
```

`flutter test` never builds the app or loads the engine - the engine is a
device binary that does not exist on a test host, and a golden test of a
nebula animated by a random walk fails on Tuesdays. What it pins is the
boundary: the constants Dart and C++ must agree on, and the colour maths the
whole look rests on. Add to it when you add either.

The preview harness is how a visual change is judged without a device: it
rasterises the real painter at phone, desktop and television sizes from
hand-written engine snapshots, so the field can be posed in states that would
take twenty minutes of listening to catch. **Look at the PNGs it writes** -
that is the point of it. Text comes out as boxes; the test environment has no
font, and layout and metrics are still true.

For anything that changes what the synthesizer does:

```bash
cmake -S tools/render -B tools/render/build -DCMAKE_BUILD_TYPE=Release
cmake --build tools/render/build -j
./tools/render/build/nulleig_render out.wav 180 --mood 2
./tools/render/build/nulleig_render tour.wav 360 --tour
```

It prints peak, per-second RMS spread, DC offset, NaN count, dropouts and how
often the harmony moved, and exits non-zero when any of those is wrong. CI runs
it over every mood on each push, so a DSP change that clips or falls silent
fails there rather than in someone's headphones.

## What breaks silently here

These are the ones that do not announce themselves - no crash, no red test,
just an app that is subtly wrong or a platform that stopped working.

- **`neMoodCount` in `nulleig.dart` and `NE_MOOD_COUNT` in `nulleig.h` and the
  length of `MoodPalette.all`.** Three places, one number. A test asserts the
  last two agree; that test exists because indexing past the palette list is a
  range error the first time someone taps the last dot.
- **The audio thread.** No allocation, no locks, no logging, nothing that can
  block, inside anything reachable from `ne_render`. See
  `references/engine.md` before touching the C++.
- **`ne_vis` and `_NeVis`.** A field added on one side and not the other reads
  garbage rather than failing - the struct is copied by layout, not by name.
- **The five builds.** Adding a source file to `src/` means adding it to the
  CMake targets *and* the podspecs, or one platform links fine and the other
  four do not. See `references/platforms.md`.
- **Every push to `main` cuts a public release**, versioned `0.1.<run number>`,
  which phones then offer as an update. There is no separate release step to
  forget - and no way to un-ship. Work on a branch, open a PR (CI runs the same
  matrix on pull requests), and merge when it is green.
- **Repaint discipline.** The field changes on every pointer move and the
  painter already repaints every frame from a ticker. `setField` deliberately
  does not `notifyListeners` - rebuilding the widget tree at 120 Hz for a value
  no widget reads is pure waste. Do not "fix" that by adding a notify.

## House style

This repository is written, not just typed, and a change that ignores that
reads as foreign however correct it is.

- **Comments say why, not what.** The interesting comments here record the
  version that did not work and the reason it did not - "tracking the finger
  exactly was the first version and it is wrong: it left two thirds of the
  screen dead black". If you fixed something subtle, that reasoning belongs in
  the file next to it. Avoid shouty MUST/NEVER; explain instead.
- **The README is part of the change.** A user-visible feature that is not in
  the README is half delivered. Match its register: prose, em dashes, no
  bullet-point marketing.
- **Commit messages are essays.** Look at `git log` before writing one. A
  title that is a phrase rather than a summary ("A remote, three metres away",
  "Debug is not a configuration to optimise"), then paragraphs explaining the
  problem, what was rejected and why the chosen shape is the right one.
- **British spelling** in prose and identifiers (`colour`, `centre`).

## Where to go next

- `references/engine.md` - the C++ core, the FFI contract, the audio-thread
  rules, and the end-to-end recipe for adding an engine parameter.
- `references/picture.md` - the painter and its state, the palette rules, the
  chrome, and how to add a preview shot.
- `references/platforms.md` - how the engine gets into each of the five
  builds, what CI checks, and how a release actually reaches a phone.
