import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:nulleig/nulleig.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'palette.dart';

/// Owns the engine and the app's only piece of durable state.
///
/// The split with the UI is deliberate: this class knows nothing about how the
/// field is drawn and the painter knows nothing about FFI. What crosses
/// between them is four numbers and a mood.
class DroneController extends ChangeNotifier {
  DroneController(this.engine);

  final DroneEngine engine;

  int _mood = 1;
  double _x = 0.5;
  double _y = 0.45;
  bool _playing = false;
  bool _deviceOk = false;

  /// Master gain, 0..1.
  ///
  /// Not quite 1 by default: the synthesizer is mastered to leave a little
  /// headroom, and starting at unity would mean the only direction the control
  /// goes is down. This is the app's own level, underneath whatever the system
  /// mixer says - which is the point of having it on a desktop, where the drone
  /// is one voice among a dozen other things making noise.
  double _volume = 0.92;

  // Where the mood transition is up to, for the palette crossfade. The engine
  // does its own, much slower migration in the audio; this is only the colour.
  int _prevMood = 1;
  double _moodBlend = 1;

  SharedPreferences? _prefs;
  Directory? _tmp;

  /// Whether AudioService.init came up. Null until main() has tried. The
  /// failure is deliberately survivable - the app still sounds - but it is
  /// exactly the difference between "no lock-screen controls because iOS said
  /// no" and "no lock-screen controls because we never asked", so the
  /// diagnostics line wants to know.
  bool? mediaSessionOk;

  int get mood => _mood;
  int get previousMood => _prevMood;
  double get moodBlend => _moodBlend;
  double get fieldX => _x;
  double get fieldY => _y;
  bool get playing => _playing;
  bool get deviceOk => _deviceOk;
  double get volume => _volume;

  MoodPalette get palette => MoodPalette.lerp(
        MoodPalette.all[_prevMood],
        MoodPalette.all[_mood],
        _ease(_moodBlend),
      );

  String get moodName => MoodPalette.all[_mood].name;

  /// Called by whatever is driving the frame clock.
  void tickBlend(double dt) {
    if (_moodBlend < 1) {
      _moodBlend = math.min(1, _moodBlend + dt / 2.2);
    }
  }

