/// On-device replacement for the CodeWalk server: nearby spots + fact-based radio dialogues.
///
/// Same operations the app used to call over HTTP (/spots, /area, /dialogue, /dialogue/best,
/// /prefetch), returning the same JSON shapes. Pure Dart, so it also runs from `dart run`.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'characters.dart';
import 'claude.dart';
import 'country.dart' as country;
import 'discover.dart' as discover;
import 'overpass.dart' as overpass;
import 'pipeline.dart' as pipeline;
import 'sources.dart';
import 'store.dart';
import 'util.dart';
import 'wikipedia.dart' as wikipedia;

const spotsTtlS = 7 * 24 * 3600;
const staleTtlS = 365 * 24 * 3600; // when the map server is down, older spots and towns are used up to this age
const dialogueTtlS = 30 * 24 * 3600;
const negativeTtlS = 7 * 24 * 3600;
const errorTtlS = 10 * 60;
const orderBonus = 0.1; // small preference for the app's order (least-heard theme, nearest) on equal scores

class _Semaphore {
  _Semaphore(this._free);
  int _free;
  final _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _free++;
    }
  }
}

/// One conversation to make: the place, who tells it, its cache slot (theme, or theme + round)
/// and what was already told there.
typedef _Req = ({Json spot, String theme, String slot, List<String> told, String lang});

class _Job {
  _Job(this.urgent);
  final bool urgent;
  bool started = false, cancelled = false;
}

class Engine {
  Engine({
    required this.store,
    required String? apiKey,
    this.config = const EngineConfig(),
    required this.userAgent,
    http.Client? client,
    this.log = print,
    this.onUsage,
    this.onEvent,
    int nowConcurrency = 2,
  })  : _http = client ?? http.Client(),
        _semNow = _Semaphore(nowConcurrency),
        _semBg = _Semaphore(1) {
    _llm = (apiKey == null || apiKey.isEmpty) ? null : Claude(apiKey, config: config, client: _http);
  }

  final Store store;
  final EngineConfig config;
  final String userAgent;
  final http.Client _http;
  final void Function(String) log;

  /// Called after each finished generation with its usage summary (to total up API spend).
  final void Function(Json usage)? onUsage;

  /// Called after each finished generation or town discovery with what happened (the phone app's walk log):
  /// `{'type': 'generation' | 'discover', 'outcome': ..., 'ms': ..., 'usage': ...}` and the spot.
  final void Function(Json event)? onEvent;

  Claude? _llm;
  // Two lanes: "now" for what the user is standing at, and a single background slot for
  // prefetching spots ahead, so prefetch never blocks a live request.
  final _Semaphore _semNow, _semBg;
  final _jobs = <String, _Job>{};
  final _discoverJobs = <String>{};
  final _discoverFailed = <String, DateTime>{};
  discover.PlaceFinder? _finder;

  /// Country lookups in flight per cell (spots, Wikipedia and the town ask at once: one request).
  final _countryLookups = <String, Future<String?>>{};

  /// The country lookup failed this launch: don't ask again until the next one (Nominatim may be
  /// down or refusing us; asking on every spot refresh would only add to it).
  bool _countryDown = false;

  bool get hasKey => _llm != null;

  /// Forget cached spots, towns and dialogues: places are looked up and conversations written again.
  /// A generation still running finishes and is kept.
  Future<void> clearCache() async {
    _discoverJobs.clear();
    _discoverFailed.clear();
    await store.clear();
  }

  Json health() => {'ok': true, 'llm': hasKey, 'provider': 'anthropic', 'model': config.model};

  /// Checks the API key with a 1-token call. Throws ClaudeError on a bad key.
  Future<void> checkKey() async {
    final llm = _llm;
    if (llm == null) throw ClaudeError(401, 'no key');
    await llm.ping();
    store.forgetKeyErrors(); // the key works: earlier 401/403s no longer apply
  }

  // --- spots ---------------------------------------------------------------

