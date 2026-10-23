/// The walk, run by the glasses app alone (no CODEWALK phone app): pure Dart, compiled to
/// JavaScript (js_main.dart) and driven by g2/src/local.ts with the Even Hub location and storage.
///
/// It follows WalkController (the phone app) step for step, minus what only a phone has
/// (notifications, haptics, the map screen, a developer server). Keep the two in sync.
library;

import 'dart:async';
import 'dart:convert';

import '../api.dart';
import '../engine/characters.dart' as cast;
import '../engine/claude.dart';
import '../engine/engine.dart';
import '../engine/store.dart';
import '../l10n.dart';
import '../log_book.dart';
import '../minimap.dart';
import '../models.dart';
import '../radar.dart';

/// What the user chose on the phone page of the glasses app.
class CoreSettings {
  CoreSettings({
    this.apiKey = '',
    this.codename = '',
    this.lang = 'ja',
    this.themes = defaultThemes,
    this.frequency = CallFrequency.normal,
    this.pinRange = LogRange.today,
    this.contact = '',
  });

  factory CoreSettings.fromJson(Map<String, dynamic> j) {
    final lang = j['lang'] == 'en' ? 'en' : 'ja';
    final themes = [for (final t in (j['themes'] as List? ?? const [])) if (cast.specialists.containsKey(t)) t as String];
    final codename = (j['codename'] as String? ?? '').trim();
    return CoreSettings(
      apiKey: (j['apiKey'] as String? ?? '').trim(),
      codename: codename.isEmpty ? (lang == 'en' ? 'Walker' : 'ウォーカー') : codename,
      lang: lang,
      themes: themes.isEmpty ? defaultThemes : themes,
      frequency: CallFrequency.values.asNameMap()[j['frequency']] ?? CallFrequency.normal,
      pinRange: LogRange.values.asNameMap()[j['pinRange']] ?? LogRange.today,
      contact: (j['contact'] as String? ?? '').trim(),
    );
  }

  final String apiKey, codename, lang, contact;
  final List<String> themes;
  final CallFrequency frequency;
  final LogRange pinRange;

  String get userAgent =>
      'CodeWalk/0.1 (Even G2 app; ${contact.isEmpty ? 'https://www.mediawiki.org/wiki/API:Etiquette' : contact})';
}

/// The call log kept by the glasses app (newest first).
class LogBook with LogQueries {
  LogBook(this.entries);

  factory LogBook.fromJson(String? json) {
    try {
      return LogBook([for (final e in jsonDecode(json ?? '[]') as List) LogEntry.fromJson(e as Map<String, dynamic>)]);
    } catch (_) {
      return LogBook([]); // a broken log starts over rather than stopping the walk
    }
  }

  @override
  final List<LogEntry> entries;

  /// Most recent first; long logs are trimmed so they fit the Even Hub storage.
  String toJson({int max = 300}) => jsonEncode([for (final e in entries.take(max)) e.toJson()]);
}

/// The call being played (like RadioSession, without Flutter).
class CallSession {
  Dialogue? dialogue;
  int index = 0;
  bool finished = false;
  bool get active => dialogue != null;

  void start(Dialogue d) {
    dialogue = d;
    index = 0;
    finished = false;
  }

  void next() {
    final d = dialogue;
    if (d == null || finished) return;
    if (index + 1 < d.lines.length) {
      index++;
    } else {
      finished = true;
    }
  }

  void prev() {
    if (dialogue == null) return;
    if (finished) {
      finished = false;
    } else if (index > 0) {
      index--;
    }
  }

  void end() {
    dialogue = null;
    index = 0;
    finished = false;
  }
}

/// What the core needs from the host (the TypeScript side).
abstract interface class CoreHost {
  /// Something the glasses or the phone page show has changed.
  void changed();

  /// Persist [value] under [key] ('store': engine cache, 'log': call log).
  Future<void> save(String key, String value);

  /// A finished generation cost [usd] (to total up this month's spend).
  void spend(double usd);

  void debug(String message);
}

