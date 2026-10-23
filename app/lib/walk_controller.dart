import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'backend_host.dart';
import 'radio_widgets.dart' show portraitPng;
import 'engine/characters.dart' as engine_chars;
import 'g2_bridge.dart';
import 'l10n.dart';
import 'minimap.dart';
import 'models.dart';
import 'radio_session.dart';
import 'radar.dart';
import 'stores.dart';

class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  void Function()? onTap;

  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (_) => onTap?.call(),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> incoming(Dialogue d) => _plugin.show(
        id: 1,
        title: 'CALL ${d.commander.frequency}',
        body: t.notifBody(d.commander.name, d.spotName),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'radio_call',
            t.notifTitleChannel,
            channelDescription: t.notifChannelDesc,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.call,
          ),
        ),
      );

  Future<void> clear() => _plugin.cancel(id: 1);
}

class WalkController extends ChangeNotifier {
  WalkController(this.settings, this.log, this.notifier, this.host) {
    minimap = MiniMap(userAgent: settings.userAgent);
    g2 = G2Bridge(
        state: g2State,
        onCommand: g2Command,
        token: () => settings.g2Code,
        roads: minimap.roadsJson,
        photo: _callPhoto,
        portrait: _portrait)
      ..onConnect = _fetchRoads;
    addListener(g2.changed);
    session.addListener(g2.changed);
    settings.addListener(_syncG2);
    _syncG2();
  }

  final AppSettings settings;
  final BackendHost host;

  /// The call being played (phone radio screen and glasses share it).
  final session = RadioSession();

  /// Link to the CODEWALK app on Even G2 (see g2/).
  late final G2Bridge g2;

  /// Roads and heard places for the minimap on the glasses.
  late final MiniMap minimap;

  void _syncG2() {
    if (settings.g2Enabled && !g2.running) {
      g2.start().catchError((Object e) => debugPrint('[g2] could not listen: $e'));
    } else if (!settings.g2Enabled && g2.running) {
      unawaited(g2.stop());
    }
  }