  Future<List<Json>> spots(double lat, double lon, {int radius = 400}) async {
    // v2: themes reassigned after the 暮らし・インフラ theme was retired (older cached answers are refetched).
    final key = 'v2:${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)},$radius';
    final cached = store.getArea(key, spotsTtlS);
    if (cached != null) return [for (final x in [...cached, ..._webSpotsNear(lat, lon, radius, cached)]) publicSpot(x)];
    Object? osmErr, wpErr;
    final code = await _country(lat, lon);
    final japan = code != null ? code == 'jp' : overpass.inJapanBox(lat, lon);
    final results = await Future.wait([
      overpass.fetchSpots(_http, userAgent, lat, lon, radius, japan: japan).catchError((Object e) {
        osmErr = e;
        return <Json>[];
      }),
      (config.wikipediaSpots ? _wikipediaSpots(lat, lon, radius) : Future.value(<Json>[])).catchError((Object e) {
        wpErr = e;
        return <Json>[];
      }),
    ]);
    if (osmErr != null) log('overpass failed: $osmErr');
    if (wpErr != null) log('wikipedia geosearch failed: $wpErr');
    var osm = results[0];
    if (osmErr != null) {
      // The public Overpass servers are often busy: an older answer here beats no map spots.
      final stale = [for (final s in store.getArea(key, staleTtlS) ?? const <Json>[]) if ((s['id'] as String).startsWith('osm:')) s];
      if (stale.isNotEmpty) {
        log('using ${stale.length} map spots from an older answer');
        osm = stale;
      } else if (wpErr != null) {
        throw StateError('spots unavailable');
      }
    }
    final found = merge(osm, results[1]);
    if (osmErr == null) {
      store.putArea(key, found); // cache only complete answers
    } else {
      store.putSpots(found); // still askable; the area is fetched again next time
    }
    return [for (final x in [...found, ..._webSpotsNear(lat, lon, radius, found)]) publicSpot(x)];
  }

  /// Japanese Wikipedia, plus the local edition(s) abroad. An article in both is kept once (the
  /// Japanese one: its title is the name). Only the Japanese search failing counts as a failure.
  Future<List<Json>> _wikipediaSpots(double lat, double lon, int radius) async {
    final ja = wikipedia.fetchSpots(_http, userAgent, lat, lon, radius);
    final local = <Json>[];
    for (final lang in country.wikisFor(await _country(lat, lon))) {
      try {
        local.addAll(await wikipedia.fetchSpots(_http, userAgent, lat, lon, radius, lang: lang));
      } catch (e) {
        log('wikipedia ($lang) geosearch failed: $e');
      }
    }
    final spots = await ja;
    final known = {for (final s in spots) s['wikidata']};
    for (final s in local) {
      if (known.add(s['wikidata'])) spots.add(s);
    }
    return spots;
  }

  /// The country at the point, cached per 1-degree cell (a year: borders rarely move). Null when
  /// unknown: callers then go by [overpass.inJapanBox] and search no local Wikipedia edition.
  Future<String?> _country(double lat, double lon) async {
    final key = 'country:${country.countryCell(lat, lon)}';
    final cached = store.getValue(key, 365 * 24 * 3600);
    if (cached != null) return cached.$1 as String?;
    if (_countryDown) return null;
    return _countryLookups[key] ??= () async {
      try {
        final code = await country.countryCode(_http, userAgent, lat, lon);
        if (code != null) {
          store.putValue(key, code);
        } else {
          _countryDown = true; // error or no country (sea): not again this launch
        }
        return code;
      } finally {
        _countryLookups.remove(key);
      }
    }();
  }

  /// Landmarks found by web search within the radius, minus ones that duplicate an OSM spot.
  List<Json> _webSpotsNear(double lat, double lon, int radius, List<Json> osm) {
    final osmIds = {for (final x in osm) x['id']};
    return [
      for (final w in store.spotsWithPrefix('web:'))
        if (distanceM(lat, lon, (w['lat'] as num).toDouble(), (w['lon'] as num).toDouble()) <= radius &&
            !osmIds.contains((w['_tags'] as Map?)?['osm']))
          w,
    ];
  }

