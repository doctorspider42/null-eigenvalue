import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nulleig/nulleig.dart';

import 'palette.dart';
import 'tv_focus.dart';

/// The ring that says "this is the thing the remote is pointing at".
///
/// A hairline in the accent colour, at the weight the panel's divider and the
/// level's rule already use. Not a Material focus highlight: one of those in
/// the middle of this picture looks like it was pasted in from another program,
/// which is the same reason the transport and the gear are drawn rather than
/// iconed.
///
/// The border is always laid out and only its alpha moves, so a control does
/// not shift by a pixel when the cursor arrives at it.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.on,
    required this.colour,
    required this.child,
    this.radius = 6,
  });

  final bool on;
  final Color colour;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          width: 1,
          color: colour.withValues(alpha: on ? 0.55 : 0),
        ),
      ),
      child: child,
    );
  }
}

/// The only chrome in the app: a transport and five names. It is hidden by
/// default and fades back out on its own, because a control that is always on
/// screen is a control you are always looking at.
class Hud extends StatelessWidget {
  const Hud({
    super.key,
    required this.palette,
    required this.mood,
    required this.playing,
    required this.rootHz,
    required this.onMood,
    required this.onToggle,
    this.scale = 1,
    this.focus,
    this.sleepLabel,
    this.updateLabel,
    this.onUpdateTap,
    this.volumeLabel,
    this.diagnostics,
    this.onDiagnosticsTap,
  });

  final MoodPalette palette;
  final int mood;
  final bool playing;
  final double rootHz;
  final ValueChanged<int> onMood;
  final VoidCallback onToggle;

  /// Where the remote is pointing, or null anywhere there is no remote - which
  /// is everywhere but a television. It rings one control at a time and is
  /// deliberately separate from [mood]: the ring says "this is what the button
  /// would do", the filled dot says "this is what is playing".
  final TvFocus? focus;

  /// How much bigger than the phone this is being drawn. One number for the
  /// whole HUD: the proportions are the design, and a window is a bigger sheet
  /// of the same paper rather than an excuse to lay it out again. 1 on a
  /// phone, and never much past one and a half anywhere - past that the
  /// chrome starts competing with the picture it is sitting on.
  final double scale;

  /// "SLEEP 27:41" while a sleep timer runs, or null. Same register as the
  /// frequency readout: information for whoever looks, decoration for
  /// everyone else.
  final String? sleepLabel;

  /// "UPDATE 0.1.42" when the desktop build has found a newer release, and
  /// the download's progress after it has been asked for. Null everywhere
  /// else, which includes every phone and every build that CI did not cut.
  final String? updateLabel;
  final VoidCallback? onUpdateTap;

  /// "VOLUME 72%", for the couple of seconds after the level changes.
  ///
  /// Transient rather than permanent. The level is worth seeing while you are
  /// moving it and is clutter the rest of the time - and unlike the sleep
  /// countdown there is always a value, so a line that was always there would
  /// never be off.
  final String? volumeLabel;