class WalkCore {
  WalkCore(this.host, {required String? storeJson, required String? logJson, required CoreSettings settings})
      : log = LogBook.fromJson(logJson),
        _settings = settings {
    _store = Store.fromJson(storeJson, persist: (json) => host.save('store', json));
    setLang(settings.lang);
    _rebuildEngine();
    minimap = MiniMap(userAgent: settings.userAgent);
  }

  final CoreHost host;
  final LogBook log;
  final session = CallSession();
  late final MiniMap minimap;
  late final Store _store;
  late Engine _engine;
  CoreSettings _settings;
  CoreSettings get settings => _settings;

  bool walking = false;
  double? lat, lon;
  double speedMps = 0;
  double walkedM = 0;
  int callsThisWalk = 0;
  String status = '';
  List<Spot> spots = [];
  Spot? area;
  Dialogue? incoming;
  double? _ringLat, _ringLon;

  Timer? _tick;
  double? _fetchLat, _fetchLon;
  DateTime? _fetchAt, _lastCallAt, _walkStartedAt;
  bool _fetching = false, _asking = false;
  final Set<String> _unavailable = {};
  final Map<String, DateTime> _lastPoll = {};
  Spot? _chat;
  String? _chatTheme;
  int? _chatDay;

  Backend get _api => LocalBackend(_engine);

  void _rebuildEngine() {
    _engine = Engine(
      store: _store,
      apiKey: _settings.apiKey,
      userAgent: _settings.userAgent,
      log: host.debug,
      onUsage: (u) {
        final usd = u['usd'];
        if (usd is num) host.spend(usd.toDouble());
      },
    );
  }

  void updateSettings(CoreSettings next) {
    final newKey = next.apiKey != _settings.apiKey;
    final rebuild = newKey || next.contact != _settings.contact;
    _settings = next;
    if (newKey) _store.forgetKeyErrors();
    setLang(next.lang);
    if (rebuild) {
      _rebuildEngine();
      if (status == t.apiKeyMissing || status == t.apiKeyInvalid) _setStatus(walking ? t.standingBy : '');
    }
    host.changed();
  }

  /// Checks the key with a 1-token call: 'ok', 'bad_key', 'no_key' or 'error STATUS'.
  Future<String> checkKey() async {
    try {
      await _engine.checkKey();
      return 'ok';
    } on ClaudeError catch (e) {
      if (!_engine.hasKey) return 'no_key';
      return e.badKey ? 'bad_key' : 'error ${e.status}';
    } catch (_) {
      return 'error network';
    }
  }

  // --- the walk (same flow as WalkController) ----------------------------------------------------

  static const _keyProblems = {'no_api_key', 'bad_key'};
  void _keyProblem(String reason) => _setStatus(reason == 'bad_key' ? t.apiKeyInvalid : t.apiKeyMissing);

  List<String> get _themes {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return rotateThemes(_settings.themes, log.entries.where((e) => e.receivedAt.isAfter(since)).map((e) => e.dialogue.theme));
  }

  void start() {
    if (walking) return;
    walking = true;
    walkedM = 0;
    _walkStartedAt = DateTime.now();
    callsThisWalk = 0;
    _setStatus(_settings.apiKey.isEmpty ? t.apiKeyMissing : t.standingBy);
    _tick = Timer.periodic(const Duration(seconds: 8), (_) => _evaluate());
    final la = lat, lo = lon;
    if (la != null && lo != null) {
      _fetchRoads(la, lo); // the minimap needs no new position to start
      unawaited(_evaluate());
    }
  }

  /// Roads for the glasses minimap: the tile under the user first, the ones around as they arrive.
  void _fetchRoads(double la, double lo) {
    unawaited(minimap.maybeFetchRoads(la, lo, onMore: host.changed).then((fresh) {
      if (fresh) host.changed();
    }));
  }

  void stop() {
    _tick?.cancel();
    walking = false;
    _setStatus('');
  }

  void position(double newLat, double newLon, double speed) {
    if (lat != null && lon != null && walking) {
      final d = distanceM(lat!, lon!, newLat, newLon);
      if (d < 500) walkedM += d; // ignore jumps (GPS glitches)
    }
    lat = newLat;
    lon = newLon;
    speedMps = speed < 0 ? 0 : speed;
    if (walking) _fetchRoads(newLat, newLon);
    host.changed();
    if (walking) unawaited(_evaluate());
  }

