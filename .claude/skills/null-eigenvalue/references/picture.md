# The picture and the chrome

Everything glowing is one white blob texture, tinted and added. The composition
is a direct reading of the synthesizer: the core is the drone, the eight orbs
are the register slices the engine publishes, a ring expands each time a voice
takes a new pitch, a point of light flashes for every bell. The engine hands
the UI eight numbers and a few scalars - there is no FFT and no second thread.

## The split, and why it exists

`NebulaState` is the simulation; `NebulaPainter` draws it.

- The state advances **once per frame at a known `dt`**, driven by the ticker in
  `field_screen.dart`. Putting it inside `paint()` would run it again for every
  repaint the framework decides to do, and the orbits would speed up whenever
  something unrelated rebuilt.
- The painter takes the state as `repaint:`, so a value the picture reads is a
  field on the state rather than a constructor argument: a new painter every
  frame would mean a widget rebuild every frame for values no widget reads.
- Two clocks live in `advance`: the music's (`dt * rate`, which the orbits,
  the breathing, the rings and the bells run on) and the hand's (wall time, for
  the spring, the wake and the field mark). A finger does not move faster when
  the drone does.

## What reads what

| on screen | from |
|---|---|
| the eight orbs | `vis.bands[i]`, one per register slice |
| the core | `vis.level`, tinted between `deep` and `mid` by `vis.centroid` |
| expanding rings | a change in `vis.chordChange` (an edge, not a level) |
| points of light | a rising edge on `vis.spark` |
| the pool of light | `vis.gate`, so a paused app still has somewhere to sit |
| the idle breathing | nothing - it is `(1 - gate)`, so the moment sound starts the picture is the synthesizer's again |
| the field mark | `state.centre`, the app's own state, not the engine's |
| colour and size | `state.palette` (already transposed) and `state.tone` |

While paused the engine reports silence. A black screen is not a pause, it is a
crash, and it is the first thing anyone sees - so the field breathes on its own
until the music arrives, multiplied by `(1 - gate)` so it contributes nothing
once there is sound.

## Palette rules

`MoodPalette` is four stops per mood, not a two-colour gradient, because the
picture is additive: `deep` must stay almost invisible against `bg` when a
voice is quiet, while `accent` has to survive being added on top of everything.

- **`bg` is never pure black.** A real black rectangle on an OLED reads as a
  hole rather than as depth. `transposed()` darkens it an octave down and must
  keep that true; a test asserts it for every mood.
- `forBand` runs deep → mid → accent with register, and brightness lifts the
  whole thing toward `accent` rather than changing hue - which is what opening
  the filter actually sounds like.
- `transposed(octaves)` slides every stop one place along the ladder the
  palette already is: this is a transposition, not a tint. The whole app is
  handed the transposed palette (`DroneController.tonedPalette`), so the mood
  dots and the panel are drawn in the mood as it currently sounds.
- `MoodPalette.all.length` must equal `neMoodCount`. There is a test.

## The chrome

The app is chromeless by default and everything on top of the picture earns its
place. `_hudVisible` is raised by a tap (or by mouse movement on a desktop) and
takes itself away after four seconds; the gear opens the one panel; the
readouts under the frequency (volume, pitch/speed, sleep, updates) are
transient and each says why in its own doc comment.

Three things to keep in mind when adding anything there:

- **The transport sits in the middle of the bottom of the field.** Anything you
  draw near the centre will collide with it while the chrome is up. The field
  mark's rays stand down under the chrome for exactly this reason.
- **Television.** `tv_focus.dart` holds where the D-pad is pointing, and it is
  deliberately separate from what is playing: the ring says "this is what the
  button would do", the filled dot says "this is what is playing". The chrome
  only takes the arrows once it is up; the bare picture leaves them to the
  field. Chrome is inset for overscan - the field bleeds off the edges happily,
  the chrome must not.
- **One scale number.** `scale` drives the whole HUD so proportions stay put;
  a window is a bigger sheet of the same paper, not a re-layout.

## Judging a visual change

```bash
flutter test tools/preview/preview_test.dart   # writes tools/preview/out/*.png
```

Then **look at the PNGs**. The harness rasterises the real painter with a real
canvas at phone (393x852), desktop (1040x780) and television (960x540) sizes,
from hand-written `DroneVis` snapshots - so you can pose the field in states
that would take twenty minutes of listening to catch by accident. Text renders
as boxes (no font in the test environment); layout and metrics are still true.

To add a shot, copy an existing `testWidgets` block: give it a number in
sequence, a mood, a `centre`, and a `_vis(...)` snapshot. The `shot` helper
takes `tone`, `rate` and `handOn` for the second field and the mark's resting
state, `hud`, `panel`, `tv` and `size` for the chrome. Shots are not goldens -
nothing fails if the picture changes - they exist to be looked at, which is
why `tools/preview/out/` is git-ignored and regenerated rather than committed.

When the change is about motion or feel rather than composition, run the real
app (`flutter run -d windows`, or your desktop): a still cannot show you a
breath rate or whether a spring has the right weight.