  /// Shown under the readout when something is wrong with the audio device,
  /// or when the reading is asked for by long-pressing the frequency. There is
  /// no console on a sideloaded build, so this is the console.
  final String? diagnostics;
  final VoidCallback? onDiagnosticsTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Transport(
          playing: playing,
          colour: palette.accent,
          scale: scale,
          focused: focus?.control == TvControl.transport,
          onTap: onToggle,
        ),
        SizedBox(height: 26 * scale),
        // Dots, not names. Six names at a readable size do not fit across a
        // phone, and the obvious fixes - a scroller, or two rows - both turn
        // the one piece of chrome in the app into a menu. A row of dots with
        // the current name under it fits any width, keeps every mood one tap
        // away, and stays quiet.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < neMoodCount; i++)
              _MoodDot(
                selected: i == mood,
                colour: palette.accent,
                scale: scale,
                focused: focus?.ringsMood(i) ?? false,
                onTap: () => onMood(i),
              ),
          ],
        ),
        SizedBox(height: 14 * scale),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          child: Text(
            MoodPalette.all[mood].name.toUpperCase(),
            key: ValueKey<int>(mood),
            style: TextStyle(
              fontSize: 12 * scale,
              height: 1.0,
              letterSpacing: 4.6 * scale,
              fontWeight: FontWeight.w400,
              color: palette.accent.withValues(alpha: 0.92),
            ),
          ),
        ),
        SizedBox(height: 12 * scale),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: onDiagnosticsTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 24 * scale,
              vertical: 4 * scale,
            ),
            child: Text(
              '${rootHz.toStringAsFixed(1)} Hz',
              style: TextStyle(
                fontSize: 10 * scale,
                height: 1.2,
                letterSpacing: 2.4 * scale,
                fontWeight: FontWeight.w300,
                color: Colors.white.withValues(alpha: 0.26),
              ),
            ),
          ),
        ),
        // Above the sleep countdown, because it is the line that is currently
        // moving and the one the reader just asked for.
        if (volumeLabel != null) ...<Widget>[
          SizedBox(height: 6 * scale),
          Text(
            volumeLabel!,
            style: TextStyle(
              fontSize: 10 * scale,
              height: 1.2,
              letterSpacing: 2.4 * scale,
              fontWeight: FontWeight.w300,
              color: palette.accent.withValues(alpha: 0.55),
            ),
          ),
        ],
        if (sleepLabel != null) ...<Widget>[
          SizedBox(height: 6 * scale),
          Text(
            sleepLabel!,
            style: TextStyle(
              fontSize: 10 * scale,
              height: 1.2,
              letterSpacing: 2.4 * scale,
              fontWeight: FontWeight.w300,
              color: palette.accent.withValues(alpha: 0.55),
            ),
          ),
        ],
        // The update sits under the sleep countdown and above the
        // diagnostics, which is the right order of urgency: how long the music
        // has left, then that there is a newer one of these, then why it is
        // broken. Dimmer than the mood name and no louder than the frequency -
        // it is an offer, and an offer that shouts is a nag.
        if (updateLabel != null) ...<Widget>[
          SizedBox(height: 6 * scale),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onUpdateTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 24 * scale,
                vertical: 4 * scale,
              ),
              child: Text(
                updateLabel!,
                style: TextStyle(
                  fontSize: 10 * scale,
                  height: 1.2,
                  letterSpacing: 2.4 * scale,
                  fontWeight: FontWeight.w300,
                  color: palette.accent.withValues(alpha: 0.62),
                ),
              ),
            ),
          ),
        ],
        if (diagnostics != null) ...<Widget>[
          SizedBox(height: 8 * scale),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 18 * scale),
            child: Text(
              diagnostics!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9 * scale,
                height: 1.35,
                color: Colors.white.withValues(alpha: 0.42),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The corner gear that opens the sleep panel. Drawn, like the transport,
/// because a Material icon in this picture looks like a sticker: one thin
/// outline of eight teeth and a hub, at the same stroke weight as everything
/// else. A 20-pixel glyph inside a 44-pixel target, same deal as the dots.
class GearButton extends StatelessWidget {
  const GearButton({
    super.key,
    required this.colour,
    required this.onTap,
    this.scale = 1,
    this.focused = false,
  });

  final Color colour;
  final VoidCallback onTap;
  final double scale;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FocusRing(
        on: focused,
        colour: colour,
        child: SizedBox(
          width: 44 * scale,
          height: 44 * scale,
          child: CustomPaint(painter: _GearPainter(colour)),
        ),
      ),
    );
  }
}

class _GearPainter extends CustomPainter {
  _GearPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = colour.withValues(alpha: 0.5);

    const n = 8;
    const seg = 2 * math.pi / n;
    const tw = seg * 0.44; // angular width of one tooth
    final r = size.shortestSide * 0.155; // body
    final tr = r * 1.42; // tooth tip
    final outer = Rect.fromCircle(center: c, radius: tr);
    final inner = Rect.fromCircle(center: c, radius: r);

