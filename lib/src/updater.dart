import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this build calls itself.
///
/// Empty in a local `flutter run`, and that is the point: an updater that
/// offers to replace your working tree with a release is not a feature. CI
/// passes the real number with `--dart-define=NE_VERSION=0.1.42`, so only a
/// build that came from a release ever compares itself to one.
const String buildVersion = String.fromEnvironment('NE_VERSION');

const String _repo = 'doctorspider42/null-eigenvalue';

/// How the app is packaged here, and therefore what a newer one arrives as.
///
/// The names have to agree with what the release workflow attaches. They are
/// fixed rather than versioned so that the URL is stable, which is the same
/// reason the .apk and the .ipa have fixed names.
String? get _assetForThisPlatform {
  if (Platform.isWindows) return 'NullEigenvalue-Setup.exe';
  if (Platform.isMacOS) return 'NullEigenvalue.dmg';
  if (Platform.isLinux) return 'NullEigenvalue-x86_64.AppImage';
  return null;
}

/// Where the update has got to.
///
/// Four of these are worth interrupting the picture for and four are not, which
/// is the whole reason the list is this long: the HUD shows only the states
/// that are about a newer version actually existing, and the panel - where the
/// user went looking - shows all of them.
enum UpdateStage {
  /// Nothing found, or nothing looked for yet.
  idle,

  /// Asking GitHub. Only ever visible in the panel, and only during a check
  /// the user asked for: the automatic one happens six seconds after launch
  /// with nobody looking.
  checking,

  /// Asked, and this is the newest there is.
  upToDate,

  /// Could not ask - offline, rate-limited, GitHub having a day. Distinct from
  /// [failed], which is a download that went wrong, because the two want
  /// different things from the reader and only one of them is worth a word on
  /// the picture.
  checkFailed,

  /// A newer release exists and its installer is waiting to be fetched.
  available,

  /// Fetching it.
  downloading,

  /// Fetched. On Windows the installer has been handed over and the app is
  /// about to close; elsewhere the file is on disk and the user has been shown
  /// where.
  ready,

  /// The download or the hand-off went wrong. Never fatal - see [Updater.check].
  failed,
}

/// Checks GitHub for a newer release and, if asked, installs it.
///
/// Deliberately no dependency. This is one HTTPS GET of a JSON document and
/// one of a file, and `dart:io` does both; an update client is exactly the
/// kind of thing that should not widen the app's supply chain.
///
/// Nothing here is allowed to break the instrument. Every failure path ends in
/// a state the UI can ignore, and the whole thing runs several seconds after
/// the audio device is up so that a slow network cannot delay the first sound.
class Updater extends ChangeNotifier {
  Updater({String? currentVersion, this.repo = _repo})
      : current = currentVersion ?? buildVersion;

  /// The version running now, or '' for a build that was not cut by CI.
  final String current;
  final String repo;

  UpdateStage stage = UpdateStage.idle;

  /// The version on offer, e.g. '0.1.42'. Null unless [stage] is past idle.
  String? latest;

  /// 0..1 while downloading.
  double progress = 0;

  /// What to tell the user once the file has landed somewhere they have to
  /// act on themselves - a mounted disk image, a replaced AppImage. Null on
  /// Windows, where the installer simply takes over.
  String? handoff;

  /// Whether the app looks for a new version by itself.
  ///
  /// On by default and switchable off from the panel. Off stops the automatic
  /// check only - the button next to it still works, because "do not go to the
  /// network behind my back" and "never tell me about a new version again" are
  /// different wishes and the first one is the common one.
  bool auto = true;

  Uri? _asset;
  int _assetBytes = 0;
  bool _busy = false;

  /// Whether a check or a download is in flight.
  bool get busy => _busy;

