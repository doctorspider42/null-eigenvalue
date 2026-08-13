import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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

  bool _hudVisible = true;
  Timer? _hudTimer;

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
    _state.palette = c.palette;

    final wantIdle = c.playing ? 0.0 : 1.0;
    _idle += (wantIdle - _idle) * (1 - math.exp(-dt / 0.45));
    _state.idleHint = _idle;

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

          if (!c.deviceOk)
            Align(
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'no audio device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 3,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
