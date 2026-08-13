/// Dart's side of the synthesis engine.
///
/// The binding is deliberately thin and deliberately synchronous. Every call
/// here is a store to an atomic or a read of one - nanoseconds - so there is
/// nothing to await and no isolate to hop to. The audio itself never crosses
/// this boundary: it is generated on the OS audio thread inside the C++, which
/// is what lets the app keep playing while Flutter is suspended behind a
/// locked screen.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Register slices published for the visuals, low to high.
const int neBands = 8;

/// How many moods the engine knows. Kept in step with `NE_MOOD_COUNT`.
const int neMoodCount = 5;

/// Mirrors `ne_vis`. Every field is a float except the last, so the layout is
/// the obvious one and needs no padding.
final class _NeVis extends Struct {
  @Float()
  external double level;
  @Float()
  external double centroid;
  @Array(neBands)
  external Array<Float> band;
  @Float()
  external double spark;
  @Float()
  external double rootHz;
  @Float()
  external double motion;
  @Float()
  external double gate;
  @Int32()
  external int chordChange;
}

/// A snapshot of what the engine is doing, as plain Dart values.
class DroneVis {
  const DroneVis({
    required this.level,
    required this.centroid,
    required this.bands,
    required this.spark,
    required this.rootHz,
    required this.motion,
    required this.gate,
    required this.chordChange,
  });

  /// Smoothed master peak, 0..1.
  final double level;

  /// Perceived brightness, 0..1.
  final double centroid;

  /// Energy per register slice, low first. Length is [neBands].
  final List<double> bands;

  /// Decays after each bell strike, 0..1.
  final double spark;

  /// The drone's current fundamental.
  final double rootHz;

  /// How much the harmony has moved recently, 0..1.
  final double motion;

  /// Master fade: 0 while paused, 1 while playing.
  final double gate;

  /// Increments every time a voice takes a new pitch.
  final int chordChange;

  static const empty = DroneVis(
    level: 0,
    centroid: 0.5,
    bands: <double>[0, 0, 0, 0, 0, 0, 0, 0],
    spark: 0,
    rootHz: 55,
    motion: 0,
    gate: 0,
    chordChange: 0,
  );
}

typedef _Create = Pointer<Void> Function(int);
typedef _CreateC = Pointer<Void> Function(Int32);
typedef _Void1 = void Function(Pointer<Void>);
typedef _Void1C = Void Function(Pointer<Void>);
typedef _Int1 = int Function(Pointer<Void>);
typedef _Int1C = Int32 Function(Pointer<Void>);
typedef _SetInt = void Function(Pointer<Void>, int);
typedef _SetIntC = Void Function(Pointer<Void>, Int32);
typedef _SetFloat = void Function(Pointer<Void>, double);
typedef _SetFloatC = Void Function(Pointer<Void>, Float);
typedef _SetXY = void Function(Pointer<Void>, double, double);
typedef _SetXYC = Void Function(Pointer<Void>, Float, Float);
typedef _SetTouch = void Function(Pointer<Void>, int, double);
typedef _SetTouchC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetSeed = void Function(Pointer<Void>, int);
typedef _SetSeedC = Void Function(Pointer<Void>, Uint32);
typedef _GetVis = void Function(Pointer<Void>, Pointer<_NeVis>);
typedef _GetVisC = Void Function(Pointer<Void>, Pointer<_NeVis>);
typedef _MoodName = Pointer<Utf8> Function(int);
typedef _MoodNameC = Pointer<Utf8> Function(Int32);
typedef _Elapsed = double Function(Pointer<Void>);
typedef _ElapsedC = Double Function(Pointer<Void>);

DynamicLibrary _open() {
  // On iOS the engine is compiled into the app binary by the podspec rather
  // than shipped as a dylib, so there is nothing to open - the symbols are
  // already in the process.
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libnulleig.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('nulleig.dll');
  throw UnsupportedError('Null Eigenvalue has no engine for this platform');
}

/// The synthesizer. One per app; creating a second one would open a second
/// audio device and both would fight over the session.
class DroneEngine {
  DroneEngine._(this._lib, this._handle);

  /// Builds the engine and its wavetables. Costs a couple of hundred
  /// milliseconds of table generation, so call it once, at startup, before the
  /// first frame if you can.
  factory DroneEngine.create({int sampleRate = 48000}) {
    final lib = _open();
    final create = lib.lookupFunction<_CreateC, _Create>('ne_create');
    final handle = create(sampleRate);
    if (handle == nullptr) {
      throw StateError('ne_create returned null');
    }
    return DroneEngine._(lib, handle);
  }