  Future<void> _evaluate() async {
    final la = lat, lo = lon;
    if (!walking || la == null || lo == null) return;
    final now = DateTime.now();
    if (!_fetching && shouldRefetch(lat: la, lon: lo, lastLat: _fetchLat, lastLon: _fetchLon, now: now, lastAt: _fetchAt)) {
      await _fetchSpots(la, lo);
    }
    if (incoming != null || _asking || session.active) return;
    final excluded = {...log.recentlyHeard(now, revisitAfter), ..._unavailable};
    final candidates = candidatesToCall(
      spots: spots, lat: la, lon: lo, speedMps: speedMps, themes: _themes, excluded: excluded, now: now,
      lastCallAt: _lastCallAt, minInterval: _settings.frequency.minInterval,
    );
    if (candidates.isNotEmpty) {
      await _askBest(candidates, now);
      return;
    }
    final target = areaToCall(
      area: area, speedMps: speedMps, themes: _themes, excluded: excluded, now: now,
      lastCallAt: _lastCallAt, minInterval: _settings.frequency.minInterval,
    );
    if (target != null) {
      await _ask(target, now);
      return;
    }
    final startedAt = _walkStartedAt;
    final chat = _chat, chatTheme = _chatTheme;
    if (startedAt == null || chat == null || chatTheme == null) return;
    if (excluded.contains(chat.id) || log.heardSpotIds.contains(chat.id)) return;
    if (chatDue(speedMps: speedMps, now: now, walkStartedAt: startedAt, lastCallAt: _lastCallAt)) {
      await _ask(chat, now, themes: [chatTheme]);
    }
  }

  Future<void> _prepareChat(double la, double lo) async {
    final today = DateTime.now().day;
    if (_chat != null && _chatDay == today) return;
    final themes = _themes;
    if (themes.isEmpty) return;
    try {
      final spot = await _api.chatSpot(la, lo);
      if (spot == null || log.heardSpotIds.contains(spot.id)) return;
      _chat = spot;
      _chatTheme = themes.first;
      _chatDay = today;
      await _api.prefetch([spot.id], [themes.first], lang: _settings.lang);
    } catch (_) {
      // Best effort: the walk works without the chat call.
    }
  }

  Future<void> _askBest(List<Spot> candidates, DateTime now) async {
    final key = candidates.map((s) => s.id).join(',');
    final polled = _lastPoll[key];
    if (polled != null && now.difference(polled) < const Duration(seconds: 5)) return;
    _lastPoll[key] = now;
    _asking = true;
    try {
      final (r, skip) = await _api.bestDialogue([for (final s in candidates) s.id], _themes, _settings.codename,
          rounds: log.heardCounts, lang: _settings.lang);
      _unavailable.addAll(skip);
      switch (r) {
        case DialogueReady(:final dialogue):
          _ring(dialogue);
        case DialoguePending():
          _setStatus(candidates.length > 1
              ? t.researchingNearby(candidates.length)
              : t.researchingSpot(candidates.first.displayName));
        case DialogueUnavailable(:final reason):
          if (_keyProblems.contains(reason)) _keyProblem(reason);
      }
    } catch (_) {
      _setStatus(t.offlineRetry);
    } finally {
      _asking = false;
    }
  }

  Future<void> _ask(Spot spot, DateTime now, {List<String>? themes}) async {
    final polled = _lastPoll[spot.id];
    if (polled != null && now.difference(polled) < const Duration(seconds: 5)) return;
    _lastPoll[spot.id] = now;
    _asking = true;
    try {
      final r = await _api.dialogue(spot.id, themes ?? _themes, _settings.codename,
          round: log.heardCounts[spot.id] ?? 0, lang: _settings.lang);
      switch (r) {
        case DialogueReady(:final dialogue):
          _ring(dialogue);
        case DialoguePending():
          _setStatus(spot.kind == 'area' ? t.researchingTown(spot.displayName) : t.researchingSpot(spot.displayName));
        case DialogueUnavailable(:final reason):
          if (_keyProblems.contains(reason)) {
            _keyProblem(reason);
          } else if (reason != 'temporary_error') {
            _unavailable.add(spot.id);
          }
      }
    } catch (_) {
      _setStatus(t.offlineRetry);
    } finally {
      _asking = false;
    }
  }