  Future<void> restore() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _mood = (_prefs?.getInt('mood') ?? 1).clamp(0, neMoodCount - 1);
      _prevMood = _mood;
      _x = (_prefs?.getDouble('x') ?? 0.5).clamp(0.0, 1.0);
      _y = (_prefs?.getDouble('y') ?? 0.45).clamp(0.0, 1.0);
      // Floored well above zero. A drone that comes back silent because the
      // level was left at nothing last week is indistinguishable from one that
      // is broken, and this app has no other evidence to offer.
      _volume = (_prefs?.getDouble('volume') ?? 0.92).clamp(0.05, 1.0);
    } catch (_) {
      // A phone that will not give us preferences is not a reason to refuse to
      // make a sound.
    }
    engine.mood = _mood;
    engine.setField(_x, _y);
    engine.gain = _volume;
    notifyListeners();
  }

  /// Opens the audio device.
  ///
  /// Separate from [restore], and called after the media session has been
  /// initialised, because both want a say in the AVAudioSession and the last
  /// one to touch it wins. Starting the device last means the category the
  /// engine asked for is the category that is live.
  void startAudio() {
    _deviceOk = engine.startDevice();
    notifyListeners();
  }

  DroneStatus status() => engine.status();

  /// The engine's own idea of whether it is playing, read back through FFI
  /// rather than mirrored from [_playing]. If these two ever disagree, the
  /// set_playing store is not reaching the synthesizer, and that is worth a
  /// line on screen.
  bool get enginePlaying => engine.playing;

  String sessionInfo() => engine.sessionInfo();

  void _save() {
    _prefs?.setInt('mood', _mood);
    _prefs?.setDouble('x', _x);
    _prefs?.setDouble('y', _y);
    _prefs?.setDouble('volume', _volume);
  }

  /// Sets the master gain. The engine ramps to it internally, so this is safe
  /// to call from a scroll wheel at whatever rate the mouse produces.
  void setVolume(double value) {
    final v = value.clamp(0.05, 1.0);
    if (v == _volume) return;
    _volume = v;
    engine.gain = v;
    _save();
    notifyListeners();
  }

  void nudgeVolume(double delta) => setVolume(_volume + delta);

  void setField(double x, double y, {bool touching = true, double speed = 0}) {
    _x = x.clamp(0.0, 1.0);
    _y = y.clamp(0.0, 1.0);
    engine.setField(_x, _y);
    engine.setTouch(active: touching, speed: speed);
    _save();
    // No notifyListeners: the field changes on every pointer move and the
    // painter is already repainting every frame from the ticker. Rebuilding
    // the widget tree at 120 Hz for a value nothing in it reads would be pure
    // waste.
  }

  void endTouch() => engine.setTouch(active: false);

  void setMood(int value) {
    final m = value.clamp(0, neMoodCount - 1);
    if (m == _mood) return;
    _prevMood = _mood;
    _moodBlend = 0;
    _mood = m;
    engine.mood = m;
    _save();
    notifyListeners();
    unawaited(_refreshArtwork());
  }

  void cycleMood(int delta) =>
      setMood((_mood + delta + neMoodCount) % neMoodCount);

  void setPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    engine.playing = value;
    notifyListeners();
  }

  void toggle() => setPlaying(!_playing);

  // ----------------------------------------------------------------- sleep

  Timer? _sleepFallback;

  /// The option the user picked, for highlighting it in the panel. The truth
  /// about the countdown itself is the engine's; this is only which label to
  /// draw a ring around.
  Duration? sleepChoice;

  /// Seconds until the armed sleep fires, straight from the engine. Null when
  /// disarmed - which includes "it already fired", so the UI can simply stop
  /// showing a countdown that no longer exists.
  Duration? get sleepRemaining {
    final s = engine.sleepRemaining;
    return s == null ? null : Duration(milliseconds: (s * 1000).round());
  }

  /// Arms the sleep timer, or disarms it with null.
  ///
  /// The engine owns the deadline (it must fire behind a locked screen, where
  /// this isolate may be frozen). The Dart timer here is only an echo: when
  /// the UI *is* alive at the deadline it flips [playing] so the transport
  /// and the lock-screen controls agree with the silence; when it is not,
  /// [syncFromEngine] catches up on the next frame instead.
  void setSleep(Duration? d) {
    engine.setSleep(d);
    sleepChoice = d;
    _sleepFallback?.cancel();
    _sleepFallback = d == null
        ? null
        : Timer(d + const Duration(seconds: 1), () => setPlaying(false));
    notifyListeners();
  }

  /// Called from the frame clock. The engine can stop itself (sleep landing
  /// with the app foregrounded but the fallback timer throttled, or the UI
  /// waking after a night of background audio); the transport should follow
  /// rather than claim to be playing silence.
  void syncFromEngine() {
    if (_playing && !engine.playing) {
      _playing = false;
      if (sleepChoice != null && engine.sleepRemaining == null) {
        sleepChoice = null;
        _sleepFallback?.cancel();
        _sleepFallback = null;
      }
      notifyListeners();
    }
  }

  DroneVis vis() => engine.vis();

  // ---------------------------------------------------------------- artwork

  /// The lock screen wants a square image. Rather than ship five PNGs, draw
  /// one: the same palette and the same shapes the app is showing, so what is
  /// under the controls is a still of what is playing.
  Uri? artworkUri;

  Future<void> _refreshArtwork() async {
    try {
      _tmp ??= Directory.systemTemp;
      final p = MoodPalette.all[_mood];
      final bytes = await _paintArtwork(p);
      if (bytes == null) return;
      final f = File('${_tmp!.path}/ne_art_$_mood.png');
      await f.writeAsBytes(bytes, flush: true);
      artworkUri = Uri.file(f.path);
      notifyListeners();
    } catch (_) {
      // Artwork is decoration. Never let it take the audio down with it.
    }
  }

  Future<void> prepareArtwork() => _refreshArtwork();

  static Future<Uint8List?> _paintArtwork(MoodPalette p) async {
    const size = 512.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, size, size),
      ui.Paint()..color = p.bg,
    );
    final rnd = math.Random(7);
    for (var i = 0; i < 7; i++) {
      final t = i / 6.0;
      final c = p.forBand(i, 7, 0.55);
      final r = size * (0.16 + 0.30 * rnd.nextDouble());
      final cx = size * (0.30 + 0.40 * rnd.nextDouble());
      final cy = size * (0.72 - 0.45 * t);
      canvas.drawCircle(
        ui.Offset(cx, cy),
        r,
        ui.Paint()
          ..blendMode = ui.BlendMode.plus
          ..shader = ui.Gradient.radial(ui.Offset(cx, cy), r, <ui.Color>[
            c.withValues(alpha: 0.55),
            c.withValues(alpha: 0.0),
          ], <double>[
            0,
            1
          ]),
      );
    }
    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }

  @override
  void dispose() {
    _sleepFallback?.cancel();
    engine.dispose();
    super.dispose();
  }
}

/// Local ease so this file does not have to pull in the widgets layer for one
/// curve.
double _ease(double t) {
  final u = t.clamp(0.0, 1.0);
  return u * u * (3 - 2 * u);
}
