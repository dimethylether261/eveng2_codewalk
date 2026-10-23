import 'dart:convert';

import 'package:http/http.dart' as http;

import 'engine/engine.dart';
import 'models.dart';

sealed class DialogueResult {}

class DialogueReady extends DialogueResult {
  DialogueReady(this.dialogue);
  final Dialogue dialogue;
}

class DialoguePending extends DialogueResult {}

class DialogueUnavailable extends DialogueResult {
  DialogueUnavailable(this.reason);
  final String reason;
}

/// Where spots and dialogues come from: the on-device engine (default) or a CodeWalk server.
abstract interface class Backend {
  Future<Map<String, dynamic>> health();
  Future<List<Spot>> spots(double lat, double lon, {int radius = 500});
  Future<Spot?> area(double lat, double lon);
  /// [round]: how many times the place was heard before (0 = first time). Later rounds are new
  /// conversations (another specialist if possible, different facts).
  /// [lang]: language of the conversation ('ja' / 'en').
  Future<DialogueResult> dialogue(String spotId, List<String> themes, String codename, {int round = 0, String lang = 'ja'});
  Future<(DialogueResult, List<String>)> bestDialogue(List<String> spotIds, List<String> themes, String codename,
      {Map<String, int> rounds = const {}, String lang = 'ja'});
  Future<void> prefetch(List<String> spotIds, List<String> themes, {Map<String, int> rounds = const {}, String lang = 'ja'});

  /// Today's "今日は何の日" chat call as a spot (null when the backend has none).
  Future<Spot?> chatSpot(double lat, double lon);
}

DialogueResult _result(Map<String, dynamic> j) => switch (j['status']) {
      'ready' => DialogueReady(Dialogue.fromJson(j['dialogue'] as Map<String, dynamic>)),
      'pending' => DialoguePending(),
      _ => DialogueUnavailable((j['reason'] ?? 'unknown') as String),
    };

/// Everything runs on the phone: OSM / Wikipedia / Claude are called directly with the user's key.
class LocalBackend implements Backend {
  LocalBackend(this.engine);
  final Engine engine;

  @override
  Future<Map<String, dynamic>> health() async => engine.health();

  @override
  Future<List<Spot>> spots(double lat, double lon, {int radius = 500}) async =>
      (await engine.spots(lat, lon, radius: radius)).map(Spot.fromJson).toList();

  @override
  Future<Spot?> area(double lat, double lon) async {
    final a = await engine.area(lat, lon);
    return a == null ? null : Spot.fromJson(a);
  }

  @override
  Future<DialogueResult> dialogue(String spotId, List<String> themes, String codename,
          {int round = 0, String lang = 'ja'}) async =>
      _result(engine.dialogue(spotId, themes, codename, round: round, lang: lang));

  @override
  Future<(DialogueResult, List<String>)> bestDialogue(List<String> spotIds, List<String> themes, String codename,
      {Map<String, int> rounds = const {}, String lang = 'ja'}) async {
    final j = engine.bestDialogue(spotIds, themes, codename, rounds: rounds, lang: lang);
    return (_result(j), (j['skip'] as List? ?? const []).cast<String>());
  }

  @override
  Future<void> prefetch(List<String> spotIds, List<String> themes,
          {Map<String, int> rounds = const {}, String lang = 'ja'}) async =>
      engine.prefetch(spotIds, themes, rounds: rounds, lang: lang);

  @override
  Future<Spot?> chatSpot(double lat, double lon) async => Spot.fromJson(engine.chatSpot(lat, lon, DateTime.now()));
}

/// A CodeWalk server (developer option, for comparing with the Python version).
class ApiClient implements Backend {
  ApiClient(this.baseUrl, {http.Client? client}) : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  Uri _u(String path, [Map<String, String>? q]) => Uri.parse('$baseUrl$path').replace(queryParameters: q);

  @override
  Future<Map<String, dynamic>> health() async {
    final r = await _http.get(_u('/health')).timeout(const Duration(seconds: 5));
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  @override
  Future<List<Spot>> spots(double lat, double lon, {int radius = 500}) async {
    final r = await _http
        .get(_u('/spots', {'lat': '$lat', 'lon': '$lon', 'radius': '$radius'}))
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw Exception('spots ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('spots ${j['error']}');
    return (j['spots'] as List).map((e) => Spot.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// The town (町) containing the point, or null when OSM has no town boundary there.
  @override
  Future<Spot?> area(double lat, double lon) async {
    final r = await _http
        .get(_u('/area', {'lat': '$lat', 'lon': '$lon'}))
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw Exception('area ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('area ${j['error']}');
    final a = j['area'];
    return a == null ? null : Spot.fromJson(a as Map<String, dynamic>);
  }

  @override
  Future<DialogueResult> dialogue(String spotId, List<String> themes, String codename,
      {int round = 0, String lang = 'ja'}) async {
    final r = await _http
        .post(_u('/dialogue'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'spot_id': spotId, 'themes': themes, 'codename': codename}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('dialogue ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    switch (j['status']) {
      case 'ready':
        return DialogueReady(Dialogue.fromJson(j['dialogue'] as Map<String, dynamic>));
      case 'pending':
        return DialoguePending();
      default:
        return DialogueUnavailable((j['reason'] ?? 'unknown') as String);
    }
  }

  /// Best-reviewed ready dialogue among nearby candidates. Also returns ids the server
  /// found unusable (not enough sourced facts) so the app stops asking for them.
  @override
  Future<(DialogueResult, List<String>)> bestDialogue(List<String> spotIds, List<String> themes, String codename,
      {Map<String, int> rounds = const {}, String lang = 'ja'}) async {
    final r = await _http
        .post(_u('/dialogue/best'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'spot_ids': spotIds, 'themes': themes, 'codename': codename}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('dialogue/best ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final skip = (j['skip'] as List? ?? const []).cast<String>();
    final DialogueResult result = switch (j['status']) {
      'ready' => DialogueReady(Dialogue.fromJson(j['dialogue'] as Map<String, dynamic>)),
      'pending' => DialoguePending(),
      _ => DialogueUnavailable((j['reason'] ?? 'unknown') as String),
    };
    return (result, skip);
  }

  @override
  Future<void> prefetch(List<String> spotIds, List<String> themes,
      {Map<String, int> rounds = const {}, String lang = 'ja'}) async {
    if (spotIds.isEmpty) return;
    await _http
        .post(_u('/prefetch'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'spot_ids': spotIds, 'themes': themes}))
        .timeout(const Duration(seconds: 10));
  }

  /// The Python server has no chat calls.
  @override
  Future<Spot?> chatSpot(double lat, double lon) async => null;
}