  final DynamicLibrary _lib;
  Pointer<Void> _handle;

  late final _destroy = _lib.lookupFunction<_Void1C, _Void1>('ne_destroy');
  late final _start = _lib.lookupFunction<_Int1C, _Int1>('ne_start');
  late final _stop = _lib.lookupFunction<_Void1C, _Void1>('ne_stop');
  late final _setMood = _lib.lookupFunction<_SetIntC, _SetInt>('ne_set_mood');
  late final _getMood = _lib.lookupFunction<_Int1C, _Int1>('ne_mood');
  late final _setField = _lib.lookupFunction<_SetXYC, _SetXY>('ne_set_field');
  late final _setTouch =
      _lib.lookupFunction<_SetTouchC, _SetTouch>('ne_set_touch');
  late final _setPlaying =
      _lib.lookupFunction<_SetIntC, _SetInt>('ne_set_playing');
  late final _isPlaying = _lib.lookupFunction<_Int1C, _Int1>('ne_playing');
  late final _setGain =
      _lib.lookupFunction<_SetFloatC, _SetFloat>('ne_set_gain');
  late final _setSeed =
      _lib.lookupFunction<_SetSeedC, _SetSeed>('ne_set_seed');
  late final _getVisFn =
      _lib.lookupFunction<_GetVisC, _GetVis>('ne_get_vis');
  late final _moodNameFn =
      _lib.lookupFunction<_MoodNameC, _MoodName>('ne_mood_name');
  late final _elapsedFn =
      _lib.lookupFunction<_ElapsedC, _Elapsed>('ne_elapsed');

  // Reused so that polling the visuals sixty times a second allocates nothing.
  final Pointer<_NeVis> _visBuf = calloc<_NeVis>();

  bool _disposed = false;

  /// Opens the audio device. Returns true on success; a device that cannot be
  /// opened is worth surfacing, because on iOS it means no background
  /// execution either.
  bool startDevice() => !_disposed && _start(_handle) == 0;

  /// Closes the device. Not the same as pausing - see [playing]. The app only
  /// does this on disposal, because a closed device on iOS drops the audio
  /// session and with it the lock-screen controls.
  void stopDevice() {
    if (!_disposed) _stop(_handle);
  }

  set mood(int value) {
    if (!_disposed) _setMood(_handle, value.clamp(0, neMoodCount - 1));
  }

  int get mood => _disposed ? 0 : _getMood(_handle);

  /// The 2D field. `x` is brightness, `y` is density, both 0..1.
  void setField(double x, double y) {
    if (!_disposed) _setField(_handle, x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  /// `speed` in screen-widths per second; it drives the excitation that makes
  /// a fast drag audible rather than merely effective.
  void setTouch({required bool active, double speed = 0}) {
    if (!_disposed) _setTouch(_handle, active ? 1 : 0, speed);
  }

  set playing(bool value) {
    if (!_disposed) _setPlaying(_handle, value ? 1 : 0);
  }

  bool get playing => !_disposed && _isPlaying(_handle) != 0;

  set gain(double value) {
    if (!_disposed) _setGain(_handle, value.clamp(0.0, 1.0));
  }

  set seed(int value) {
    if (!_disposed) _setSeed(_handle, value & 0xFFFFFFFF);
  }

  double get elapsedSeconds => _disposed ? 0 : _elapsedFn(_handle);

  /// Reads the current state. Cheap enough to call every frame.
  DroneVis vis() {
    if (_disposed) return DroneVis.empty;
    _getVisFn(_handle, _visBuf);
    final v = _visBuf.ref;
    return DroneVis(
      level: v.level,
      centroid: v.centroid,
      bands: List<double>.generate(neBands, (i) => v.band[i], growable: false),
      spark: v.spark,
      rootHz: v.rootHz,
      motion: v.motion,
      gate: v.gate,
      chordChange: v.chordChange,
    );
  }

  String moodName(int index) =>
      _moodNameFn(index.clamp(0, neMoodCount - 1)).toDartString();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stop(_handle);
    _destroy(_handle);
    _handle = nullptr;
    calloc.free(_visBuf);
  }
}
