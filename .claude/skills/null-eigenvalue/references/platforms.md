# Five builds, one core

The same C++ reaches every platform, but by five different routes. Adding or
renaming a file under `packages/nulleig/src/` means visiting all of them, or
one platform links and the rest do not - and nothing tells you until that
platform's job fails in CI.

| platform | how the engine gets in | flags |
|---|---|---|
| iOS | `ios/nulleig.podspec` compiles `src/` via forwarders in `ios/Classes/*.mm` | podspec xcconfig |
| macOS | `macos/nulleig.podspec`, same two forwarders | podspec xcconfig |
| Android | `android/build.gradle` points at `src/CMakeLists.txt` → `libnulleig.so` | `-O3 -ffast-math -fno-finite-math-only` |
| Linux | `linux/CMakeLists.txt`, same sources | the same three |
| Windows | `windows/CMakeLists.txt` → `nulleig.dll` | `/EHsc`, and `/O2` for non-Debug only |

`-ffast-math` without `-fno-finite-math-only` would let the compiler assume
infinities cannot happen; a feedback delay network that meets one never
recovers. MSVC has no equivalent split, so the Windows build takes the default
floating point model. `/O2` is excluded from Debug because Flutter's Debug
configuration carries `/RTC1` and MSVC refuses both on one command line - which
used to mean `flutter run -d windows` could not build at all.

Dart resolves the library at run time out of the process image on Apple
platforms and by file name elsewhere; see `DroneEngine.create` in
`packages/nulleig/lib/nulleig.dart` for the exact per-platform lookup.

## What differs above the engine

- **`lib/src/platform.dart` is the only file that asks which platform this
  is.** `isDesktop`, `isMobile`, `isTv`, `hasMediaSession`. Keep it that way -
  the desktop build is the same app with different edges, not a second screen.
- **Television.** The same APK. A leanback launcher entry in the manifest is
  what makes a set show it, and `detectTv()` in `main.dart` asks the system at
  startup - before anything reads `isTv`, which is most of what follows.
- **Media session.** `audio_service` has no Windows or Linux implementation, so
  `AudioService.init` is guarded by `hasMediaSession`: calling it there would
  sit until an eight-second timeout at every launch to learn something known at
  compile time. macOS does have one and it is worth having.
- **The updater** (`lib/src/updater.dart`) is desktop-only and asks GitHub for
  the newest release once per launch, at most every six hours, several seconds
  after audio is already running - a slow network must never be between the
  user and the first sound. Phones update through AltStore instead.

## CI, and what each job protects

`.github/workflows/build.yml` runs on every push to `main`, on every pull
request, and on demand.

- `version` - one place decides the name: `0.1.<run number>`, from the minor in
  `pubspec.yaml`. Every push to main is therefore strictly newer than the last,
  which is what AltStore compares.
- `checks` - `flutter analyze`, `flutter test`, then it builds the offline
  renderer and renders every mood plus the tour, uploading the WAVs. This is
  the DSP gate and it runs in about a minute.
- `android` - builds the APK and then checks two things that break silently:
  that `lib/arm64-v8a/libnulleig.so` is actually in it (an APK without it
  installs, opens, and says the engine did not load), and that the manifest
  still has `leanback-launchable-activity` (without it a television installs
  the app and then offers no way to start it).
- `ios` - unsigned, then greps the bundle for the engine symbol rather than for
  a file, because whether the pod ended up static or as an embedded framework
  is CocoaPods' business and both are fine for `dlsym`.
- `windows`, `macos-desktop`, `linux-desktop` - the installer, the disk image
  and the AppImage.

A pull request runs all of it without publishing. **A push to `main` publishes
a release**, and `altstore-source.yml` then regenerates `altstore.json` and
commits it with `[skip ci]` so a phone on that source sees the update. There is
no manual release step and no way to withdraw a version once phones have seen
it - which is the argument for doing the work on a branch and merging green.

## Signing, and why there is none

The iOS build is unsigned on purpose: there are no Apple credentials in this
repository and there are not going to be. AltStore or Sideloadly signs it with
the user's own free Apple ID at install time. The Android APK is signed with
the debug key, the Windows installer is unsigned (SmartScreen will say so), and
the Mac app is signed to itself and not notarised, so the first launch has to
be right-click → Open. All four of those are documented in the README's
`## Installing it`; if you change one, change that too.
