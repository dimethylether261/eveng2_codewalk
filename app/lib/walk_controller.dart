import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'backend_host.dart';
import 'l10n.dart';
import 'models.dart';
import 'radio_session.dart';
import 'radar.dart';
import 'stores.dart';
import 'walk_log.dart';

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
  WalkController(this.settings, this.log, this.notifier, this.host);

  final AppSettings settings;
  final BackendHost host;

  /// The call being played on the radio screen.
  final session = RadioSession();

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
  WalkLog get _walkLog => host.walkLog;

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
    _walkLog.startWalk({
      'simulate': settings.simulate,
      'server': settings.serverUrl.isNotEmpty,
      'lang': settings.lang,
      'themes': settings.themes,
      'frequency': settings.frequency.name,
      'restrict_sources': settings.restrictSources,
    });
    walkedM = 0;
    _walkStartedAt = DateTime.now();
    callsThisWalk = 0;
    _setStatus(settings.simulate ? t.devModeHint : t.standingBy);
    _tick = Timer.periodic(const Duration(seconds: 8), (_) => _evaluate());
    if (lat != null && lon != null) unawaited(_evaluate());
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
    ).listen((p) => _onPosition(p.latitude, p.longitude, p.speed < 0 ? 0 : p.speed, accuracy: p.accuracy),
        onError: (Object e) {
      debugPrint('position stream error (forceLocationManager=$forceLocationManager): $e');
      _walkLog.event('location_error', {'error': '$e', 'location_manager': forceLocationManager});
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
    if (walking) _walkLog.event('walk_end', {'walked_m': walkedM.round(), 'calls': callsThisWalk});
    walking = false;
    _setStatus('');
  }

  /// Developer mode: jump to a point (as if walking there).
  void simulateMove(double toLat, double toLon) => _onPosition(toLat, toLon, 1.2);

  void _onPosition(double newLat, double newLon, double speed, {double? accuracy}) {
    if (walking) {
      _walkLog.event('pos', {
        'lat': _round6(newLat),
        'lon': _round6(newLon),
        'speed': (speed * 10).round() / 10,
        if (accuracy != null) 'accuracy_m': accuracy.round(),
      });
    }
    if (lat != null && lon != null && walking) {
      final d = distanceM(lat!, lon!, newLat, newLon);
      if (d < 500) walkedM += d; // ignore jumps (simulated teleports, GPS glitches)
    }
    lat = newLat;
    lon = newLon;
    speedMps = speed;
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
      if (skip.isNotEmpty) _walkLog.event('skip', {'spots': skip});
      switch (r) {
        case DialogueReady(:final dialogue):
          _ring(dialogue);
        case DialoguePending():
          _setStatus(candidates.length > 1
              ? t.researchingNearby(candidates.length)
              : t.researchingSpot(candidates.first.displayName));
        case DialogueUnavailable(:final reason):
          _walkLog.event('unavailable', {'spots': [for (final s in candidates) s.id], 'reason': reason});
          if (_keyProblems.contains(reason)) _keyProblem(reason);
      }
    } catch (e) {
      _walkLog.event('ask_error', {'error': '$e'});
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
          _walkLog.event('unavailable', {'spots': [spot.id], 'reason': reason});
          if (_keyProblems.contains(reason)) {
            _keyProblem(reason);
          } else if (reason != 'temporary_error') {
            _unavailable.add(spot.id); // not enough sourced facts: stay silent
          }
      }
    } catch (e) {
      _walkLog.event('ask_error', {'error': '$e'});
      _setStatus(t.offlineRetry);
    } finally {
      _asking = false;
    }
  }

  Future<void> _fetchSpots(double la, double lo) async {
    _fetching = true;
    final started = DateTime.now();
    try {
      spots = await _api.spots(la, lo);
      _walkLog.event('spots', {
        'lat': _round6(la),
        'lon': _round6(lo),
        'count': spots.length,
        'ms': DateTime.now().difference(started).inMilliseconds,
      });
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
    } catch (e) {
      _walkLog.event('spots_error', {'error': '$e', 'ms': DateTime.now().difference(started).inMilliseconds});
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
      if (isNew) _walkLog.event('area', {'id': a.id, 'name': a.name});
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
    _walkLog.event('ring', _callInfo(d));
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
    _walkLog.event('answer', _callInfo(d));
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
    _walkLog.event('later', {..._callInfo(d), 'auto': auto});
    unawaited(notifier.clear());
    _setStatus(auto ? t.savedToLogAuto : t.savedToLog);
    await log.add(d, played: false, heardLat: _ringLat, heardLon: _ringLon);
  }

  void _setStatus(String s) {
    if (walking && s != status) _walkLog.event('status', {'text': s});
    status = s;
    notifyListeners();
  }

  static double _round6(double v) => (v * 1e6).round() / 1e6;

  /// What the walk log keeps about a call.
  Map<String, dynamic> _callInfo(Dialogue d) => {'spot': d.spotId, 'name': d.spotName, 'theme': d.theme};

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _autoLater?.cancel();
    super.dispose();
  }
}