    final path = Path()
      ..moveTo(c.dx + tr * math.cos(-tw / 2), c.dy + tr * math.sin(-tw / 2));
    for (var i = 0; i < n; i++) {
      final a = i * seg - tw / 2;
      path
        ..arcTo(outer, a, tw, false)
        ..lineTo(c.dx + r * math.cos(a + tw), c.dy + r * math.sin(a + tw))
        ..arcTo(inner, a + tw, seg - tw, false)
        ..lineTo(
            c.dx + tr * math.cos(a + seg), c.dy + tr * math.sin(a + seg));
    }
    path.close();
    canvas.drawPath(path, paint);
    canvas.drawCircle(c, r * 0.42, paint);
  }

  @override
  bool shouldRepaint(covariant _GearPainter old) => old.colour != colour;
}

class _MoodDot extends StatelessWidget {
  const _MoodDot({
    required this.selected,
    required this.colour,
    required this.onTap,
    this.scale = 1,
    this.focused = false,
  });

  final bool selected;
  final Color colour;
  final VoidCallback onTap;
  final double scale;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // A 5-pixel dot inside a 44-pixel target: the thing you aim at is the
      // size a thumb needs, the thing you see is the size the picture needs.
      // On a television the ring goes round the target rather than the dot -
      // the dot is four pixels, and a ring round it would be a smudge.
      child: FocusRing(
        on: focused,
        colour: colour,
        child: SizedBox(
          width: 44 * scale,
          height: 34 * scale,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              width: (selected ? 7 : 4) * scale,
              height: (selected ? 7 : 4) * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    selected ? colour : Colors.white.withValues(alpha: 0.26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.playing,
    required this.colour,
    required this.onTap,
    this.scale = 1,
    this.focused = false,
  });

  final bool playing;
  final Color colour;
  final VoidCallback onTap;
  final double scale;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // Radius half the side, so the ring round the transport is a circle
      // concentric with the one the painter draws rather than a box round it.
      child: FocusRing(
        on: focused,
        colour: colour,
        radius: 46 * scale,
        child: SizedBox(
          width: 92 * scale,
          height: 92 * scale,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: playing ? 1 : 0),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => CustomPaint(
              painter: _TransportPainter(t, colour),
            ),
          ),
        ),
      ),
    );
  }
}

/// A ring and a glyph that morphs between a triangle and two bars. Drawn
/// rather than iconed so the line weight matches the rest of the picture -
/// a Material icon next to this artwork looks like it came from another app.
class _TransportPainter extends CustomPainter {
  _TransportPainter(this.t, this.colour);