  /// Whether the app should show anything at all about updates. A dev build
  /// has no version to compare, and a phone gets its updates from AltStore or
  /// from the .apk it was installed with.
  bool get enabled =>
      current.isNotEmpty &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Reads the one preference this object owns.
  ///
  /// Separate from the constructor because it touches disk and the app is not
  /// going to wait on it: the panel is several seconds of interaction away and
  /// the automatic check is six.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      auto = prefs.getBool('updateAuto') ?? true;
    } catch (_) {
      // A machine that will not give us preferences gets the default, which is
      // the same thing it would have got the first time anyway.
    }
    notifyListeners();
  }

  /// Turns the automatic check on or off.
  Future<void> setAuto(bool value) async {
    if (auto == value) return;
    auto = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('updateAuto', value);
    } catch (_) {
      // The switch still holds for this run; it just will not be remembered.
    }
  }

  /// Asks GitHub what the newest release is.
  ///
  /// Automatically at most once every six hours across launches. The releases
  /// API is unauthenticated here, which means sixty requests an hour from one
  /// address; an app that is meant to be left running for a whole evening
  /// should not be spending them on a question whose answer changes weekly.
  ///
  /// [force] is the button in the panel: it ignores both the six hours and the
  /// automatic switch, because a check the user asked for out loud is not the
  /// thing either of those was protecting them from.
  Future<void> check({bool force = false}) async {
    if (!enabled || _busy) return;
    if (!force && !auto) return;
    // Deliberately not shown for the automatic check. Six seconds after launch
    // nobody is looking at the panel, and a "CHECKING" that flickers past on
    // its own is noise.
    if (force) {
      stage = UpdateStage.checking;
      notifyListeners();
    }
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('updateCheckedAt') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - last < const Duration(hours: 6).inMilliseconds) {
        return;
      }

      final release = await _getJson(
        Uri.https('api.github.com', '/repos/$repo/releases/latest'),
      );
      await prefs.setInt('updateCheckedAt', now);
      if (release == null) {
        stage = UpdateStage.checkFailed;
        notifyListeners();
        return;
      }

      final tag = (release['tag_name'] as String?) ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty || !isNewerVersion(version, current)) {
        stage = UpdateStage.upToDate;
        notifyListeners();
        return;
      }

      final wanted = _assetForThisPlatform;
      if (wanted == null) return;
      for (final asset in (release['assets'] as List<dynamic>? ?? const [])) {
        if (asset is! Map) continue;
        if (asset['name'] != wanted) continue;
        final url = asset['browser_download_url'] as String?;
        if (url == null) continue;
        _asset = Uri.parse(url);
        _assetBytes = (asset['size'] as num?)?.toInt() ?? 0;
        latest = version;
        stage = UpdateStage.available;
        notifyListeners();
        return;
      }
      // A release with no build for this platform yet. CI publishes all of
      // them in one job, so this means the run is still going - report the
      // truth, which is that there is nothing to fetch, and pick it up on the
      // next check.
      stage = UpdateStage.upToDate;
      notifyListeners();
    } catch (_) {
      // Offline, rate-limited, GitHub down, a JSON shape we did not expect.
      // None of that is worth a word on the picture - but it is worth one in
      // the panel, where somebody is waiting for an answer.
      stage = UpdateStage.checkFailed;
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Downloads the installer and hands it over.
  Future<void> install() async {
    final asset = _asset;
    if (asset == null || stage != UpdateStage.available || _busy) return;
    _busy = true;
    stage = UpdateStage.downloading;
    progress = 0;
    notifyListeners();

    try {
      final file = await _download(asset);
      if (Platform.isWindows) {
        // Inno Setup cannot replace a running executable, so the app has to
        // go first. Started detached: the moment this process exits, nothing
        // is left to keep the installer alive but the OS.
        await Process.start(
          file.path,
          <String>['/SILENT', '/NOCANCEL', '/RESTARTAPPLICATIONS'],
          mode: ProcessStartMode.detached,
        );
        stage = UpdateStage.ready;
        notifyListeners();
        // Long enough for the installer to have a window up, so the screen
        // never goes empty between the two.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        exit(0);
      } else if (Platform.isMacOS) {
        // Mounting the image and dragging the app is the Mac's own idiom for
        // this, and it is the only one that works for an app the user
        // themselves had to clear past Gatekeeper.
        await Process.run('open', <String>[file.path]);
        handoff = 'DRAG IT OVER THE OLD ONE';
        stage = UpdateStage.ready;
      } else {
        handoff = await _replaceAppImage(file);
        stage = UpdateStage.ready;
      }
    } catch (_) {
      stage = UpdateStage.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Swaps a running AppImage for the one just downloaded.
  ///
  /// A rename over the file of a running AppImage is safe on Linux: the kernel
  /// holds the inode open until the process exits, so the copy that is
  /// executing keeps working and the next launch is the new one. If the app
  /// was not started from an AppImage there is nothing to replace, and the
  /// honest thing is to say where the file went.
  Future<String> _replaceAppImage(File downloaded) async {
    await Process.run('chmod', <String>['+x', downloaded.path]);
    final running = Platform.environment['APPIMAGE'];
    if (running == null || running.isEmpty) {
      return 'SAVED TO ${downloaded.parent.path}';
    }
    await downloaded.rename(running);
    return 'RESTART TO FINISH';
  }

  // ------------------------------------------------------------------- net

  Future<Map<String, dynamic>?> _getJson(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      // GitHub rejects a request with no User-Agent outright, and the version
      // header is what keeps the response shape from moving under us.
      request.headers.set(HttpHeaders.userAgentHeader, 'NullEigenvalue/$current');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _download(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'NullEigenvalue/$current');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('${response.statusCode} for $url');
      }

      final total = response.contentLength > 0
          ? response.contentLength
          : _assetBytes;
      final dir = await Directory.systemTemp.createTemp('nulleig_update');
      final file = File('${dir.path}/${url.pathSegments.last}');
      final sink = file.openWrite();
      var received = 0;
      var lastNotified = 0.0;
      await response.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total <= 0) return;
        final p = received / total;
        // Repainting on every 8 KB chunk would rebuild the HUD a thousand
        // times for one download and tell the reader nothing new.
        if (p - lastNotified >= 0.01 || p >= 1) {
          lastNotified = p;
          progress = p.clamp(0.0, 1.0);
          notifyListeners();
        }
      });
      await sink.close();
      return file;
    } finally {
      client.close(force: true);
    }
  }
}

/// True when [candidate] sorts after [current] as a dotted number.
///
/// Deliberately not a semver library: CI cuts `<major>.<minor>.<run number>`
/// and nothing else ever appears here. Anything unparseable is treated as not
/// newer, so a malformed tag can only ever fail to offer an update.
bool isNewerVersion(String candidate, String current) {
  List<int>? parse(String s) {
    final parts = s.split('.');
    final out = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      out.add(n);
    }
    return out.isEmpty ? null : out;
  }

  final a = parse(candidate);
  final b = parse(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