  Future<void> _runDiscover(Json town, Claude llm) async {
    final usage = Usage();
    final id = town['id'] as String;
    final started = DateTime.now();
    var event = <String, dynamic>{'outcome': 'error'};
    try {
      _finder ??= discover.PlaceFinder(_http, userAgent);
      final found = await discover.discover(llm.withUsage(usage), town, _finder!, store.spotsWithPrefix('osm:'));
      store.putArea('discover:$id', found);
      log('discovered ${found.length} web landmarks in ${town['name']}: ${found.map((x) => x['name']).join(', ')}');
      event = {'outcome': 'ready', 'found': found.length};
    } catch (e) {
      log('discovery failed for ${town['name']}: $e'); // best effort; retry after an hour
      _discoverFailed[id] = DateTime.now();
      event = {'outcome': 'error', 'reason': '$e'};
    } finally {
      onEvent?.call({
        'type': 'discover',
        'spot': {'id': id, 'name': town['name']},
        ...event,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'usage': usage.summary(),
      });
      if (usage.steps.isNotEmpty) {
        log('usage discover ${town['name']}: ${usage.describe()}');
        onUsage?.call(usage.summary());
      }
      _discoverJobs.remove(id);
    }
  }

  void _maybeDiscover(Json? town) {
    final llm = _llm;
    if (town == null || llm == null || !config.discoverEnabled) return;
    final id = town['id'] as String;
    if (_discoverJobs.contains(id)) return;
    final failed = _discoverFailed[id];
    if (failed != null && DateTime.now().difference(failed) < const Duration(hours: 1)) return;
    if (store.getArea('discover:$id', dialogueTtlS) != null) return;
    _discoverJobs.add(id);
    unawaited(_runDiscover(town, llm));
  }

  /// The town (町) the point is in, as a spot the app can ask a dialogue for.
  Future<Json?> area(double lat, double lon) async {
    final key = 'area:${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
    final cached = store.getArea(key, dialogueTtlS);
    if (cached != null) {
      _maybeDiscover(cached.firstOrNull);
      return cached.isEmpty ? null : publicSpot(cached.first);
    }
    final code = await _country(lat, lon);
    Json? town;
    try {
      town = await overpass.fetchArea(_http, userAgent, lat, lon, country: code);
    } catch (e) {
      final stale = store.getArea(key, staleTtlS);
      if (stale == null) rethrow;
      log('town lookup failed ($e): using the older answer');
      return stale.isEmpty ? null : publicSpot(stale.first);
    }
    if (town != null) {
      town = store.getSpot(town['id'] as String) ?? town; // keep the first point we saw as the town's pin
    }
    store.putArea(key, town == null ? [] : [town]);
    _maybeDiscover(town);
    return town == null ? null : publicSpot(town);
  }

  /// The "今日は何の日" chat call for [day]: a topic tied to today's date, not to a place, told by
  /// whichever specialist the app asks for (researched from that date's Wikipedia page).
  /// One per day; pinned where the user is.
  Json chatSpot(double lat, double lon, DateTime day) {
    final date = '${day.month}月${day.day}日';
    final spot = <String, dynamic>{
      'id': 'chat:${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
      'name': '今日は何の日（$date）',
      'name_en': 'On this day (${const ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][day.month]} ${day.day})',
      'lat': round6(lat),
      'lon': round6(lon),
      'themes': List<String>.of(allThemes),
      'kind': 'chat',
      'wikipedia': 'ja:$date',
      '_tags': {'date': date},
    };
    final existing = store.getSpot(spot['id'] as String);
    if (existing == null) store.putSpots([spot]);
    return publicSpot(existing ?? spot);
  }

  // --- dialogues -----------------------------------------------------------

