import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The two images the whole picture is drawn out of.
///
/// Everything glowing in this app is the same white blob, tinted and scaled.
/// The alternative - building a radial gradient shader per orb per frame -
/// works, but it is fifteen shader objects a frame and it shows up on an older
/// phone as a stutter in something that is supposed to be perfectly smooth.
/// One texture, drawn fifteen times, is a single GPU state change.
class Textures {
  Textures._(this.blob, this.grain);

  final ui.Image blob;
  final ui.Image grain;

  static Future<Textures> load() async {
    final blob = await _blob(256);
    final grain = await _grain(128);
    return Textures._(blob, grain);
  }

  /// A soft white disc, alpha falling off as a raised cosine squared. The
  /// exponent is the whole character of the thing: too low and the orbs have
  /// visible edges, too high and they are a faint smudge with no core.
  static Future<ui.Image> _blob(int size) {
    final pixels = Uint8List(size * size * 4);
    final c = (size - 1) / 2.0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = (x - c) / c;
        final dy = (y - c) / c;
        final r = math.sqrt(dx * dx + dy * dy);
        double a = 0;
        if (r < 1) {
          final f = 0.5 + 0.5 * math.cos(math.pi * r);
          a = f * f * (0.55 + 0.45 * f);
        }
        final i = (y * size + x) * 4;
        pixels[i] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
        pixels[i + 3] = (a * 255).round().clamp(0, 255);
      }
    }
    return _decode(pixels, size, size);
  }

  /// Monochrome noise, tiled over the finished frame at a few percent. Without
  /// it, wide dark gradients on an 8-bit display band into visible rings; with
  /// it, the dither hides them and the picture reads as film rather than as a
  /// gradient.
  static Future<ui.Image> _grain(int size) {
    final rnd = math.Random(0x4E756C6C);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      // Deviations around mid grey rather than full-range noise: the texture
      // is drawn with BlendMode.overlay, where 128 is a no-op, so the strength
      // of the effect lives in this number and nowhere else. Full-range noise
      // through overlay is snow.
      final v = (128 + (rnd.nextDouble() - 0.5) * 18).round().clamp(0, 255);
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 255;
    }
    return _decode(pixels, size, size);
  }

  static Future<ui.Image> _decode(Uint8List pixels, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
