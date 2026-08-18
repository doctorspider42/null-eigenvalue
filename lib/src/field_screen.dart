import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:nulleig/nulleig.dart';

import 'drone_controller.dart';
import 'hud.dart';
import 'nebula.dart';
import 'platform.dart';
import 'textures.dart';
import 'tv_focus.dart';
import 'updater.dart';

/// The app. There is one screen and it is the instrument.
class FieldScreen extends StatefulWidget {
  const FieldScreen({
    super.key,
    required this.controller,
    required this.textures,
    required this.updater,
  });

  final DroneController controller;
  final Textures textures;
  final Updater updater;

  @override
  State<FieldScreen> createState() => _FieldScreenState();
}

class _FieldScreenState extends State<FieldScreen>
    with SingleTickerProviderStateMixin {
  final NebulaState _state = NebulaState();
  late final Ticker _ticker;

  Duration _lastTick = Duration.zero;
  double _idle = 1;

  // Hidden at launch. The painter already draws a large breathing ring with a
  // play glyph in the middle of the field while the app is silent, and the HUD
  // has a transport of its own - showing both at once put two play buttons on
  // screen, one of them apparently decorative.
  bool _hudVisible = false;
  double _hudAmt = 0;
  Timer? _hudTimer;

  DroneStatus _status = DroneStatus.unknown;
  double _statusClock = 0;
  bool _forceDiagnostics = false;

  // Callback throughput between status polls. `callbacks` alone cannot tell a
  // live device from one that served four thousand buffers and then silently
  // died with its state still saying "started" - the *rate* can.
  int _lastCallbacks = -1;
  double _cbPerSec = 0;

  // The sleep panel, and the last countdown second the HUD was rebuilt for.
  // The countdown lives in the engine; the UI only needs a repaint when the
  // displayed second changes, and only while something is showing it.
  bool _sleepVisible = false;
  int _sleepSecShown = -1;

  /// Pixels the finger has covered since the last frame, which is where the
  /// excitation the engine hears comes from. Accumulated here rather than
  /// measured per pointer event because pointer events arrive in bursts and
  /// dividing one delta by one inter-event time gives a number that swings by
  /// an order of magnitude between frames.
  double _movedPx = 0;
  bool _touching = false;

  /// Fingers actually on the glass, and whether this gesture has ever had two
  /// of them.
  ///
  /// The lock is what stops lifting one finger from throwing the field across
  /// the screen: the recognizer hands the remaining finger back as a fresh
  /// one-finger drag, and jumping the composition to wherever that finger
  /// happens to be is not what letting go of the other one meant. Once two
  /// have been down, the field waits until the glass is clear.
  ///
  /// Counted from raw pointer events rather than from the gesture's own
  /// `pointerCount` for two reasons. The recognizer does not promise a last
  /// callback - lifting the second finger without moving the first leaves it
  /// in a state that ends silently - and its count is not fingers anyway: a
  /// trackpad pan-zoom counts as two of them and arrives with no pointer at
  /// all behind it. A count taken from downs and ups is balanced by
  /// construction and means what it says.
  int _fingers = 0;
  bool _toneLock = false;

  /// Desktop only. Whether the right button is down and dragging.
  ///
  /// Handled with raw pointer events rather than a recognizer because
  /// GestureDetector has no secondary drag - and because the recognizers it
  /// does have take any button, so the field has to be told explicitly to keep
  /// its hands off this one.
  bool _rightDrag = false;

  /// Desktop only. Whether the window is filling the screen, mirrored here so
  /// that Escape knows whether it has something to leave.
  bool _fullscreen = false;

  /// The scale the last build laid the chrome out at, kept only so the
  /// diagnostics can report it. On a television it is derived from a screen
  /// size nobody can see from here, which makes it worth printing.
  double _uiScale = 1;

  /// Television only. Where the remote is pointing while the chrome is up, and
  /// which row of the panel is lit while the panel is open. Both are dead
  /// weight everywhere else - a pointer aims at what it is over, and a keyboard
  /// has a key per control.
  TvFocus _focus = const TvFocus();
  int _panelCol = SettingsPanel.tvSleepColumn;
  int _panelRow = 0;

  /// Whether the level readout is currently showing. It appears when the
  /// volume moves and takes itself away again, so the resting HUD is the same
  /// four lines it has always been.
  bool _volumeHint = false;
  Timer? _volumeHintTimer;

  /// The same, for the second field. It has two numbers and no other way to
  /// read them: the frequency line moves with the pitch but says nothing about
  /// how far from home it is, and the speed is not visible anywhere at all
  /// until half a minute has gone by.
  bool _toneHint = false;
  Timer? _toneHintTimer;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _state.target = Offset(c.fieldX, 1 - c.fieldY);
    _state.centre = _state.target;
    _state.palette = c.tonedPalette;
    // The field is remembered between launches, so the app opens somewhere in
    // particular rather than in the middle. It says where.
    _state.bumpMark();
    c.addListener(_onControllerChanged);
    widget.updater.addListener(_onControllerChanged);
    _ticker = createTicker(_onTick)..start();
    _restartHudTimer();
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _volumeHintTimer?.cancel();
    _toneHintTimer?.cancel();
    _ticker.dispose();
    widget.controller.removeListener(_onControllerChanged);
    widget.updater.removeListener(_onControllerChanged);
    _state.dispose();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  void _onTick(Duration elapsed) {
    // Clamped: coming back from the background hands us one enormous frame,
    // and an unclamped dt there would throw the spring across the screen.
    final dt =
        ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;
    if (dt <= 0) return;

    final c = widget.controller;
    // Rebuilt for as long as a mood crossfade is running. tickBlend moves the
    // palette without notifying - correct for the picture, which re-reads it
    // here every frame, and wrong for the HUD, which only sees it at build
    // time. Without this the chrome keeps the *previous* mood's accent until
    // something unrelated rebuilds it, so tapping a dot renamed the mood while
    // leaving its colour behind.
    final blending = c.moodBlend < 1;
    c.tickBlend(dt);
    if (blending) setState(() {});
    c.syncFromEngine();
    // Every frame, like the palette: all three are read by the painter and by
    // nothing that would rebuild for them.
    _state.palette = c.tonedPalette;
    _state.rate = c.rate;
    _state.tone = c.pitch / DroneController.pitchSpan;

    // Redraw the countdown once a second, and only when someone can see it.
    final sleepSec = c.sleepRemaining?.inSeconds ?? -1;
    if (sleepSec != _sleepSecShown && (_hudVisible || _sleepVisible)) {
      _sleepSecShown = sleepSec;
      setState(() {});
    }

    final wantIdle = c.playing ? 0.0 : 1.0;
    _idle += (wantIdle - _idle) * (1 - math.exp(-dt / 0.45));
    // The two invitations cross-fade rather than swap, so raising the HUD
    // while stopped does not make the centre glyph vanish on a frame boundary.
    _hudAmt += ((_hudVisible ? 1.0 : 0.0) - _hudAmt) * (1 - math.exp(-dt / 0.28));
    _state.idleHint = _idle * (1 - _hudAmt);
    // Raising the chrome is already a request to be told what things are set
    // to, so the field's mark comes up with it and goes back down after it.
    _state.chrome = _hudAmt;

    _statusClock += dt;
    if (_statusClock > 0.5) {
      final s = c.status();
      if (_lastCallbacks >= 0 && s.callbacks >= _lastCallbacks) {
        _cbPerSec = (s.callbacks - _lastCallbacks) / _statusClock;
      }
      _lastCallbacks = s.callbacks;
      _statusClock = 0;
      _status = s;
    }

    if (_touching) {
      final w = context.size?.width ?? 400;
      c.setField(
        _state.target.dx,
        1 - _state.target.dy,
        touching: true,
        speed: (_movedPx / w) / dt,
      );
    }
    _movedPx = 0;

    _state.advance(dt, c.vis());
  }

  // ------------------------------------------------------------- gestures

  void _setFromLocal(Offset local, Size size) {
    _state.target = Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
    _state.addTrail(_state.target);
  }

  /// One recognizer for both gestures, because Flutter will not let a pan and
  /// a scale share a detector and this needs to know how many fingers are on
  /// the glass. One is the field, two is the second field.
  ///
  /// How many is [_fingers] and deliberately not `details.pointerCount`. That
  /// number counts a trackpad gesture as two by definition - the pan-zoom
  /// protocol never says how many fingers are really on the pad, so the
  /// framework assumes the minimum - and a two-finger scroll on a laptop is
  /// therefore indistinguishable from two fingers on a phone. Worse, a
  /// pan-zoom is not a pointer: it produces no down and no up, so a lock taken
  /// on the strength of it is never released and the field stays dead
  /// afterwards. Counting the pointers we were actually handed says
  /// "one mouse" for the trackpad, which is what it is.
  void _onScaleStart(ScaleStartDetails d) {
    final size = context.size;
    if (size == null) return;
    if (_fingers >= 2) {
      _toneLock = true;
      return;
    }
    if (_toneLock || _rightDrag) return;
    _touching = true;
    _movedPx = 0;
    _setFromLocal(d.localFocalPoint, size);
    _hideHud();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final size = context.size;
    if (size == null) return;
    if (_fingers >= 2) {
      _toneLock = true;
      // The focal point, not the span: this is a two-finger drag and not a
      // pinch. Nothing here has a size to zoom.
      _dragTone(d.focalPointDelta, size);
      return;
    }
    if (_toneLock || _rightDrag) return;
    _movedPx += d.focalPointDelta.distance;
    _setFromLocal(d.localFocalPoint, size);
  }

  void _onScaleEnd(ScaleEndDetails d) => _endFieldTouch();

  /// Whichever of the two notices first - a pointer leaving, or the gesture
  /// ending - does this once and the other finds nothing to do. They arrive in
  /// that order and not the other, but only because the pointer layer sits
  /// above the gesture arena, which is not the sort of thing to let a stuck
  /// finger depend on.
  void _endFieldTouch() {
    if (!_touching) return;
    _touching = false;
    widget.controller.endTouch();
    // Park the final position without the touch flag, so the engine stops
    // hearing excitation but keeps the field where the finger left it.
    widget.controller.setField(
      _state.target.dx,
      1 - _state.target.dy,
      touching: false,
    );
  }

  /// Two fingers, or the right button: up is higher, right is faster, and a
  /// full traverse of the screen is the whole of each range. Relative, because
  /// there is nowhere for a second pair of fingers to land that could mean an
  /// absolute value - putting them down would otherwise retune the instrument
  /// before they had moved.
  void _dragTone(Offset delta, Size size) => _changeTone(
        semitones: -delta.dy / size.height * 2 * DroneController.pitchSpan,
        octaves: delta.dx / size.width * 2 * DroneController.rateSpan,
      );

  void _changeTone({double semitones = 0, double octaves = 0}) {
    widget.controller.nudgeTone(semitones: semitones, octaves: octaves);
    _showToneHint();
  }

  void _showToneHint() {
    // Unconditionally, unlike the volume's. Both numbers move for as long as
    // the finger does, and a setState that only fired on the first frame of a
    // drag would leave the readout showing where the gesture started.
    setState(() => _toneHint = true);
    _showHud();
    _toneHintTimer?.cancel();
    _toneHintTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _toneHint = false);
    });
  }

  /// Every finger, whether or not the recognizer made a gesture out of it.
  void _onFingerDown(PointerDownEvent event) => _fingers++;

  void _onFingerUp(PointerEvent event) {
    if (--_fingers > 0) return;
    _fingers = 0;
    _toneLock = false;
    _endFieldTouch();
  }

  /// Desktop only. A mouse has no second finger and its left button is already
  /// the field, so the second field is the right one.
  void _onMouseDown(PointerDownEvent event) {
    if (_sleepVisible) return;
    if (event.buttons & kSecondaryButton == 0) return;
    _rightDrag = true;
  }

  void _onMouseMove(PointerMoveEvent event) {
    if (!_rightDrag) return;
    final size = context.size;
    if (size == null) return;
    _dragTone(event.delta, size);
  }

  void _endRightDrag(PointerEvent event) => _rightDrag = false;

  void _onTap() {
    final c = widget.controller;
    if (!c.playing) {
      // While silent, the whole screen is the play button. Nothing else it
      // could reasonably mean.
      c.setPlaying(true);
      _showHud();
    } else {
      if (_hudVisible) {
        _hideHud();
      } else {
        _showHud();
      }
    }
  }

  /// Desktop only. A mouse that moves over the picture raises the chrome, the
  /// way it does over a video, and four seconds of stillness takes it away
  /// again - the pointer with it, so that a drone left running overnight is
  /// the picture and nothing else.
  void _onHover(PointerHoverEvent event) {
    if (event.delta == Offset.zero) return;
    _showHud();
  }

  void _showHud() {
    if (!_hudVisible) setState(() => _hudVisible = true);
    _restartHudTimer();
  }

  void _hideHud() {
    _hudTimer?.cancel();
    if (_hudVisible) setState(() => _hudVisible = false);
  }

  void _restartHudTimer() {
    _hudTimer?.cancel();
    // Longer on a television, where the chrome is also the cursor: four seconds
    // is a fair timeout for something you stopped pointing at and a mean one
    // for something you are still walking a D-pad across.
    _hudTimer = Timer(Duration(seconds: isTv ? 8 : 4), () {
      if (mounted && widget.controller.playing) {
        setState(() => _hudVisible = false);
      }
    });
  }

  // ------------------------------------------------------------- keyboard

  /// The keyboard is the desktop's version of the lock-screen controls: a way
  /// to drive the instrument without aiming at anything. The bindings are
  /// listed under the sleep options behind the gear, because a chromeless app
  /// that also hides its shortcuts is just a locked door.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final c = widget.controller;
    final key = event.logicalKey;

    // Escape unwinds one layer at a time: the panel, then the window.
    if (key == LogicalKeyboardKey.escape) {
      if (_sleepVisible) {
        _closeSleep();
      } else if (_fullscreen) {
        _toggleFullscreen();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      c.toggle();
      _showHud();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyS) {
      setState(() => _sleepVisible = !_sleepVisible);
      _hudTimer?.cancel();
      return KeyEventResult.handled;
    }

    // Where every application that has a zoom puts its zoom, and this app has
    // no zoom. Both the main row and the numeric keypad.
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _changeVolume(-0.04);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _changeVolume(0.04);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyD) {
      setState(() => _forceDiagnostics = !_forceDiagnostics);
      _showHud();
      return KeyEventResult.handled;
    }

    // The six moods, in the order the dots are drawn.
    const digits = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    ];
    final mood = digits.indexOf(key);
    if (mood >= 0 && mood < neMoodCount) {
      c.setMood(mood);
      _showHud();
      return KeyEventResult.handled;
    }

    // Shifted, the arrows are the second field - the same two axes the right
    // button drags. Checked before the plain arrows, which would otherwise
    // swallow them and move the picture instead.
    if (HardwareKeyboard.instance.isShiftPressed) {
      final tone = _toneOffset(key);
      if (tone != null) {
        _changeTone(semitones: tone.dy, octaves: tone.dx);
        return KeyEventResult.handled;
      }
    }

    // The arrows are the field itself, not a menu: the same two axes the
    // pointer drags through.
    final nudge = _arrowOffset(key);
    if (nudge != null) {
      _nudgeField(nudge);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _nudgeField(Offset delta) {
    _state.target = Offset(
      (_state.target.dx + delta.dx).clamp(0.0, 1.0),
      (_state.target.dy + delta.dy).clamp(0.0, 1.0),
    );
    // A trail point, same as a drag leaves. Without it the composition slides
    // and nothing marks that it was asked to.
    _state.addTrail(_state.target);
    widget.controller.setField(
      _state.target.dx,
      1 - _state.target.dy,
      touching: false,
    );
  }

  // ----------------------------------------------------------------- remote

  /// The remote, which is a television's entire vocabulary: four directions, a
  /// button in the middle of them, and Back.
  ///
  /// The four directions mean two different things, and which one depends on
  /// what is on screen. With the picture bare they are the field itself - the
  /// same two axes a finger drags through, and most of the reason this is worth
  /// putting on a television at all. Once the chrome is up they are the chrome,
  /// because a remote has nothing else to move a cursor with, and the field
  /// would otherwise be moving invisibly under a menu the user is reading.
  ///
  /// Back is not here. Android delivers it as a route pop rather than reliably
  /// as a key, so it is the `PopScope` in [build].
  ///
  /// Play/pause is not here either: `audio_service` owns the media session, and
  /// a remote's transport key already arrives through it. Handling the key as
  /// well would toggle twice on the remotes that have one.
  KeyEventResult _onTvKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // A D-pad centre arrives as `select`; the rest are what the various boxes
    // and their air-mouse remotes send instead of it.
    final pressed = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;

    if (_sleepVisible) return _onPanelKey(key, pressed);
    if (_hudVisible) return _onChromeKey(key, pressed);

    // The bare picture. The D-pad is the instrument.
    if (pressed) {
      _onTap();
      return KeyEventResult.handled;
    }
    final nudge = _arrowOffset(key);
    if (nudge != null) {
      _nudgeField(nudge);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onChromeKey(LogicalKeyboardKey key, bool pressed) {
    if (pressed) {
      _activateFocus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final order = TvControl.values;
      final i = (order.indexOf(_focus.control) +
              (key == LogicalKeyboardKey.arrowUp ? -1 : 1))
          .clamp(0, order.length - 1);
      setState(() => _focus = _focus.withControl(order[i]));
      _restartHudTimer();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final dir = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      if (_focus.control == TvControl.mood) {
        setState(() => _focus =
            _focus.withMood((_focus.mood + dir).clamp(0, neMoodCount - 1)));
        _restartHudTimer();
      } else {
        // Nothing to walk sideways through on the other two rows, and a
        // television is the one place with no volume control of its own within
        // reach of the app - the set's own buttons move the set, not this.
        _changeVolume(dir * 0.04);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  KeyEventResult _onPanelKey(LogicalKeyboardKey key, bool pressed) {
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final dir = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
      final last = SettingsPanel.tvRowsIn(_panelCol) - 1;
      setState(() => _panelRow = (_panelRow + dir).clamp(0, last));
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final left = key == LogicalKeyboardKey.arrowLeft;

      // The level is the one row that wants the sideways keys for itself. A
      // slider that could not be moved with left and right would be the only
      // control on the panel that does not do what it looks like it does; the
      // way back to the durations is up or down first, which is one press and
      // is where the eye is going anyway.
      if (_panelCol == SettingsPanel.tvSettingsColumn &&
          _panelRow == SettingsPanel.tvVolumeRow) {
        _changeVolume(left ? -0.04 : 0.04);
        return KeyEventResult.handled;
      }

      // Between the two columns. The row is carried across and clamped rather
      // than reset, so coming back lands near where it left instead of at the
      // top - the columns are different lengths and a reset would make the
      // shorter one feel like it swallowed the cursor.
      final want = left
          ? SettingsPanel.tvSleepColumn
          : SettingsPanel.tvSettingsColumn;
      if (want != _panelCol) {
        final last = SettingsPanel.tvRowsIn(want) - 1;
        setState(() {
          _panelCol = want;
          _panelRow = _panelRow.clamp(0, last);
        });
      }
      return KeyEventResult.handled;
    }

    if (pressed) {
      if (_panelCol == SettingsPanel.tvSleepColumn) {
        _pickSleep(_panelRow == 0
            ? null
            : Duration(minutes: SettingsPanel.minutes[_panelRow - 1]));
      } else if (_panelRow == SettingsPanel.tvDiagnosticsRow) {
        // Flipped here and read after Back: the reading is drawn on the HUD,
        // which is dead under the panel's scrim anyway.
        setState(() => _forceDiagnostics = !_forceDiagnostics);
      }
      // Nothing for the middle button to commit on the level's own row - it is
      // already moving under the left and right keys.
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _activateFocus() {
    final c = widget.controller;
    switch (_focus.control) {
      case TvControl.gear:
        setState(() {
          _sleepVisible = true;
          _panelCol = SettingsPanel.tvSleepColumn;
          _panelRow = 0;
        });
        _hudTimer?.cancel();
        return;
      case TvControl.transport:
        c.toggle();
        _restartHudTimer();
        return;
      case TvControl.mood:
        c.setMood(_focus.mood);
        _restartHudTimer();
        return;
    }
  }

  /// Which way an arrow key moves the field, or null for anything else. In
  /// steps small enough that holding a key reads as a slow sweep rather than
  /// as a jump.
  /// Which way a shifted arrow moves the second field: a semitone at a time
  /// up and down, a tenth of an octave of speed left and right. Deliberately
  /// coarser than the field's step - a control with a detent in the middle of
  /// it has to be able to leave the detent on the first press, or the first
  /// press appears to do nothing.
  Offset? _toneOffset(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) return const Offset(-0.1, 0);
    if (key == LogicalKeyboardKey.arrowRight) return const Offset(0.1, 0);
    if (key == LogicalKeyboardKey.arrowUp) return const Offset(0, 1);
    if (key == LogicalKeyboardKey.arrowDown) return const Offset(0, -1);
    return null;
  }

  Offset? _arrowOffset(LogicalKeyboardKey key) {
    const step = 0.035;
    if (key == LogicalKeyboardKey.arrowLeft) return const Offset(-step, 0);
    if (key == LogicalKeyboardKey.arrowRight) return const Offset(step, 0);
    if (key == LogicalKeyboardKey.arrowUp) return const Offset(0, -step);
    if (key == LogicalKeyboardKey.arrowDown) return const Offset(0, step);
    return null;
  }

  // --------------------------------------------------------------- volume

  /// The wheel is the level. It is the one gesture a desktop has spare - the
  /// picture has nothing to scroll - and it is where every other player on the
  /// machine already puts it.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // While the panel is open the wheel belongs to the panel, which has a
    // level control of its own and, in a short window, more rows than fit.
    if (_sleepVisible) return;
    // Sign only, not magnitude: a trackpad's fling delivers deltas an order of
    // magnitude larger than a wheel's detent, and scaling by them made a flick
    // go from silence to full.
    _changeVolume(event.scrollDelta.dy > 0 ? -0.04 : 0.04);
  }

  void _changeVolume(double delta) {
    widget.controller.nudgeVolume(delta);
    _showVolumeHint();
  }

  void _showVolumeHint() {
    if (!_volumeHint) setState(() => _volumeHint = true);
    _showHud();
    _volumeHintTimer?.cancel();
    _volumeHintTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _volumeHint = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    final now = await AppWindow.toggleFullscreen();
    if (mounted) setState(() => _fullscreen = now);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final palette = c.tonedPalette;
    final media = MediaQuery.of(context);

    // The phone's proportions are the design; a window is simply a bigger
    // sheet of the same thing. One number, so the transport, the dots and the
    // lettering all grow together and nothing has to be redrawn by hand.
    final shortest = media.size.shortestSide;
    final double scale = isDesktop
        ? (shortest / 620).clamp(1.0, 1.5).toDouble()
        : isTv
            ? tvChromeScale(shortest)
            : 1.0;
    _uiScale = scale;

    // Overscan. A television may simply not show the outermost few per cent of
    // the picture, and nothing reports how much: MediaQuery.padding is about
    // system bars and there are none here. The field is happy to bleed off the
    // edges - it is a field, not a frame - so this insets the chrome only.
    final overscan = isTv
        ? EdgeInsets.symmetric(
            horizontal: media.size.width * 0.04,
            vertical: media.size.height * 0.04,
          )
        : EdgeInsets.zero;

    // Nothing to point at while the chrome is away, so the pointer goes too.
    final hideCursor = isDesktop && !_hudVisible && !_sleepVisible;

    // The HUD stands down while the panel is open. It was always dead under
    // there - the panel's scrim is opaque to hits, so a tap on the transport
    // closed the panel rather than pausing anything - and once the panel grew
    // a key legend on the desktop the two also collided outright.
    final chrome = _hudVisible && !_sleepVisible;

    final Widget screen = Scaffold(
      backgroundColor: palette.bg,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // The counter is outside the recognizer because it has to see every
          // finger, including the ones the recognizer never makes a gesture
          // out of.
          Listener(
            onPointerDown: _onFingerDown,
            onPointerUp: _onFingerUp,
            onPointerCancel: _onFingerUp,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: NebulaPainter(
                    state: _state,
                    textures: widget.textures,
                  ),
                  isComplex: true,
                  willChange: true,
                ),
              ),
            ),
          ),

          // Wordmark. Visible with the HUD only - it is a title, not a status.
          Positioned(
            top: media.padding.top + overscan.top + 22 * scale,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: chrome ? 1 : 0,
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOut,
                // The name, and after it the version at half the name's
                // weight. A downloaded app has no store page to look at, so
                // "which one am I running" has to be answerable from the app
                // itself - but it is a footnote to the title, not a second
                // title, so it shares the line and stays quieter than the
                // frequency readout.
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Text(
                      'NULL EIGENVALUE',
                      style: TextStyle(
                        fontSize: 11 * scale,
                        letterSpacing: 6.5 * scale,
                        fontWeight: FontWeight.w300,
                        color: Colors.white.withValues(alpha: 0.34),
                      ),
                    ),
                    if (_versionLabel != null)
                      Text(
                        _versionLabel!,
                        style: TextStyle(
                          fontSize: 10 * scale,
                          letterSpacing: 2.4 * scale,
                          fontWeight: FontWeight.w300,
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // The gear. Rides in and out with the HUD, so the resting picture
          // stays chromeless; opens the one setting the app has.
          Positioned(
            top: media.padding.top + overscan.top + 8,
            right: overscan.right + 10,
            child: AnimatedOpacity(
              opacity: chrome ? 1 : 0,
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !chrome,
                child: GearButton(
                  colour: palette.accent,
                  scale: scale,
                  focused: isTv && _focus.control == TvControl.gear,
                  onTap: () {
                    setState(() => _sleepVisible = true);
                    _hudTimer?.cancel();
                  },
                ),
              ),
            ),
          ),

          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                  bottom: media.padding.bottom + overscan.bottom + 34 * scale),
              child: AnimatedOpacity(
                opacity: chrome ? 1 : 0,
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOut,
                child: IgnorePointer(
                  ignoring: !chrome,
                  // The chrome is anchored to the bottom and grows upwards, so
                  // anything that makes it taller - the diagnostics block, four
                  // lines of it - walks it into the wordmark at the top. A
                  // window can afford that because it has height to spare; a
                  // television reports 540 logical pixels and does not. Bounded
                  // to what is actually free above the bottom padding and
                  // scaled down if it does not fit, which is the same answer
                  // the settings panel already gives to the same question.
                  child: _boundedForTv(
                    context,
                    scale: scale,
                    overscan: overscan,
                    child: Hud(
                    palette: palette,
                    mood: c.mood,
                    playing: c.playing,
                    rootHz: _state.vis.rootHz,
                    scale: scale,
                    focus: isTv ? _focus : null,
                    sleepLabel: _sleepLabel(c),
                    updateLabel: _updateLabel(),
                    onUpdateTap: _onUpdateTap,
                    toneLabel: _toneHint ? _toneLabel(c) : null,
                    volumeLabel: _volumeHint
                        ? 'VOLUME ${(c.volume * 100).round()}%'
                        : null,
                    diagnostics: _diagnostics(c),
                    onDiagnosticsTap: () {
                      setState(() => _forceDiagnostics = !_forceDiagnostics);
                      _restartHudTimer();
                    },
                    onMood: (m) {
                      c.setMood(m);
                      _restartHudTimer();
                    },
                    onToggle: () {
                      c.toggle();
                      _restartHudTimer();
                    },
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Sleep panel. A scrim and five words; tapping anywhere else is
          // "close". It deliberately does not pause, restyle or otherwise
          // comment on the music - it is a bedside switch, not a screen.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_sleepVisible,
              child: AnimatedOpacity(
                opacity: _sleepVisible ? 1 : 0,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOut,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeSleep,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                    // The scrim covers the whole screen - it is the thing being
                    // dimmed - but what is written on it obeys the same overscan
                    // inset as the rest of the chrome. Without this the panel was
                    // the one piece laid out to the physical edge, and on a set
                    // that hides its outermost few per cent the heading went with
                    // it.
                    child: Padding(
                      padding: overscan,
                      child: Center(
                        child: SettingsPanel(
                          accent: palette.accent,
                          remaining: c.sleepRemaining,
                          choice: c.sleepChoice,
                          scale: scale,
                          showKeys: isDesktop,
                          tv: isTv,
                          focusColumn: _panelCol,
                          focusRow: _panelRow,
                          diagnosticsOn: _forceDiagnostics,
                          onDiagnostics: () => setState(
                              () => _forceDiagnostics = !_forceDiagnostics),
                          // A phone has a hardware volume rocker an inch from
                          // the thumb already holding it; a window does not, and
                          // a television's own buttons move the television.
                          volume: isDesktop || isTv ? c.volume : null,
                          onVolume: c.setVolume,
                          // Only where there is a version to compare. A build
                          // CI did not cut would be claiming to be up to date
                          // on no evidence at all.
                          updates: widget.updater.enabled
                              ? UpdatePanel(
                                  auto: widget.updater.auto,
                                  busy: widget.updater.busy,
                                  status: _updateStatus(),
                                  onAuto: (v) =>
                                      unawaited(widget.updater.setAuto(v)),
                                  onCheck: () => unawaited(
                                      widget.updater.check(force: true)),
                                )
                              : null,
                          onPick: _pickSleep,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (isTv) {
      // Back arrives as a route pop rather than as a key, so it is handled here
      // rather than in _onTvKey. It unwinds the layers Escape unwinds on a
      // desktop, and only the bare picture lets it out of the app: a Back that
      // closed the whole instrument because a panel happened to be open would
      // make for a bad night.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_sleepVisible) {
            _closeSleep();
          } else if (_hudVisible) {
            _hideHud();
          } else {
            SystemNavigator.pop();
          }
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) => _onTvKey(event),
          child: screen,
        ),
      );
    }

    if (!isDesktop) return screen;

    // Desktop only, and in this order: the pointer layer has to be inside the
    // focus layer, or a click on the picture would move focus off the node
    // that owns the keyboard and the shortcuts would go dead after the first
    // drag.
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: _onHover,
        // Outside the MouseRegion's child rather than inside the Scaffold, so
        // the wheel works over the whole window - including over the HUD,
        // where a scroll that did nothing would read as the control being
        // stuck rather than as the HUD not being a scrollable thing.
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onMouseDown,
          onPointerMove: _onMouseMove,
          onPointerUp: _endRightDrag,
          onPointerCancel: _endRightDrag,
          child: screen,
        ),
      ),
    );
  }

  /// Caps the chrome's height on a television and shrinks it rather than
  /// letting it run off the top. A no-op everywhere else, where the window is
  /// tall enough that the question never comes up.
  ///
  /// The ceiling leaves the wordmark's band alone: it is the thing the chrome
  /// was colliding with, and a title the transport is sitting on top of reads
  /// as a bug rather than as a dense layout.
  Widget _boundedForTv(
    BuildContext context, {
    required double scale,
    required EdgeInsets overscan,
    required Widget child,
  }) {
    if (!isTv) return child;
    final media = MediaQuery.of(context);
    final wordmarkBand = media.padding.top + overscan.top + 46 * scale;
    final bottomTaken =
        media.padding.bottom + overscan.bottom + 34 * scale;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            (media.size.height - wordmarkBand - bottomTaken).clamp(0.0, 4000.0),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }

  void _closeSleep() {
    setState(() => _sleepVisible = false);
    _restartHudTimer();
  }

  void _pickSleep(Duration? d) {
    widget.controller.setSleep(d);
    _closeSleep();
  }

  /// "SLEEP 27:41" under the frequency while a timer runs, or null.
  String? _sleepLabel(DroneController c) {
    final rem = c.sleepRemaining;
    if (rem == null) return null;
    final h = rem.inHours;
    final m = rem.inMinutes % 60;
    final s = rem.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? 'SLEEP $h:$mm:$ss' : 'SLEEP $m:$ss';
  }

  /// What to draw after the wordmark, or null where there is nothing worth
  /// drawing.
  ///
  /// Desktop only. CI bakes NE_VERSION into those builds because they are
  /// downloaded rather than installed from a store and there is no store page
  /// to go and read; a phone would have nothing here but the word DEV.
  String? get _versionLabel {
    if (!isDesktop) return null;
    return buildVersion.isEmpty ? '  DEV' : '  $buildVersion';
  }

  /// One line about the newer version, in the same whisper as everything else
  /// down there. Null - which is almost always - means the app says nothing
  /// about updates at all.
  ///
  /// Only the states that are about a newer version actually existing appear
  /// here. "Checking", "up to date" and "could not check" are answers to a
  /// question asked in the panel and they belong in the panel: putting them on
  /// the picture would mean the app interrupts itself to say nothing happened.
  String? _updateLabel() {
    final u = widget.updater;
    switch (u.stage) {
      case UpdateStage.idle:
      case UpdateStage.checking:
      case UpdateStage.upToDate:
      case UpdateStage.checkFailed:
        return null;
      case UpdateStage.available:
        return 'UPDATE ${u.latest}';
      case UpdateStage.downloading:
        return 'UPDATING ${(u.progress * 100).round()}%';
      case UpdateStage.ready:
        return u.handoff ?? 'RESTARTING';
      case UpdateStage.failed:
        // The reason, where there is one. A hand-off that says which permission
        // to grant is not a failure the reader can do nothing about, and
        // flattening both into UPDATE FAILED hid the one that was actionable.
        return u.handoff ?? 'UPDATE FAILED';
    }
  }

  /// The line under the two update rows in the panel, where every state has
  /// something to say.
  String _updateStatus() {
    final u = widget.updater;
    switch (u.stage) {
      case UpdateStage.idle:
        return u.auto ? 'NOT CHECKED YET' : 'AUTOMATIC IS OFF';
      case UpdateStage.checking:
        return 'CHECKING';
      case UpdateStage.upToDate:
        return 'UP TO DATE';
      case UpdateStage.checkFailed:
        return 'COULD NOT REACH GITHUB';
      case UpdateStage.available:
        return '${u.latest} IS AVAILABLE';
      case UpdateStage.downloading:
        return 'DOWNLOADING ${(u.progress * 100).round()}%';
      case UpdateStage.ready:
        return u.handoff ?? 'RESTARTING';
      case UpdateStage.failed:
        return u.handoff ?? 'DOWNLOAD FAILED';
    }
  }

  void _onUpdateTap() {
    final u = widget.updater;
    if (u.stage != UpdateStage.available) return;
    unawaited(u.install());
    _restartHudTimer();
  }

  /// The second field, as two numbers. The transposition is signed because
  /// the only thing worth knowing about it is which way and how far from home
  /// it is; the speed is a multiplier because "1.80x" is what it means and
  /// "+0.85 octaves" is not.
  String _toneLabel(DroneController c) {
    final p = c.pitch;
    final semis = p == 0 ? '0.0' : '${p > 0 ? '+' : ''}${p.toStringAsFixed(1)}';
    return 'PITCH $semis   SPEED ${c.rate.toStringAsFixed(2)}\u00d7';
  }

  /// The lines to show under the readout, or null to show nothing.
  ///
  /// It appears on its own when the audio is demonstrably not working, and can
  /// be summoned by long-pressing the frequency. The states it has to tell
  /// apart: a device that never opened, a device that opened but is never
  /// asked for audio, a synthesizer that is being asked and is returning
  /// silence, and - the one the first line cannot see - a synthesizer whose
  /// sound leaves the callback and then goes somewhere nobody is listening.
  /// Hence the second line: the engine's own play flag, gate and output level
  /// split "silence is ours" from "silence is downstream", and the session's
  /// category / route / media volume say where downstream actually points.
  String? _diagnostics(DroneController c) {
    final wanted = _forceDiagnostics ||
        !c.deviceOk ||
        (c.playing && _status.callbacks == 0) ||
        (c.playing && _status.elapsed > 5 && _state.vis.level < 0.0005);
    if (!wanted) return null;

    final v = _state.vis;
    final ms = c.mediaSessionOk;
    final second = <String>[
      'play${c.enginePlaying ? 1 : 0}',
      'gate${v.gate.toStringAsFixed(2)}',
      'lvl${v.level.toStringAsFixed(3)}',
      'cb/s${_cbPerSec.round()}',
      if (ms != null) 'ms${ms ? 1 : 0}',
    ].join(' ');
    final session = c.sessionInfo();

    // What the screen says it is. On a television this is the number the whole
    // layout is derived from and the one thing that cannot be checked from
    // here: sets report a logical size that has little to do with the panel in
    // them, and picking a scale without it is guesswork. There is no console on
    // a sideloaded build, so it is printed where the rest of the readings are.
    final m = MediaQuery.of(context);
    final geometry = '${m.size.width.round()}x${m.size.height.round()}'
        ' dpr${m.devicePixelRatio.toStringAsFixed(1)}'
        ' ui${_uiScale.toStringAsFixed(2)}';

    return '${_status.line}\n$second\n$geometry'
        '${session.isEmpty ? '' : '\n$session'}';
  }
}