  Future<void> _runJob(_Req req, _Job job, Claude llm) async {
    final (:spot, :theme, :slot, :told, :lang) = req;
    final sem = job.urgent ? _semNow : _semBg;
    await sem.acquire();
    final key = '${spot['id']}|$slot';
    final usage = Usage();
    DateTime? started;
    Json? event;
    try {
      if (job.cancelled) return; // moved to the fast lane while waiting
      job.started = true;
      started = DateTime.now();
      try {
        final image = await fetchImage(_http, spot['wikidata'] as String?, userAgent);
        final dialogue = await pipeline.generate(llm.withUsage(usage), spot, theme, image: image, told: told, lang: lang);
        dialogue['usage'] = usage.summary();
        store.putDialogue(spot['id'] as String, slot, 'ready', dialogue: dialogue);
        event = {'outcome': 'ready', 'review': dialogue['review'], 'lines': (dialogue['lines'] as List).length};
      } on Unavailable catch (e) {
        store.putDialogue(spot['id'] as String, slot, 'unavailable', reason: e.reason);
        event = {'outcome': 'unavailable', 'reason': e.reason};
      } on ClaudeRefused {
        store.putDialogue(spot['id'] as String, slot, 'unavailable', reason: 'refused');
        event = {'outcome': 'unavailable', 'reason': 'refused'};
      } on ClaudeError catch (e) {
        log('generation failed for $key: $e');
        store.putDialogue(spot['id'] as String, slot, 'error', reason: e.badKey ? 'bad_key' : 'api_error');
        event = {'outcome': 'error', 'reason': e.badKey ? 'bad_key' : 'api_error', 'detail': '$e'};
      } catch (e, st) {
        // keep the engine alive; retry after errorTtlS
        log('generation failed for $key: $e\n$st');
        store.putDialogue(spot['id'] as String, slot, 'error', reason: e.runtimeType.toString());
        event = {'outcome': 'error', 'reason': e.runtimeType.toString(), 'detail': '$e'};
      }
    } finally {
      sem.release();
      if (started != null) {
        onEvent?.call({
          'type': 'generation',
          'spot': {'id': spot['id'], 'name': spot['name'], 'kind': spot['kind'] ?? 'spot'},
          'theme': theme,
          'slot': slot,
          'prefetch': !job.urgent,
          ...?event,
          'ms': DateTime.now().difference(started).inMilliseconds,
          'usage': usage.summary(),
        });
      }
      if (usage.steps.isNotEmpty) {
        log('usage ${spot['name']}/$theme (${spot['id']})${job.urgent ? '' : ' [prefetch]'}: ${usage.describe()}');
        onUsage?.call(usage.summary());
      }
      if (identical(_jobs[key], job)) _jobs.remove(key);
    }
  }

  /// Was [dialogue] written by today's cast (same names as now)?
  static bool _currentCast(Json? dialogue, String theme, String lang) {
    final sp = specialists[theme];
    return dialogue != null &&
        sp != null &&
        (dialogue['specialist'] as Map?)?['name'] == sp.nameIn(lang) &&
        (dialogue['commander'] as Map?)?['name'] == commander.nameIn(lang);
  }

  /// ('ready', dialogue) | ('unavailable', reason) | ('start', _Req) | ('pending', _Req).
  ///
  /// [round] = how many times the user heard this place before. Round 0 is the first conversation;
  /// later rounds are new ones: a specialist who hasn't spoken here yet comes first, and what was
  /// already told goes to research and writing so the talk moves on to something else.
  ///
  /// [lang]: dialogue language; each language has its own conversations (Japanese keeps the
  /// original cache slots).
  (String, Object?) _lookup(String spotId, List<String> themes, {int round = 0, String lang = 'ja'}) {
    final spot = store.getSpot(spotId);
    if (spot == null) return ('unavailable', 'unknown_spot');
    var told = const <String>[];
    var order = themes;
    if (round > 0) {
      // Earlier rounds only: this round's own conversation is not "before".
      int roundOf(String slot) => int.tryParse(RegExp(r'\|r(\d+)').firstMatch(slot)?.group(1) ?? '') ?? 0;
      final before = [
        for (final (slot, d) in store.readyDialoguesFor(spotId))
          if (roundOf(slot) < round) d,
      ];
      final spoke = {for (final d in before) d['theme']};
      order = [...themes.where((t) => !spoke.contains(t)), ...themes.where(spoke.contains)];
      told = pipeline.toldBefore(before);
    }
    final theme = pipeline.pickTheme(spot, order);
    if (theme == null) return ('unavailable', 'theme_mismatch');
    // Cache key part: a new conversation per round and per language.
    final slot = '$theme${round == 0 ? '' : '|r$round'}${lang == 'ja' ? '' : '|$lang'}';
    final req = (spot: spot, theme: theme, slot: slot, told: told, lang: lang);
    final cached = store.getDialogue(spotId, slot);
    if (cached != null) {
      final (status, reason, dialogue, ts) = cached;
      final age = DateTime.now().millisecondsSinceEpoch / 1000 - ts;
      // A conversation written before the cast was renamed would bring back the old names and voices.
      if (status == 'ready' && age < dialogueTtlS && _currentCast(dialogue, theme, lang)) return ('ready', dialogue);
      if (status == 'unavailable' && age < negativeTtlS) return ('unavailable', reason);
      if (status == 'error' && age < errorTtlS) return ('unavailable', reason == 'bad_key' ? 'bad_key' : 'temporary_error');
    }
    if (_jobs.containsKey('$spotId|$slot')) return ('pending', req);
    if (_llm == null) return ('unavailable', 'no_api_key');
    return ('start', req);
  }