  Future<void> _fetchSpots(double la, double lo) async {
    _fetching = true;
    try {
      spots = await _api.spots(la, lo);
      _fetchLat = la;
      _fetchLon = lo;
      _fetchAt = DateTime.now();
      final ahead = prefetchCandidates(
        spots: spots, lat: la, lon: lo, themes: _themes,
        excluded: {...log.recentlyHeard(DateTime.now(), revisitAfter), ..._unavailable},
      );
      await _api.prefetch(ahead.take(prefetchAhead).map((s) => s.id).toList(), _themes, rounds: log.heardCounts, lang: _settings.lang);
      await _fetchArea(la, lo);
      await _prepareChat(la, lo);
      if (incoming == null && status != t.apiKeyMissing && status != t.apiKeyInvalid) _setStatus(t.standingBy);
    } catch (_) {
      _setStatus(t.areaUnavailable);
      _fetchAt = DateTime.now().subtract(refetchInterval - const Duration(seconds: 30));
      _fetchLat = la;
      _fetchLon = lo;
    } finally {
      _fetching = false;
    }
  }

  Future<void> _fetchArea(double la, double lo) async {
    try {
      final a = await _api.area(la, lo);
      final isNew = a != null && a.id != area?.id;
      area = a;
      final heard = {...log.recentlyHeard(DateTime.now(), revisitAfter), ..._unavailable};
      if (isNew && !heard.contains(a.id)) {
        await _api.prefetch([a.id], _themes, rounds: log.heardCounts, lang: _settings.lang);
      }
    } catch (_) {
      // Town lookup is best-effort.
    }
  }

  // --- calls ---------------------------------------------------------------------------------

  /// Unanswered calls go to the log as "あとで" after this long (the glasses stop blinking too).
  static const autoLaterAfter = Duration(seconds: 10);
  Timer? _autoLater;

  void _ring(Dialogue d) {
    incoming = d;
    _autoLater?.cancel();
    _autoLater = Timer(autoLaterAfter, () {
      if (identical(incoming, d)) unawaited(later(auto: true));
    });
    _ringLat = lat;
    _ringLon = lon;
    _lastCallAt = DateTime.now();
    callsThisWalk++;
    _setStatus('');
  }

  Future<void> _saveLog() => host.save('log', log.toJson());

  Future<void> answer() async {
    final d = incoming;
    if (d == null) return;
    _autoLater?.cancel();
    incoming = null;
    log.newEntry(d, played: true, heardLat: _ringLat, heardLon: _ringLon);
    session.start(d);
    host.changed();
    await _saveLog();
  }

  Future<void> later({bool auto = false}) async {
    final d = incoming;
    if (d == null) return;
    _autoLater?.cancel();
    incoming = null;
    log.newEntry(d, played: false, heardLat: _ringLat, heardLon: _ringLon);
    _setStatus(auto ? t.savedToLogAuto : t.savedToLog);
    await _saveLog();
  }

  /// Play a call from the log on the glasses (the phone page's "play" button).
  Future<void> replay(String id) async {
    final e = log.entries.where((e) => e.id == id).firstOrNull;
    if (e == null || incoming != null) return;
    session.start(e.dialogue);
    if (!e.played) {
      e.played = true;
      await _saveLog();
    }
    host.changed();
  }

  /// A gesture from the glasses (same commands as the phone app's G2 bridge).
  Future<void> command(String cmd) async {
    switch (cmd) {
      case 'answer':
        await answer();
      case 'later':
        await later();
      case 'next':
        session.next();
      case 'prev':
        session.prev();
      case 'end':
        session.end();
      case 'walk': // a long press on the ring
        walking ? stop() : start();
    }
    host.changed();
  }

