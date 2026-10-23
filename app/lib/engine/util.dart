import 'dart:async';
import 'dart:math' as math;

/// A spot or dialogue as plain JSON (same shape the Python server used).
typedef Json = Map<String, dynamic>;

/// Compiled to JavaScript for the glasses app (lib/standalone/): requests run in a browser.
const isWeb = bool.fromEnvironment('dart.library.js_interop');

/// Headers that identify the app. A browser won't let a page set User-Agent; Wikimedia reads
/// Api-User-Agent instead (other services get no identification from the glasses app).
Map<String, String> uaHeaders(String userAgent, {bool wikimedia = false}) =>
    isWeb ? (wikimedia ? {'Api-User-Agent': userAgent} : const {}) : {'User-Agent': userAgent};

/// Who to contact about this app's requests to Nominatim. Its usage policy asks an app to identify
/// itself, and a browser can't set User-Agent, so the glasses app sends this as email= instead.
/// Put the developer's address here before a public release.
const appContactEmail = '';

/// Nominatim's email= parameter: [appContactEmail], else the user's contact from [userAgent] (see
/// AppSettings.userAgent / CoreSettings.userAgent) when it is an email address; none when neither.
Map<String, String> nominatimEmail(String userAgent) {
  if (appContactEmail.isNotEmpty) return const {'email': appContactEmail};
  final user = RegExp(r'[^\s;()]+@[^\s;()]+\.[^\s;()]+').firstMatch(userAgent)?.group(0);
  return user == null ? const {} : {'email': user};
}

/// Runs calls one at a time, at most one per [minInterval] (Nominatim's usage policy: 1 request/second).
class Throttle {
  Throttle([this.minInterval = const Duration(milliseconds: 1100)]);
  final Duration minInterval;
  Future<void> _tail = Future.value();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  Future<T> run<T>(Future<T> Function() call) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      final wait = _last.add(minInterval).difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      try {
        done.complete(await call());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}

/// Wikimedia APIs answer a browser's cross-site call only with origin=*.
const Map<String, String> webOrigin = isWeb ? {'origin': '*'} : {};

double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double round6(num v) => (v * 1e6).round() / 1e6;

String normSpace(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Public view of a spot: keys starting with "_" are internal.
Json publicSpot(Json spot) => {
      for (final e in spot.entries)
        if (!e.key.startsWith('_')) e.key: e.value,
    };

/// 'ja:品川宿' -> 'https://ja.wikipedia.org/wiki/品川宿'.
String? wikipediaUrl(String? tag) {
  if (tag == null || !tag.contains(':')) return null;
  final i = tag.indexOf(':');
  final lang = tag.substring(0, i), title = tag.substring(i + 1);
  if (!RegExp(r'^[a-z\-]{2,12}$').hasMatch(lang)) return null;
  return 'https://$lang.wikipedia.org/wiki/${title.trim().replaceAll(' ', '_')}';
}

class Unavailable implements Exception {
  Unavailable(this.reason);
  final String reason;
  @override
  String toString() => 'Unavailable($reason)';
}