  /// What the glasses show (the g2/ app renders it).
  Map<String, dynamic> g2State() {
    Map<String, dynamic> sp(Speaker s) => {'id': s.id, 'name': s.name, 'frequency': s.frequency};
    final inc = incoming;
    final d = session.dialogue;
    final la = lat, lo = lon;
    return {
      'v': 1,
      // Waiting screen minimap: only while walking; heard places only (never unheard spots).
      'map': walking && la != null && lo != null
          ? minimap.state(la, lo, [for (final e in log.inRange(settings.pinRange, DateTime.now())) (e.pinLat, e.pinLon)])
          : null,
      'walking': walking,
      'status': status,
      'codename': settings.codename,
      'lang': settings.lang,
      'freq': engine_chars.commander.frequency,
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
              // The glasses fetch the picture from /photo; the credit goes on their sources page.
              'photo': d.image == null ? null : {'key': d.image!.url.hashCode, 'credit': '${d.image!.author} / ${d.image!.license}'},
            },
    };
  }

  final _portraits = <String, List<int>>{};

  /// Character portraits for the glasses (the bundled PNGs in assets/characters/, cached per id).
  Future<List<int>?> _portrait(String id) async {
    final cached = _portraits[id];
    if (cached != null) return cached;
    final png = await portraitPng(id);
    if (png != null) _portraits[id] = png;
    return png;
  }

  (String, (List<int>, String))? _photoCache;

  /// The photo of the call being played, fetched once (Wikimedia Commons thumbnail, ~800 px).
  Future<(List<int>, String)?> _callPhoto() async {
    final url = session.dialogue?.image?.url;
    if (url == null) return null;
    final cached = _photoCache;
    if (cached != null && cached.$1 == url) return cached.$2;
    try {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': settings.userAgent}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final photo = (r.bodyBytes as List<int>, r.headers['content-type'] ?? 'image/jpeg');
      _photoCache = (url, photo);
      return photo;
    } catch (_) {
      return null;
    }
  }

  /// Roads for the glasses minimap — only while walking with glasses connected (no extra map traffic otherwise).
  void _fetchRoads() {
    final la = lat, lo = lon;
    if (!walking || la == null || lo == null || g2.clients == 0) return;
    // The tile under the user first; the tiles around call g2.changed as they arrive.
    unawaited(minimap.maybeFetchRoads(la, lo, onMore: g2.changed).then((fresh) {
      if (fresh) g2.changed();
    }));
  }

  /// A command from the glasses.
  Future<void> g2Command(String cmd) async {
    switch (cmd) {
      case 'answer':
        if (incoming == null) return;
        final entry = await answer();
        if (entry != null) session.start(entry.dialogue);
      case 'later':
        if (incoming != null) await later();
      case 'next':
        session.next();
      case 'prev':
        session.prev();
      case 'end':
        session.end();
      case 'walk': // a long press on the ring: start or end the walk from the glasses
        if (walking) {
          await stop();
        } else {
          final err = await start();
          if (err != null) _setStatus(err); // e.g. location off: shown on the glasses' status line
        }
    }
  }
  final LogStore log;
  final Notifier notifier;

  bool walking = false;
  bool appInForeground = true;
  double? lat, lon;
  double speedMps = 0;
  double walkedM = 0;
  int callsThisWalk = 0;
  String status = '';
  List<Spot> spots = [];
  Spot? area; // the town (町) we're walking in
  Dialogue? incoming;
  double? _ringLat, _ringLon; // where the user was when [incoming] rang

  StreamSubscription<Position>? _sub;
  Timer? _tick;
  double? _fetchLat, _fetchLon;
  DateTime? _fetchAt, _lastCallAt;
  bool _fetching = false, _asking = false;
  final Set<String> _unavailable = {};
  final Map<String, DateTime> _lastPoll = {};

  Backend get _api => host.backend;

  /// Reasons that mean "fix the settings", not "this spot has nothing to say".
  static const _keyProblems = {'no_api_key', 'bad_key'};

  void _keyProblem(String reason) =>
      _setStatus(reason == 'bad_key' ? t.apiKeyInvalid : t.apiKeyMissing);

  /// Tuned themes, least-heard in the last 7 days first.
  List<String> get _themes {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return rotateThemes(
        settings.themes, log.entries.where((e) => e.receivedAt.isAfter(since)).map((e) => e.dialogue.theme));
  }

  Future<String?> start() async {
    if (walking) return null;
    if (!settings.simulate) {
      if (!await Geolocator.isLocationServiceEnabled()) return t.locationOff;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return t.locationPermission;
      }
      unawaited(_listen(forceLocationManager: false));
    }
    walking = true;
    walkedM = 0;
    _walkStartedAt = DateTime.now();
    callsThisWalk = 0;
    _setStatus(settings.simulate ? t.devModeHint : t.standingBy);
    _tick = Timer.periodic(const Duration(seconds: 8), (_) => _evaluate());
    if (lat != null && lon != null) {
      _fetchRoads(); // the minimap needs no new position to start
      unawaited(_evaluate());
    }
    return null;
  }

  /// Fused location first; if it reports the service as disabled (e.g. Google location
  /// accuracy turned off), fall back to the platform GPS provider.
  Future<void> _listen({required bool forceLocationManager}) async {
    final old = _sub;
    _sub = null;
    if (old != null) {
      await old.cancel();
      // Let the plugin tear down the previous stream before opening a new one.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!walking && forceLocationManager) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
        forceLocationManager: forceLocationManager,
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'CODEWALK',
          notificationText: t.foregroundText,
          enableWakeLock: true,
        ),
      ),
    ).listen((p) => _onPosition(p.latitude, p.longitude, p.speed < 0 ? 0 : p.speed), onError: (Object e) {
      debugPrint('position stream error (forceLocationManager=$forceLocationManager): $e');
      if (!forceLocationManager && e is LocationServiceDisabledException && walking) {
        unawaited(_listen(forceLocationManager: true));
        return;
      }
      _setStatus(t.locationUnavailable);
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _tick?.cancel();
    walking = false;
    _setStatus('');
  }

  /// Developer mode: jump to a point (as if walking there).
  void simulateMove(double toLat, double toLon) => _onPosition(toLat, toLon, 1.2);

  void _onPosition(double newLat, double newLon, double speed) {
    if (lat != null && lon != null && walking) {
      final d = distanceM(lat!, lon!, newLat, newLon);
      if (d < 500) walkedM += d; // ignore jumps (simulated teleports, GPS glitches)
    }
    lat = newLat;
    lon = newLon;
    speedMps = speed;
    if (walking) {
      _fetchRoads();
    }
    notifyListeners();
    if (walking) unawaited(_evaluate());
  }

  Future<void> _evaluate() async {
    final la = lat, lo = lon;
    if (!walking || la == null || lo == null) return;
    final now = DateTime.now();
    if (!_fetching && shouldRefetch(lat: la, lon: lo, lastLat: _fetchLat, lastLon: _fetchLon, now: now, lastAt: _fetchAt)) {
      await _fetchSpots(la, lo);
    }
    if (incoming != null || _asking || session.active) return; // don't ring over a call in progress
    // Places heard in the last hour stay quiet; after that they can ring again with a new conversation.
    final excluded = {...log.recentlyHeard(now, revisitAfter), ..._unavailable};
    final candidates = candidatesToCall(
      spots: spots,
      lat: la,
      lon: lo,
      speedMps: speedMps,
      themes: _themes,
      excluded: excluded,
      now: now,
      lastCallAt: _lastCallAt,
      minInterval: settings.frequency.minInterval,
    );
    if (candidates.isNotEmpty) {
      await _askBest(candidates, now);
      return;
    }
    final target = areaToCall(
          area: area,
          speedMps: speedMps,
          themes: _themes,
          excluded: excluded,
          now: now,
          lastCallAt: _lastCallAt,
          minInterval: settings.frequency.minInterval,
        );
    if (target != null) {
      await _ask(target, now);
      return;
    }
    // Nothing nearby for a while: the least-heard specialist brings up a "今日は何の日" topic.
    final startedAt = _walkStartedAt;
    final chat = _chat, chatTheme = _chatTheme;
    if (startedAt == null || chat == null || chatTheme == null) return;
    if (excluded.contains(chat.id) || log.heardSpotIds.contains(chat.id)) return; // once a day
    if (chatDue(speedMps: speedMps, now: now, walkStartedAt: startedAt, lastCallAt: _lastCallAt)) {
      await _ask(chat, now, themes: [chatTheme]);
    }
  }

  DateTime? _walkStartedAt;
  Spot? _chat; // today's chat call, prepared when the walk starts
  String? _chatTheme; // who tells it: the least-heard tuned theme when it was prepared
  int? _chatDay; // day of month it was prepared for

  /// Prepare today's chat call in the background so it is ready when the walk goes quiet.
  /// The specialist is fixed now (the least-heard one), so the prepared dialogue is the one that rings.
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
      await _api.prefetch([spot.id], [themes.first], lang: settings.lang);
    } catch (_) {
      // Best effort: the walk works without the chat call.
    }
  }

  /// Several spots in range: the engine answers with the best-reviewed ready dialogue.
  Future<void> _askBest(List<Spot> candidates, DateTime now) async {
    final key = candidates.map((s) => s.id).join(',');
    final polled = _lastPoll[key];
    if (polled != null && now.difference(polled) < const Duration(seconds: 5)) return;
    _lastPoll[key] = now;
    _asking = true;
    try {
      final (r, skip) = await _api.bestDialogue([for (final s in candidates) s.id], _themes, settings.codename,
          rounds: log.heardCounts, lang: settings.lang);
      _unavailable.addAll(skip); // not enough sourced facts there: stay silent
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
      final r = await _api.dialogue(spot.id, themes ?? _themes, settings.codename,
          round: log.heardCounts[spot.id] ?? 0, lang: settings.lang);
      switch (r) {
        case DialogueReady(:final dialogue):
          _ring(dialogue);
        case DialoguePending():
          _setStatus(spot.kind == 'area' ? t.researchingTown(spot.displayName) : t.researchingSpot(spot.displayName));
        case DialogueUnavailable(:final reason):
          if (_keyProblems.contains(reason)) {
            _keyProblem(reason);
          } else if (reason != 'temporary_error') {
            _unavailable.add(spot.id); // not enough sourced facts: stay silent
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
        spots: spots,
        lat: la,
        lon: lo,
        themes: _themes,
        excluded: {...log.recentlyHeard(DateTime.now(), revisitAfter), ..._unavailable},
      );
      await _api.prefetch(ahead.take(prefetchAhead).map((s) => s.id).toList(), _themes, rounds: log.heardCounts, lang: settings.lang);
      await _fetchArea(la, lo);
      await _prepareChat(la, lo);
      if (incoming == null) _setStatus(t.standingBy);
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
        // start researching the town right away
        await _api.prefetch([a.id], _themes, rounds: log.heardCounts, lang: settings.lang);
      }
    } catch (_) {
      // Town lookup is best-effort; spots still work without it.
    }
  }

  /// The settings screen deleted the conversation cache: also forget what this walk learned from it
  /// (spots, the town, places with too little to say, today's chat), so everything is looked up again.
  Future<void> clearCache() async {
    await host.clearCache();
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
    notifyListeners();
    if (walking) unawaited(_evaluate());
  }

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
    if (appInForeground) {
      HapticFeedback.heavyImpact();
    } else {
      unawaited(notifier.incoming(d));
    }
  }

  /// User answered: store as played and hand the dialogue to the radio screen.
  /// Null when the call already went to the log (e.g. it timed out at the same moment).
  Future<LogEntry?> answer() async {
    final d = incoming;
    if (d == null) return null;
    _autoLater?.cancel();
    incoming = null;
    unawaited(notifier.clear());
    notifyListeners();
    return log.add(d, played: true, heardLat: _ringLat, heardLon: _ringLon);
  }

  /// "あとで" (also automatic after [autoLaterAfter]): keep it in the log as unplayed.
  Future<void> later({bool auto = false}) async {
    final d = incoming;
    if (d == null) return;
    _autoLater?.cancel();
    incoming = null;
    unawaited(notifier.clear());
    _setStatus(auto ? t.savedToLogAuto : t.savedToLog);
    await log.add(d, played: false, heardLat: _ringLat, heardLon: _ringLon);
  }

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _autoLater?.cancel();
    settings.removeListener(_syncG2);
    unawaited(g2.stop());
    super.dispose();
  }
}