  /// 0 = showing "play", 1 = showing "pause".
  final double t;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * 0.40;

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = colour.withValues(alpha: 0.42),
    );

    final paint = Paint()..color = colour.withValues(alpha: 0.88);
    final d = r * 0.42;

    if (t < 0.02) {
      final tri = Path()
        ..moveTo(c.dx - d * 0.5, c.dy - d)
        ..lineTo(c.dx - d * 0.5, c.dy + d)
        ..lineTo(c.dx + d, c.dy)
        ..close();
      canvas.drawPath(tri, paint);
      return;
    }

    // Two bars, growing out of the triangle's silhouette as it collapses.
    final gap = d * 0.36 * t;
    final w = d * 0.30;
    final h = d * (1 - 0.12 * (1 - t));
    for (final sign in <double>[-1, 1]) {
      final x = c.dx + sign * (gap + w * 0.5) - w * 0.5 + (1 - t) * d * 0.1;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, c.dy - h, w, h * 2),
          Radius.circular(w * 0.35),
        ),
        paint..color = colour.withValues(alpha: 0.88 * math.min(1, t * 2.2)),
      );
    }
    if (t < 1) {
      final tri = Path()
        ..moveTo(c.dx - d * 0.5, c.dy - d)
        ..lineTo(c.dx - d * 0.5, c.dy + d)
        ..lineTo(c.dx + d, c.dy)
        ..close();
      canvas.drawPath(
        tri,
        Paint()..color = colour.withValues(alpha: 0.88 * (1 - t) * (1 - t)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TransportPainter old) =>
      old.t != t || old.colour != colour;
}

/// Everything the app can be told to do, on one surface behind the gear.
///
/// It began as the sleep timer and kept its typography: a heading, then rows in
/// the mood name's face, the live one in the accent colour and the rest in the
/// HUD's whisper-grey, so even fully open this is barely a dialog. The desktop
/// added a level, an updates section and the key bindings - the last of those
/// belong here rather than on the picture, because this is the only surface in
/// the app allowed to be a list of words, and shortcuts nobody can find are
/// shortcuts nobody has.
///
/// On a window wide enough it lays out as two columns. One column was correct
/// while this was six durations; with four sections it ran off the bottom of
/// the default window, and a desktop has width going spare where it does not
/// have height.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.accent,
    required this.remaining,
    required this.choice,
    required this.onPick,
    this.scale = 1,
    this.showKeys = false,
    this.tv = false,
    this.focusColumn = tvSleepColumn,
    this.focusRow = 0,
    this.volume,
    this.onVolume,
    this.updates,
    this.diagnosticsOn = false,
    this.onDiagnostics,
  });

  final Color accent;
  final Duration? remaining;
  final Duration? choice;
  final ValueChanged<Duration?> onPick;
  final double scale;

  /// Whether to show the key bindings, which is to say whether there is a
  /// keyboard. Also what decides the two-column layout, since it is the only
  /// section big enough to want one.
  final bool showKeys;

  /// Whether to lay this out for a remote rather than for a pointer.
  ///
  /// Not merely a legend swap. At the size a television needs, the single
  /// column runs off the bottom of a 540-pixel-tall logical screen, so this
  /// becomes three: the sleep durations, then the settings beside them, then
  /// the legend. Nothing scrolls, which matters more here than anywhere else -
  /// a D-pad cannot scroll towards a row it cannot see.
  final bool tv;

  /// Where the remote is sitting: which column, and which row inside it. Both
  /// are ignored entirely unless [tv]. See [tvRowsIn].
  final int focusColumn;
  final int focusRow;

  /// The durations, in the order they are drawn. Public because the remote's
  /// key handler has to turn a row number back into one of these, and a second
  /// copy of the list somewhere else is a second copy to forget to update.
  static const List<int> minutes = <int>[15, 30, 45, 60, 90];

  /// The two columns a remote can walk, in the order they are drawn.
  ///
  /// The cursor is a column and a row rather than one running number. It was
  /// one number to begin with, which meant walking all six sleep durations to
  /// reach the level sitting beside them - the eye saw two columns and the
  /// D-pad treated them as one list. The legend is a third column and is not
  /// here: there is nothing in it to press.
  static const int tvSleepColumn = 0;
  static const int tvSettingsColumn = 1;

  /// Rows within [tvSettingsColumn]. The level first, because it is the one
  /// most likely to be wanted twice in an evening.
  static const int tvVolumeRow = 0;

  /// The diagnostics switch. It is only a row on a television: everywhere else
  /// the reading is summoned by long-pressing the frequency or by pressing D,
  /// and a remote can do neither. Leaving it unreachable would make the TV the
  /// one build that cannot be asked why it is silent - on the platform with the
  /// least chance of anyone having a console open.
  static const int tvDiagnosticsRow = 1;

  /// The one row that both checks for a new version and installs it. Two verbs
  /// on one row because which of them is meant is never ambiguous - there is
  /// either something to install or there is not - and a remote should walk
  /// past as few rows as the app can manage.
  static const int tvUpdateRow = 2;

  /// Whether to go looking by itself. Worth its own row even here: "do not use
  /// my network unasked" is a different wish from "never offer me a new
  /// version", and only the first one is common.
  static const int tvAutoRow = 3;

  /// How many rows [column] has. Counting and drawing must agree: walking onto
  /// a row that is not drawn makes the ring vanish, which is not a failure
  /// anyone would think to report. A test holds the two together - including
  /// the last two rows, which exist only where there is an updater to talk to.
  static int tvRowsIn(int column, {required bool withUpdates}) =>
      column == tvSleepColumn
          ? 1 + minutes.length
          : (withUpdates ? tvAutoRow + 1 : tvDiagnosticsRow + 1);

  /// The master level, 0..1, or null to leave the section out entirely - which
  /// is what a phone does, having a hardware volume control six inches from
  /// the user's thumb.
  final double? volume;
  final ValueChanged<double>? onVolume;

  /// The updates section, or null to leave it out. Null on a phone, and on a
  /// build CI did not cut - there is nothing there to compare against a
  /// release, so an "up to date" would be a guess.
  final UpdatePanel? updates;

  /// Whether the diagnostics reading is currently being forced on, and how to
  /// flip it. Drawn only when [tv]; see [tvDiagnosticsRow].
  final bool diagnosticsOn;
  final VoidCallback? onDiagnostics;

  /// What the D-pad does, which depends on whether the chrome is up - hence two
  /// short lists rather than one, each under its own heading. Every remote has
  /// these three buttons; the ones that also have a transport key get it from
  /// the media session and do not need telling.
  static const List<List<String>> _remotePicture = <List<String>>[
    <String>['D-PAD', 'THE FIELD'],
    <String>['OK', 'THE HUD'],
  ];

  static const List<List<String>> _remoteChrome = <List<String>>[
    <String>['D-PAD', 'CHOOSE'],
    <String>['OK', 'USE'],
    <String>['BACK', 'AWAY'],
  ];

  static const List<List<String>> _keys = <List<String>>[
    <String>['SPACE', 'PLAY / PAUSE'],
    <String>['1 - 6', 'MOOD'],
    <String>['ARROWS', 'FIELD'],
    <String>['SCROLL', 'VOLUME'],
    <String>['- / =', 'VOLUME'],
    <String>['F', 'FULL SCREEN'],
    <String>['S', 'THIS PANEL'],
    <String>['D', 'DIAGNOSTICS'],
  ];

  @override
  Widget build(BuildContext context) {
    // A television is the one place the single column does not fit: at the size
    // three metres needs, the durations alone are most of the screen's height.
    // Three columns rather than two, because with the settings and both halves
    // of the legend stacked together the right-hand one ran to the bottom edge
    // of the screen - and it is the column the eye reads last, so it was the
    // one that could least afford to.
    if (tv) {
      // Scaled down rather than scrolled if it somehow still does not fit. The
      // set of televisions is wider than the two shapes this was measured
      // against, and a panel that is slightly too small to be ideal beats one
      // with an overflow stripe across it that a D-pad cannot scroll away.
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: _columns(<Widget>[
          Column(mainAxisSize: MainAxisSize.min, children: _sleepSection()),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (volume != null) ..._volumeSection(),
              SizedBox(height: 20 * scale),
              _row(
                'DIAGNOSTICS',
                selected: diagnosticsOn,
                col: tvSettingsColumn,
                row: tvDiagnosticsRow,
                onTap: onDiagnostics ?? () {},
              ),
              if (updates != null) ...<Widget>[
                SizedBox(height: 20 * scale),
                _row(
                  updates!.primaryLabel,
                  // Never the accent. It is a verb, and colouring it like an
                  // armed sleep duration would read as a state.
                  selected: false,
                  col: tvSettingsColumn,
                  row: tvUpdateRow,
                  onTap: updates!.busy ? () {} : updates!.primaryAction,
                ),
                _row(
                  'AUTOMATIC',
                  selected: updates!.auto,
                  col: tvSettingsColumn,
                  row: tvAutoRow,
                  onTap: () => updates!.onAuto(!updates!.auto),
                ),
                _note(updates!.status),
              ],
            ],
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ..._legendSection('PICTURE', _remotePicture),
              SizedBox(height: 26 * scale),
              ..._legendSection('CHROME', _remoteChrome),
            ],
          ),
        ]),
      );
    }

    final settings = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ..._sleepSection(),
        if (volume != null) ...<Widget>[_divider(), ..._volumeSection()],
        if (updates != null) ...<Widget>[_divider(), ..._updatesSection()],
      ],
    );

    // Scrollable regardless of the layout, because the window has a floor of
    // 480 logical pixels and the left column alone is taller than that. It
    // shrink-wraps against the loose constraints a Center hands it, so on any
    // ordinary window there is nothing to scroll and no sign that there could
    // be.
    return SingleChildScrollView(
      child: showKeys
          ? _columns(<Widget>[
              settings,
              Column(
                mainAxisSize: MainAxisSize.min,
                children: _legendSection('KEYS', _keys),
              ),
            ])
          : settings,
    );
  }

  Widget _columns(List<Widget> columns) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < columns.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: 56 * scale),
            columns[i],
          ],
        ],
      );

  Widget _divider() => Padding(
        padding: EdgeInsets.symmetric(vertical: 24 * scale),
        child: Container(
          width: 200 * scale,
          height: 1,
          color: Colors.white.withValues(alpha: 0.08),
        ),
      );

  Widget _heading(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 11 * scale,
          height: 1.0,
          letterSpacing: 4.6 * scale,
          fontWeight: FontWeight.w300,
          color: Colors.white.withValues(alpha: 0.45),
        ),
      );

  /// A line of information rather than a control: the level, what the last
  /// check found. Quieter than the rows above it, so the eye reads the things
  /// it can touch first.
  Widget _note(String text) => Padding(
        padding: EdgeInsets.only(top: 4 * scale),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10 * scale,
            height: 1.2,
            letterSpacing: 2.4 * scale,
            fontWeight: FontWeight.w300,
            color: Colors.white.withValues(alpha: 0.28),
          ),
        ),
      );

  List<Widget> _sleepSection() {
    final armed = remaining != null;
    return <Widget>[
      Text(
        'SLEEP',
        style: TextStyle(
          fontSize: 12 * scale,
          letterSpacing: 6.5 * scale,
          fontWeight: FontWeight.w300,
          color: Colors.white.withValues(alpha: 0.45),
        ),
      ),
      SizedBox(height: 26 * scale),
      _row('OFF',
          selected: !armed,
          col: tvSleepColumn,
          row: 0,
          onTap: () => onPick(null)),
      for (var i = 0; i < minutes.length; i++)
        _row(
          '${minutes[i]} MIN',
          selected: armed && choice?.inMinutes == minutes[i],
          col: tvSleepColumn,
          row: i + 1,
          onTap: () => onPick(Duration(minutes: minutes[i])),
        ),
    ];
  }

  List<Widget> _volumeSection() => <Widget>[
        _heading('VOLUME ${(volume! * 100).round()}%'),
        SizedBox(height: 16 * scale),
        FocusRing(
          on: tv &&
              focusColumn == tvSettingsColumn &&
              focusRow == tvVolumeRow,
          colour: accent,
          child: _VolumeBar(
            value: volume!,
            accent: accent,
            scale: scale,
            onChanged: onVolume ?? (_) {},
          ),
        ),
      ];

  List<Widget> _updatesSection() => <Widget>[
        _heading('UPDATES'),
        SizedBox(height: 12 * scale),
        // Two rows in the same shape as the sleep durations: the switch, which
        // reads as on when it is the accent colour, and the button.
        _row(
          'AUTOMATIC',
          selected: updates!.auto,
          onTap: () => updates!.onAuto(!updates!.auto),
        ),
        _row(
          'CHECK NOW',
          // Never the accent: it is a verb, not a setting, and colouring it
          // like an armed sleep duration would read as a state.
          selected: false,
          onTap: updates!.busy ? () {} : updates!.onCheck,
        ),
        _note(updates!.status),
      ];

  List<Widget> _legendSection(String heading, List<List<String>> rows) =>
      <Widget>[
        _heading(heading),
        SizedBox(height: 22 * scale),
        for (final k in rows)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 3.5 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 92 * scale,
                  child: Text(
                    k[0],
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10 * scale,
                      height: 1.0,
                      letterSpacing: 2.4 * scale,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.34),
                    ),
                  ),
                ),
                SizedBox(width: 26 * scale),
                SizedBox(
                  width: 132 * scale,
                  child: Text(
                    k[1],
                    style: TextStyle(
                      fontSize: 10 * scale,
                      height: 1.0,
                      letterSpacing: 2.4 * scale,
                      fontWeight: FontWeight.w300,
                      color: Colors.white.withValues(alpha: 0.20),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ];

  /// One row of the panel. [row] is its number for a remote to land on; the
  /// sections a remote cannot reach leave it out and are never ringed.
  Widget _row(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    int row = -1,
    int col = -1,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FocusRing(
        on: tv && row == focusRow && col == focusColumn,
        colour: accent,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 48 * scale,
            vertical: 11 * scale,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12 * scale,
              height: 1.0,
              letterSpacing: 4.6 * scale,
              fontWeight: FontWeight.w400,
              color: selected
                  ? accent.withValues(alpha: 0.92)
                  : Colors.white.withValues(alpha: 0.32),
            ),
          ),
        ),
      ),
    );
  }
}

