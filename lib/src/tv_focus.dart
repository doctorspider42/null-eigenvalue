// Where a remote is pointing, for the one surface that can be pointed at.
//
// The app deliberately does not use FocusNode traversal for this. On a
// television the D-pad has to mean two different things depending on what is on
// screen - the field itself while the picture is bare, the chrome once the
// chrome is up - and handing the arrows to the framework in one of those states
// and not the other splits the input story across a traversal policy and a key
// handler. The set of controls here is fixed, small and laid out by hand
// already, so the cursor is kept by hand too and every key a remote can send is
// read in one place: _onTvKey in field_screen.dart.

/// Which piece of the HUD has the ring around it.
///
/// The order is the order the D-pad walks them, top of the screen downwards:
/// the gear sits in the corner, the transport in the middle, the mood dots
/// under it.
enum TvControl { gear, transport, mood }

/// The remote's position in the chrome: which control, and - while that
/// control is the row of dots - which dot.
///
/// The dot cursor is deliberately not the selected mood. Moving across the row
/// would otherwise start a crossfade per dot, so six presses to reach the last
/// mood would cost six of them; here the ring moves for free and the mood
/// changes when the button is pressed.
class TvFocus {
  const TvFocus({this.control = TvControl.transport, this.mood = 0});

  final TvControl control;
  final int mood;

  TvFocus withControl(TvControl c) => TvFocus(control: c, mood: mood);

  TvFocus withMood(int m) => TvFocus(control: control, mood: m);

  /// Whether the ring belongs on dot [i] right now.
  bool ringsMood(int i) => control == TvControl.mood && mood == i;
}
