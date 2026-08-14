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

/// How many moods the engine knows. Must equal `NE_MOOD_COUNT` in nulleig.h;
/// a test in the app asserts that this and the palette list agree, which is
/// the only thing standing between a new mood in C++ and a range error the
/// first time someone taps the last dot.
const int neMoodCount = 6;

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

/// Mirrors `ne_status`.
final class _NeStatus extends Struct {
  @Int32()
  external int started;
  @Int32()
  external int maContext;
  @Int32()
  external int maDeviceInit;
  @Int32()
  external int maDeviceStart;
  @Int32()
  external int deviceState;
  @Int32()
  external int sampleRate;
  @Uint32()
  external int callbacks;
  @Double()
  external double elapsed;
}

/// Why there is no sound.
///
/// Silence has several very different causes that look identical from the
/// outside, and on a sideloaded build there is no console to tell them apart.
/// [callbacks] is the one that splits the problem in half: still zero and the
/// OS is not asking us for audio at all, so it is the device or the session;
/// rising while nothing is heard and the fault is downstream of us.
class DroneStatus {
  const DroneStatus({
    required this.started,
    required this.maContext,
    required this.maDeviceInit,
    required this.maDeviceStart,
    required this.deviceState,
    required this.sampleRate,
    required this.callbacks,
    required this.elapsed,
  });

  final bool started;
  final int maContext;
  final int maDeviceInit;
  final int maDeviceStart;
  final int deviceState;
  final int sampleRate;
  final int callbacks;
  final double elapsed;

  static const unknown = DroneStatus(
    started: false,
    maContext: -999,
    maDeviceInit: -999,
    maDeviceStart: -999,
    deviceState: -1,
    sampleRate: 0,
    callbacks: 0,
    elapsed: 0,
  );

  /// One line, short enough for the bottom of the screen and complete enough
  /// to act on from a screenshot.
  String get line => 'dev ${started ? "ok" : "FAIL"}'
      ' ctx$maContext/init$maDeviceInit/start$maDeviceStart'
      ' st$deviceState ${sampleRate}Hz'
      ' cb$callbacks t${elapsed.toStringAsFixed(1)}';
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
typedef _SetDouble = void Function(Pointer<Void>, double);
typedef _SetDoubleC = Void Function(Pointer<Void>, Double);
typedef _GetVis = void Function(Pointer<Void>, Pointer<_NeVis>);
typedef _GetVisC = Void Function(Pointer<Void>, Pointer<_NeVis>);
typedef _GetStatus = void Function(Pointer<Void>, Pointer<_NeStatus>);
typedef _GetStatusC = Void Function(Pointer<Void>, Pointer<_NeStatus>);
typedef _SessionInfo = void Function(Pointer<Uint8>, int);
typedef _SessionInfoC = Void Function(Pointer<Uint8>, Int32);
typedef _MoodName = Pointer<Utf8> Function(int);
typedef _MoodNameC = Pointer<Utf8> Function(Int32);
typedef _Elapsed = double Function(Pointer<Void>);
typedef _ElapsedC = Double Function(Pointer<Void>);

DynamicLibrary _open() {
  if (Platform.isIOS || Platform.isMacOS) {
    // Where the engine ends up on Apple platforms is CocoaPods' decision, not
    // ours. Flutter's generated Podfile uses `use_frameworks!`, so the pod
    // becomes an embedded dynamic framework and its symbols are visible to
    // dlsym across the whole process; a statically linked pod would put them
    // in the app binary instead. Probe for the first case rather than assume
    // it, because assuming wrong is a crash on launch with no useful message.
    final process = DynamicLibrary.process();
    try {
      process.lookup<NativeFunction<_CreateC>>('ne_create');
      return process;
    } on ArgumentError {
      return DynamicLibrary.open('nulleig.framework/nulleig');
    }
  }
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
  late final _setSleepFn =
      _lib.lookupFunction<_SetDoubleC, _SetDouble>('ne_set_sleep');
  late final _sleepRemainingFn =
      _lib.lookupFunction<_ElapsedC, _Elapsed>('ne_sleep_remaining');
  late final _getVisFn =
      _lib.lookupFunction<_GetVisC, _GetVis>('ne_get_vis');
  late final _getStatusFn =
      _lib.lookupFunction<_GetStatusC, _GetStatus>('ne_get_status');
  late final _moodNameFn =
      _lib.lookupFunction<_MoodNameC, _MoodName>('ne_mood_name');
  late final _elapsedFn =
      _lib.lookupFunction<_ElapsedC, _Elapsed>('ne_elapsed');

  // Reused so that polling the visuals sixty times a second allocates nothing.
  final Pointer<_NeVis> _visBuf = calloc<_NeVis>();
  final Pointer<_NeStatus> _statusBuf = calloc<_NeStatus>();
  static const int _sessionCap = 160;
  final Pointer<Uint8> _sessionBuf = calloc<Uint8>(_sessionCap);

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

  /// Arms the sleep timer for [d] from now, or disarms it when [d] is null.
  /// The countdown itself lives on the audio thread - see ne_set_sleep - so
  /// it survives a locked screen and a suspended UI.
  void setSleep(Duration? d) {
    if (_disposed) return;
    _setSleepFn(_handle, d == null ? 0 : d.inMilliseconds / 1000.0);
  }

  /// Seconds until sleep fires, or null when no timer is armed.
  double? get sleepRemaining {
    if (_disposed) return null;
    final s = _sleepRemainingFn(_handle);
    return s < 0 ? null : s;
  }

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

  /// Device and callback state. Cheap; safe to poll.
  DroneStatus status() {
    if (_disposed) return DroneStatus.unknown;
    _getStatusFn(_handle, _statusBuf);
    final s = _statusBuf.ref;
    return DroneStatus(
      started: s.started != 0,
      maContext: s.maContext,
      maDeviceInit: s.maDeviceInit,
      maDeviceStart: s.maDeviceStart,
      deviceState: s.deviceState,
      sampleRate: s.sampleRate,
      callbacks: s.callbacks,
      elapsed: s.elapsed,
    );
  }

  String moodName(int index) =>
      _moodNameFn(index.clamp(0, neMoodCount - 1)).toDartString();

  /// What the OS audio session says about itself: category, output route,
  /// media volume. Empty everywhere but iOS, and empty against an engine
  /// binary that predates the symbol - the diagnostics must never be the
  /// thing that crashes the app they are diagnosing.
  String sessionInfo() {
    if (_disposed) return '';
    final _SessionInfo fn;
    try {
      fn = _lib.lookupFunction<_SessionInfoC, _SessionInfo>('ne_session_info');
    } on ArgumentError {
      return '';
    }
    fn(_sessionBuf, _sessionCap);
    return _sessionBuf.cast<Utf8>().toDartString();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stop(_handle);
    _destroy(_handle);
    _handle = nullptr;
    calloc.free(_visBuf);
    calloc.free(_statusBuf);
    calloc.free(_sessionBuf);
  }
}