/// The level, as a hairline with a dot on it.
///
/// Not a Material slider: a chrome-heavy widget with a ripple and a thumb
/// shadow in the middle of this picture looks like it was pasted in from
/// another program. This is the same 1-pixel rule the panel's divider uses,
/// with the played part in the accent colour and a dot the size of a selected
/// mood dot - the two controls in this app that mean "here" now look alike.
class _VolumeBar extends StatelessWidget {
  const _VolumeBar({
    required this.value,
    required this.accent,
    required this.scale,
    required this.onChanged,
  });

  final double value;
  final Color accent;
  final double scale;
  final ValueChanged<double> onChanged;

  static const double _floor = 0.05;

  @override
  Widget build(BuildContext context) {
    final width = 200.0 * scale;

    void emit(double dx) =>
        onChanged((dx / width).clamp(_floor, 1.0).toDouble());

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => emit(d.localPosition.dx),
      onHorizontalDragUpdate: (d) => emit(d.localPosition.dx),
      child: SizedBox(
        // A 44-pixel target around a 1-pixel line, the same deal as the dots.
        width: width,
        height: 44 * scale,
        child: Center(
          child: CustomPaint(
            size: Size(width, 12 * scale),
            painter: _VolumeBarPainter(value, accent),
          ),
        ),
      ),
    );
  }
}

