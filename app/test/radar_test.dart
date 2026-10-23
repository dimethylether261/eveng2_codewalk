import 'package:codewalk/models.dart';
import 'package:codewalk/radar.dart';
import 'package:flutter_test/flutter_test.dart';

Spot spot(String id, double lat, double lon, [List<String> themes = const ['history']]) =>
    Spot(id: id, name: id, lat: lat, lon: lon, themes: themes, kind: 'shrine');

void main() {
  const lat = 35.6226, lon = 139.7389;
  final now = DateTime(2026, 10, 13, 14);
  final near = spot('near', lat + 0.0003, lon); // ~33 m
  final far = spot('far', lat + 0.003, lon); // ~330 m

  Spot? call({
    List<Spot>? spots,
    double speed = 1.2,
    List<String> themes = const ['history'],
    Set<String> excluded = const {},
    DateTime? lastCallAt,
  }) =>
      spotToCall(
        spots: spots ?? [near, far],
        lat: lat,
        lon: lon,
        speedMps: speed,
        themes: themes,
        excluded: excluded,
        now: now,
        lastCallAt: lastCallAt,
        minInterval: const Duration(minutes: 5),
      );

  test('distance is roughly right', () {
    expect(distanceM(lat, lon, lat + 0.001, lon), closeTo(111, 2));
  });

  test('rings only for a nearby, unheard spot of a tuned theme', () {
    expect(call()?.id, 'near');
    expect(call(spots: [far]), isNull);
    expect(call(excluded: {'near'}), isNull);
    expect(call(themes: ['architecture']), isNull);
  });

  test('stays quiet when moving fast or too soon after the last call', () {
    expect(call(speed: 8), isNull);
    expect(call(lastCallAt: now.subtract(const Duration(minutes: 2))), isNull);
    expect(call(lastCallAt: now.subtract(const Duration(minutes: 6)))?.id, 'near');
  });

  test('prefetch picks near matching spots, nearest first', () {
    final c = prefetchCandidates(
      spots: [far, near, spot('x', lat + 0.01, lon)],
      lat: lat,
      lon: lon,
      themes: ['history'],
      excluded: {},
    );
    expect(c.map((s) => s.id), ['near']);
  });

  test('town call: once per town, same quiet rules, spots first', () {
    final town = Spot(id: 'area:1', name: '北品川', lat: lat, lon: lon,
        themes: ['history', 'architecture', 'infrastructure'], kind: 'area');
    Spot? areaCall({double speed = 1.2, Set<String> excluded = const {}, DateTime? lastCallAt}) => areaToCall(
          area: town,
          speedMps: speed,
          themes: const ['infrastructure'],
          excluded: excluded,
          now: now,
          lastCallAt: lastCallAt,
          minInterval: const Duration(minutes: 5),
        );
    expect(areaCall()?.id, 'area:1');
    expect(areaCall(excluded: {'area:1'}), isNull);
    expect(areaCall(speed: 8), isNull);
    expect(areaCall(lastCallAt: now.subtract(const Duration(minutes: 1))), isNull);
  });

  test('themes rotate: least-heard first, ties keep user order', () {
    const tuned = ['history', 'architecture', 'infrastructure'];
    expect(rotateThemes(tuned, []), tuned);
    expect(rotateThemes(tuned, ['history', 'history', 'architecture']), ['infrastructure', 'architecture', 'history']);
    expect(rotateThemes(['architecture', 'history'], ['infrastructure']), ['architecture', 'history']);
  });

  test('in range, the least-heard theme wins over a nearer spot', () {
    final shrine = spot('shrine', lat + 0.0001, lon); // ~11 m, history
    final tower = spot('tower', lat + 0.0004, lon, ['architecture']); // ~44 m
    Spot? pick(List<String> themes) => spotToCall(
          spots: [shrine, tower],
          lat: lat,
          lon: lon,
          speedMps: 1,
          themes: themes,
          excluded: {},
          now: now,
          lastCallAt: null,
          minInterval: const Duration(minutes: 5),
        );
    expect(pick(['history', 'architecture'])?.id, 'shrine');
    expect(pick(['architecture', 'history'])?.id, 'tower');
  });

  test('candidates: all in range, least-heard theme first, then nearest, max 5', () {
    final shrine = spot('shrine', lat + 0.0001, lon); // 11 m, history
    final temple = spot('temple', lat + 0.0002, lon); // 22 m, history
    final tower = spot('tower', lat + 0.0004, lon, ['architecture']); // 44 m
    final far = spot('far', lat + 0.003, lon, ['architecture']);
    final c = candidatesToCall(
      spots: [temple, far, tower, shrine],
      lat: lat,
      lon: lon,
      speedMps: 1,
      themes: ['architecture', 'history'],
      excluded: {},
      now: now,
      lastCallAt: null,
      minInterval: const Duration(minutes: 5),
    );
    expect(c.map((s) => s.id), ['tower', 'shrine', 'temple']);
  });

  test('refetch after moving or waiting', () {
    expect(shouldRefetch(lat: lat, lon: lon, lastLat: null, lastLon: null, now: now, lastAt: null), isTrue);
    expect(shouldRefetch(lat: lat, lon: lon, lastLat: lat, lastLon: lon, now: now, lastAt: now), isFalse);
    expect(shouldRefetch(lat: lat + 0.002, lon: lon, lastLat: lat, lastLon: lon, now: now, lastAt: now), isTrue);
    expect(
        shouldRefetch(
            lat: lat, lon: lon, lastLat: lat, lastLon: lon, now: now, lastAt: now.subtract(const Duration(minutes: 4))),
        isTrue);
  });

  test('log pin uses where it was heard, falls back to the spot for old entries', () {
    final d = Dialogue.fromJson({
      'spot': {'id': 'osm:node:1', 'name': '品川神社', 'lat': 35.6195, 'lon': 139.7405},
      'theme': 'history',
      'specialist': {'id': 'shiori', 'name': 'フクロウ', 'frequency': '146.35'},
      'commander': {'id': 'ootori', 'name': 'シレイ', 'frequency': '147.20'},
      'lines': [],
      'sources': [],
    });
    final heard = LogEntry(id: '1', receivedAt: now, played: true, dialogue: d, heardLat: 35.62, heardLon: 139.741);
    final again = LogEntry.fromJson(heard.toJson());
    expect([again.pinLat, again.pinLon], [35.6195, 139.7405]);
    final old = LogEntry.fromJson({...heard.toJson()}..remove('heard_lat')..remove('heard_lon'));
    expect([old.pinLat, old.pinLon], [35.6195, 139.7405]);
    final j = heard.toJson();
    (j['dialogue'] as Map)['spot'] = {'id': 'x', 'name': '?'};
    final noSpot = LogEntry.fromJson(j);
    expect([noSpot.pinLat, noSpot.pinLon], [35.62, 139.741]);
    final town = heard.toJson();
    (town['dialogue'] as Map)['spot'] = {'id': 'area:1', 'name': '北品川', 'kind': 'area', 'lat': 35.6195, 'lon': 139.7405};
    final area = LogEntry.fromJson(town);
    expect([area.pinLat, area.pinLon], [35.62, 139.741]);
  });

  test('source URLs with broken percent-encoding do not throw', () {
    expect(displayUrl('https://ja.wikipedia.org/wiki/%E5%93%81%E5%B7%9D'), 'https://ja.wikipedia.org/wiki/品川');
    expect(displayUrl('https://example.com/100%_sure'), 'https://example.com/100%_sure');
    expect(sourceUri('https://example.com/100%_sure'), isNotNull);
    expect(sourceUri('https://ja.wikipedia.org/wiki/品川宿'), isNotNull);
  });

  test('dialogue JSON round-trips', () {
    final j = {
      'spot': {'id': 'osm:node:1', 'name': '品川宿', 'lat': 35.6, 'lon': 139.7},
      'theme': 'history',
      'specialist': {'id': 'shiori', 'name': 'フクロウ', 'frequency': '146.35'},
      'commander': {'id': 'ootori', 'name': 'シレイ', 'frequency': '147.20'},
      'lines': [
        {'speaker': 'shiori', 'text': '最初の宿場なの。', 'source_ids': [1]}
      ],
      'sources': [
        {'id': 1, 'title': '品川宿', 'url': 'https://ja.wikipedia.org/wiki/品川宿', 'quote': '…'}
      ],
      'image': null,
    };
    final d = Dialogue.fromJson(j);
    expect(d.speaker('shiori').name, 'フクロウ');
    final again = Dialogue.fromJson(d.toJson());
    expect(again.lines.single.sourceIds, [1]);
    expect(again.sources.single.url, contains('wikipedia'));
  });

  test('chat call: after 15 quiet minutes of walking', () {
    final start = DateTime(2026, 10, 14, 10);
    bool due(DateTime now, {DateTime? last, double speed = 1.2}) =>
        chatDue(speedMps: speed, now: now, walkStartedAt: start, lastCallAt: last);
    expect(due(start.add(const Duration(minutes: 14))), isFalse);
    expect(due(start.add(const Duration(minutes: 15))), isTrue);
    expect(due(start.add(const Duration(minutes: 20)), last: start.add(const Duration(minutes: 10))), isFalse);
    expect(due(start.add(const Duration(minutes: 25)), last: start.add(const Duration(minutes: 10))), isTrue);
    // a call from an earlier walk doesn't count
    expect(due(start.add(const Duration(minutes: 15)), last: start.subtract(const Duration(minutes: 1))), isTrue);
    expect(due(start.add(const Duration(hours: 1)), speed: 8), isFalse); // on a train / bike
  });

  test('only a few spots ahead are written in advance (each one costs a conversation)', () {
    expect(prefetchAhead, inInclusiveRange(2, 3));
  });
}
