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

  // Where the mood transition is up to, for the palette crossfade. The engine
  // does its own, much slower migration in the audio; this is only the colour.
  int _prevMood = 1;
  double _moodBlend = 1;

  SharedPreferences? _prefs;
  Directory? _tmp;

  int get mood => _mood;
  int get previousMood => _prevMood;
  double get moodBlend => _moodBlend;
  double get fieldX => _x;
  double get fieldY => _y;
  bool get playing => _playing;
  bool get deviceOk => _deviceOk;

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
    } catch (_) {
      // A phone that will not give us preferences is not a reason to refuse to
      // make a sound.
    }
    engine.mood = _mood;
    engine.setField(_x, _y);
    engine.gain = 0.92;
    _deviceOk = engine.startDevice();
    notifyListeners();
  }

  void _save() {
    _prefs?.setInt('mood', _mood);
    _prefs?.setDouble('x', _x);
    _prefs?.setDouble('y', _y);
  }

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