  void _setStatus(String s) {
    status = s;
    host.changed();
  }

  Future<void> flush() => _store.flush();

  // --- saved data (the phone page's "Saved data", same as the phone app's settings) -----------

  int get cachedDialogues => _store.dialogueCount;

  /// Delete every call: places heard before can ring again (as if for the first time).
  Future<void> clearLog() async {
    log.entries.clear();
    await _saveLog();
    host.changed();
  }

  /// Delete cached spots, towns and conversations, and what this walk learned from them.
  Future<void> clearCache() async {
    await _engine.clearCache();
    spots = [];
    area = null;
    _unavailable.clear();
    _lastPoll.clear();
    _chat = null;
    _chatTheme = null;
    _chatDay = null;
    _fetchAt = null;
    _fetchLat = null;
    _fetchLon = null;
    host.changed();
    if (walking) unawaited(_evaluate());
  }

  // --- what the glasses and the phone page show ----------------------------------------------

  /// Same shape as WalkController.g2State (the glasses' render.ts reads it), plus the photo URL
  /// (the glasses app fetches it itself).
  Map<String, dynamic> g2State() {
    Map<String, dynamic> sp(Speaker s) => {'id': s.id, 'name': s.name, 'frequency': s.frequency};
    final inc = incoming;
    final d = session.dialogue;
    final la = lat, lo = lon;
    return {
      'v': 1,
      'map': walking && la != null && lo != null
          ? minimap.state(la, lo, [for (final e in log.inRange(_settings.pinRange, DateTime.now())) (e.pinLat, e.pinLon)])
          : null,
      'walking': walking,
      'status': status,
      'codename': _settings.codename,
      'lang': _settings.lang,
      'freq': cast.commander.frequency,
      'stats': {'walkedM': walkedM.round()},
      'incoming': inc == null
          ? null
          : {'spot': inc.spotName, 'area': inc.isArea, 'commander': sp(inc.commander), 'specialist': sp(inc.specialist)},
      'call': d == null
          ? null
          : {
              'spot': d.spotName,
              'commander': sp(d.commander),
              'specialist': sp(d.specialist),
              'lines': [
                for (final l in d.lines) {'id': l.speaker, 'who': d.speaker(l.speaker).name, 'text': l.text},
              ],
              'index': session.index,
              'finished': session.finished,
              'sources': [for (final s in d.sources) s.title],
              'photo': d.image == null
                  ? null
                  : {'key': d.image!.url.hashCode, 'credit': '${d.image!.author} / ${d.image!.license}', 'url': d.image!.url},
            },
    };
  }

  /// Names and labels for the phone page's settings, in the current language (same texts as the phone app).
  Map<String, dynamic> catalog() {
    final lang = _settings.lang;
    return {
      'lang': lang,
      'commander': {'name': cast.commander.nameIn(lang), 'frequency': cast.commander.frequency},
      'themes': [
        for (final e in cast.specialists.entries)
          {
            'id': e.key,
            'label': t.themeLabels[e.key] ?? e.key,
            'topics': t.themeTopics[e.key] ?? '',
            'name': e.value.nameIn(lang),
            'frequency': e.value.frequency,
            'adult': adultThemes.contains(e.key),
          },
      ],
      'frequencies': {for (final f in CallFrequency.values) f.name: f.label},
      'ranges': {for (final r in LogRange.values) r.name: r.label},
      'aiNotice': t.aiNotice,
    };
  }

  /// The phone page's log list in [range] (newest first; today, the last 7 days, or all of it, as in
  /// the phone app's log).
  List<Map<String, dynamic>> logList({LogRange range = LogRange.all, int max = 100}) => [
        for (final e in log.inRange(range, DateTime.now()).take(max))
          {
            'id': e.id,
            'at': e.receivedAt.millisecondsSinceEpoch,
            'played': e.played,
            'spot': e.dialogue.spotName,
            'theme': e.dialogue.theme,
            'specialist': e.dialogue.specialist.name,
            'sources': [for (final s in e.dialogue.sources) {'title': s.title, 'url': s.url}],
          },
      ];
}