class _VolumeBarPainter extends CustomPainter {
  _VolumeBarPainter(this.value, this.accent);

  final double value;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final x = size.width * value.clamp(0.0, 1.0);

    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.14),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(x, y),
      Paint()
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.55),
    );
    canvas.drawCircle(
      Offset(x, y),
      3.5,
      Paint()..color = accent.withValues(alpha: 0.92),
    );
  }

  @override
  bool shouldRepaint(covariant _VolumeBarPainter old) =>
      old.value != value || old.accent != accent;
}

/// What the panel needs to know about updates, and what to call when the user
/// touches one of the two rows.
///
/// A plain value rather than a reference to the Updater, so hud.dart keeps
/// knowing nothing about HTTP and the preview harness can pose the section in
/// states - mid-check, rate-limited - that are awkward to reach for real.
class UpdatePanel {
  const UpdatePanel({
    required this.auto,
    required this.busy,
    required this.status,
    required this.onAuto,
    required this.onCheck,
    this.primaryLabel = 'CHECK NOW',
    this.onPrimary,
  });

  /// Whether the app looks for a new version by itself.
  final bool auto;

  /// A check or a download is in flight; the button should not start another.
  final bool busy;

  /// One line under the two rows: what the last check found, or what this
  /// build is. Always present - a section that is sometimes three rows and
  /// sometimes two makes the panel jump when it is opened.
  final String status;

  final ValueChanged<bool> onAuto;
  final VoidCallback onCheck;

  /// What the television's single update row says, which is also what pressing
  /// it does: check when there is nothing on offer, install when there is.
  /// Supplied rather than derived, so this file goes on knowing nothing about
  /// UpdateStage.
  final String primaryLabel;

  final VoidCallback? onPrimary;

  /// Pressing that row. Falls back to [onCheck], which is what the default
  /// label says when nothing else has been supplied.
  VoidCallback get primaryAction => onPrimary ?? onCheck;
}
