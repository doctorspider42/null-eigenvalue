import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:nulleig/nulleig.dart';

import 'drone_controller.dart';
import 'hud.dart';
import 'nebula.dart';
import 'textures.dart';

/// The app. There is one screen and it is the instrument.
class FieldScreen extends StatefulWidget {
  const FieldScreen({
    super.key,
    required this.controller,
    required this.textures,
  });

  final DroneController controller;
  final Textures textures;

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

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _state.target = Offset(c.fieldX, 1 - c.fieldY);
    _state.centre = _state.target;
    _state.palette = c.palette;
    c.addListener(_onControllerChanged);
    _ticker = createTicker(_onTick)..start();
    _restartHudTimer();
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _ticker.dispose();
    widget.controller.removeListener(_onControllerChanged);
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
    c.tickBlend(dt);
    c.syncFromEngine();
    _state.palette = c.palette;

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

  void _onPanStart(DragStartDetails d) {
    final size = context.size;
    if (size == null) return;
    _touching = true;
    _movedPx = 0;
    _setFromLocal(d.localPosition, size);
    _hideHud();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final size = context.size;
    if (size == null) return;
    _movedPx += d.delta.distance;
    _setFromLocal(d.localPosition, size);
  }

  void _onPanEnd(_) {
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
    _hudTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && widget.controller.playing) {
        setState(() => _hudVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final palette = c.palette;
    final media = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: palette.bg,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTap,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            onPanCancel: () => _onPanEnd(null),
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

          // Wordmark. Visible with the HUD only - it is a title, not a status.
          Positioned(
            top: media.padding.top + 22,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hudVisible ? 1 : 0,
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOut,
                child: Text(
                  'NULL EIGENVALUE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 6.5,
                    fontWeight: FontWeight.w300,
                    color: Colors.white.withValues(alpha: 0.34),
                  ),
                ),
              ),
            ),
          ),

          // The gear. Rides in and out with the HUD, so the resting picture
          // stays chromeless; opens the one setting the app has.
          Positioned(
            top: media.padding.top + 8,
            right: 10,
            child: AnimatedOpacity(
              opacity: _hudVisible ? 1 : 0,
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !_hudVisible,
                child: GearButton(
                  colour: palette.accent,
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
              padding: EdgeInsets.only(bottom: media.padding.bottom + 34),
              child: AnimatedOpacity(
                opacity: _hudVisible ? 1 : 0,
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOut,
                child: IgnorePointer(
                  ignoring: !_hudVisible,
                  child: Hud(
                    palette: palette,
                    mood: c.mood,
                    playing: c.playing,
                    rootHz: _state.vis.rootHz,
                    sleepLabel: _sleepLabel(c),
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
                    child: Center(
                      child: _SleepPanel(
                        accent: palette.accent,
                        remaining: c.sleepRemaining,
                        choice: c.sleepChoice,
                        onPick: _pickSleep,
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
    return '${_status.line}\n$second${session.isEmpty ? '' : '\n$session'}';
  }
}

/// The sleep timer's face: a title, five durations and OFF, in the same
/// typography as the mood name. The active choice is the accent colour;
/// everything else keeps the HUD's whisper-grey, so even fully open this is
/// barely a dialog.
class _SleepPanel extends StatelessWidget {
  const _SleepPanel({
    required this.accent,
    required this.remaining,
    required this.choice,
    required this.onPick,
  });

  final Color accent;
  final Duration? remaining;
  final Duration? choice;
  final ValueChanged<Duration?> onPick;

  static const List<int> _minutes = <int>[15, 30, 45, 60, 90];

  @override
  Widget build(BuildContext context) {
    final armed = remaining != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'SLEEP',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 6.5,
            fontWeight: FontWeight.w300,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 26),
        _row('OFF', selected: !armed, onTap: () => onPick(null)),
        for (final m in _minutes)
          _row(
            '$m MIN',
            selected: armed && choice?.inMinutes == m,
            onTap: () => onPick(Duration(minutes: m)),
          ),
      ],
    );
  }

  Widget _row(String label, {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 11),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            height: 1.0,
            letterSpacing: 4.6,
            fontWeight: FontWeight.w400,
            color: selected
                ? accent.withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: 0.32),
          ),
        ),
      ),
    );
  }
}