  void _start(_Req req, {required bool urgent}) {
    final llm = _llm;
    if (llm == null) return;
    final (:spot, :theme, :slot, told: _, lang: _) = req;
    final key = '${spot['id']}|$slot';
    final old = _jobs[key];
    if (old != null) {
      if (old.started || old.urgent || !urgent) return; // already running (or already in the fast lane)
      old.cancelled = true; // still waiting in the background lane: move it to the fast lane
      log('moved ${spot['name']}/$theme from prefetch queue to now');
    }
    final job = _Job(urgent);
    _jobs[key] = job;
    unawaited(_runJob(req, job, llm));
  }

  /// {status: ready, dialogue} | {status: pending} | {status: unavailable, reason}
  Json dialogue(String spotId, List<String> themes, String codename, {int round = 0, String lang = 'ja'}) {
    final (state, value) = _lookup(spotId, themes, round: round, lang: lang);
    if (state == 'ready') return {'status': 'ready', 'dialogue': pipeline.withCodename(value as Json, codename)};
    if (state == 'unavailable') return {'status': 'unavailable', 'reason': value};
    _start(value as _Req, urgent: true);
    return {'status': 'pending'};
  }

  /// Among nearby candidates, the best-reviewed dialogue that is ready.
  /// Candidates not generated yet are started; unavailable ones are listed in `skip`.
  Json bestDialogue(List<String> spotIds, List<String> themes, String codename,
      {Map<String, int> rounds = const {}, String lang = 'ja'}) {
    final ready = <(double, Json)>[];
    final skip = <String>[];
    var pending = false;
    String? keyProblem;
    for (var i = 0; i < spotIds.length && i < 5; i++) {
      final (state, value) = _lookup(spotIds[i], themes, round: rounds[spotIds[i]] ?? 0, lang: lang);
      if (state == 'ready') {
        final d = value as Json;
        final score = (((d['review'] as Map?)?['score'] ?? 3.0) as num).toDouble();
        ready.add((score - orderBonus * i, d));
      } else if (state == 'unavailable') {
        if (value == 'no_api_key' || value == 'bad_key') {
          keyProblem = value as String; // not the spot's fault: don't skip it for good
        } else if (value != 'temporary_error') {
          skip.add(spotIds[i]);
        }
      } else {
        _start(value as _Req, urgent: true);
        pending = true;
      }
    }
    if (ready.isNotEmpty) {
      final best = ready.reduce((a, b) => b.$1 > a.$1 ? b : a);
      if (ready.length > 1) {
        log('best of ${ready.length} ready: ${(best.$2['spot'] as Map)['name']} (${best.$1.toStringAsFixed(2)})');
      }
      return {'status': 'ready', 'dialogue': pipeline.withCodename(best.$2, codename), 'skip': skip};
    }
    if (pending) return {'status': 'pending', 'skip': skip};
    return {'status': 'unavailable', 'reason': keyProblem ?? 'none', 'skip': skip};
  }

  int prefetch(List<String> spotIds, List<String> themes, {Map<String, int> rounds = const {}, String lang = 'ja'}) {
    var queued = 0;
    for (final id in spotIds.take(20)) {
      final (state, value) = _lookup(id, themes, round: rounds[id] ?? 0, lang: lang);
      if (state == 'start') {
        _start(value as _Req, urgent: false);
        queued++;
      }
    }
    return queued;
  }

  /// Waits until no generation is running or queued (for scripts and tests).
  Future<void> idle() async {
    while (_jobs.isNotEmpty || _discoverJobs.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
