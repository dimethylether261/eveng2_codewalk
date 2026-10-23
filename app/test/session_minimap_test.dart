import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:codewalk/engine/vector_tiles.dart' as tiles;
import 'package:codewalk/minimap.dart';
import 'package:codewalk/models.dart';
import 'package:codewalk/radio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Dialogue dialogue() => Dialogue.fromJson({
      'spot': {'id': 'osm:node:1', 'name': '品川神社', 'lat': 35.6, 'lon': 139.7, 'kind': 'shrine'},
      'theme': 'history',
      'specialist': {'id': 'shiori', 'name': 'フクロウ', 'frequency': '146.35'},
      'commander': {'id': 'ootori', 'name': 'シレイ', 'frequency': '147.20'},
      'lines': [
        {'speaker': 'ootori', 'text': 'ウォーカー、聞こえるか。', 'source_ids': []},
        {'speaker': 'shiori', 'text': '鳥居に龍がいるの。', 'source_ids': [1]},
      ],
      'sources': [
        {'id': 1, 'title': '品川神社', 'url': 'https://ja.wikipedia.org/wiki/品川神社'},
      ],
    });

/// A vector tile with one `transportation` layer of lines (what OpenFreeMap serves), each line a
/// class and its points.
Uint8List roadTile(int z, int x, int y, List<(String, List<(double, double)>)> lines) {
  List<int> varint(int v) {
    final out = <int>[];
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    return out..add(v);
  }

  List<int> bytes(int field, List<int> b) => [...varint(field << 3 | 2), ...varint(b.length), ...b];
  List<int> packed(int field, List<int> values) => bytes(field, [for (final v in values) ...varint(v)]);
  int zigzag(int n) => n >= 0 ? n * 2 : -n * 2 - 1;
  final n = math.pow(2, z);
  (int, int) px(double lat, double lon) {
    final r = lat * math.pi / 180;
    final ty = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n;
    return ((((lon + 180) / 360 * n - x) * 4096).round(), ((ty - y) * 4096).round());
  }

  final classes = {for (final (c, _) in lines) c}.toList();
  final layer = <int>[
    ...bytes(1, utf8.encode('transportation')),
    ...bytes(3, utf8.encode('class')),
    for (final c in classes) ...bytes(4, bytes(1, utf8.encode(c))),
    for (final (c, points) in lines)
      ...bytes(2, [
        ...packed(2, [0, classes.indexOf(c)]),
        3 << 3, 2, // type: line
        ...packed(4, () {
          final g = <int>[];
          var (cx, cy) = (0, 0);
          for (final (i, (lat, lon)) in points.indexed) {
            if (i == 0) g.add(1 | 1 << 3); // MoveTo 1
            if (i == 1) g.add(2 | (points.length - 1) << 3); // LineTo n-1
            final (ax, ay) = px(lat, lon);
            g..add(zigzag(ax - cx))..add(zigzag(ay - cy));
            (cx, cy) = (ax, ay);
          }
          return g;
        }()),
      ]),
    5 << 3, ...varint(4096), // extent
  ];
  return Uint8List.fromList(bytes(3, layer));
}

void main() {
  test('session: next past the last line shows sources, prev comes back', () {
    final s = RadioSession()..start(dialogue());
    s.next();
    expect(s.index, 1);
    s.next();
    expect(s.finished, isTrue);
    s.prev();
    expect((s.finished, s.index), (false, 1));
    s.end();
    expect(s.active, isFalse);
  });

  test('vector tile: transportation lines of the drawn classes, in lat/lon', () {
    final (x, y) = tiles.tileOf(35.62, 139.74, 14);
    final roads = tiles.parseRoadsTile(
        roadTile(14, x, y, [
          ('primary', [(35.6200, 139.7400), (35.6200, 139.7410)]),
          ('path', [(35.6200, 139.7400), (35.6205, 139.7400), (35.6205, 139.7405)]),
          ('rail', [(35.6210, 139.7400), (35.6210, 139.7410)]), // not a road
        ]),
        14,
        x,
        y);
    expect(roads.map((r) => (r.major, r.points.length)), [(true, 2), (false, 3)]);
    expect(roads.first.points.last.$1, closeTo(35.6200, 1e-5));
    expect(roads.first.points.last.$2, closeTo(139.7410, 1e-5));
    expect(tiles.tilesAround(35.62, 139.74, 600).length, inInclusiveRange(1, 4));
  });

  test('minimap: the tile under the user first, the tiles around added as they arrive', () async {
    final center = tiles.tileOf(35.62, 139.74, 14);
    final neighbour = tiles.tilesAround(35.62, 139.74, MiniMap.roadsRadiusM).firstWhere((t) => t != center);
    final late = Completer<http.Response>();
    final m = MiniMap(
      userAgent: 'test',
      client: MockClient((r) async {
        final u = r.url.toString();
        if (u == tiles.tileJsonUrl) return http.Response(jsonEncode({'tiles': ['https://t.test/{z}/{x}/{y}.pbf']}), 200);
        if (u == 'https://t.test/14/${center.$1}/${center.$2}.pbf') {
          return http.Response.bytes(roadTile(14, center.$1, center.$2, [('primary', [(35.6200, 139.7400), (35.6200, 139.7410)])]), 200);
        }
        if (u == 'https://t.test/14/${neighbour.$1}/${neighbour.$2}.pbf') return late.future;
        return http.Response.bytes([], 200);
      }),
    );
    var more = 0;
    expect(await m.maybeFetchRoads(35.62, 139.74, onMore: () => more++), isTrue);
    expect(((m.roadsJson()['roads'] as List).length, m.roadsVersion), (1, 1)); // shown before the neighbour arrives
    late.complete(http.Response.bytes(
        roadTile(14, neighbour.$1, neighbour.$2, [('path', [(35.6203, 139.7402), (35.6206, 139.7402)])]), 200));
    await pumpEventQueue();
    expect(((m.roadsJson()['roads'] as List).length, m.roadsVersion, more), (2, 2, 1));
  });

  test('minimap: after a failure, wait 10 s, 20 s, 40 s, then a minute; the tiles around too', () async {
    var clock = DateTime(2026, 10, 20, 9);
    var requests = 0;
    var down = true;
    final m = MiniMap(
      userAgent: 'test',
      now: () => clock,
      client: MockClient((r) async {
        requests++;
        final u = r.url.toString();
        if (u == tiles.tileJsonUrl) {
          return down ? http.Response('down', 503) : http.Response(jsonEncode({'tiles': ['https://t.test/{z}/{x}/{y}.pbf']}), 200);
        }
        final (x, y) = tiles.tileOf(35.62, 139.74, 14);
        if (u == 'https://t.test/14/$x/$y.pbf') {
          return http.Response.bytes(roadTile(14, x, y, [('primary', [(35.6200, 139.7400), (35.6200, 139.7410)])]), 200);
        }
        return http.Response('neighbour down', 503);
      }),
    );
    Future<int> attempt(Duration after) async {
      clock = clock.add(after);
      final before = requests;
      await m.maybeFetchRoads(35.62, 139.74);
      await pumpEventQueue();
      return requests - before;
    }

    expect(await attempt(Duration.zero), 1); // fails
    expect(await attempt(const Duration(seconds: 9)), 0);
    expect(await attempt(const Duration(seconds: 2)), 1); // 11 s: fails again
    expect(await attempt(const Duration(seconds: 15)), 0);
    expect(await attempt(const Duration(seconds: 6)), 1); // 21 s: fails a third time
    expect(await attempt(const Duration(seconds: 39)), 0);
    down = false;
    expect(await attempt(const Duration(seconds: 2)), greaterThan(1)); // 41 s: the tile under the user, then the ones around
    expect(m.roadsVersion, 1);
    // The tiles around failed: tried again after 10 s without moving.
    expect(await attempt(const Duration(seconds: 5)), 0);
    expect(await attempt(const Duration(seconds: 6)), greaterThan(0));
  });

  test('minimap: roads and heard places in metres around the user', () async {
    final (x, y) = tiles.tileOf(35.62, 139.74, 14);
    final fetched = <String>[];
    final m = MiniMap(
      userAgent: 'test',
      client: MockClient((r) async {
        final u = r.url.toString();
        fetched.add(u);
        if (u == tiles.tileJsonUrl) return http.Response(jsonEncode({'tiles': ['https://t.test/{z}/{x}/{y}.pbf']}), 200);
        if (u != 'https://t.test/14/$x/$y.pbf') return http.Response.bytes([], 200); // empty neighbours
        return http.Response.bytes(
            roadTile(14, x, y, [
              ('primary', [(35.6200, 139.7400), (35.6200, 139.7410)]),
              ('path', [(35.6200, 139.7400), (35.62001, 139.74001)]), // < 2 m: too short to draw
              ('minor', [(35.6400, 139.7600), (35.6401, 139.7601)]), // ~2.8 km away: not near
            ]),
            200);
      }),
    );
    expect(m.state(35.62, 139.74, [])['roadsVersion'], 0); // no roads yet: centred on the user
    expect(await m.maybeFetchRoads(35.62, 139.74), isTrue);
    expect(await m.maybeFetchRoads(35.6201, 139.7401), isFalse); // still near the last fetch
    final roads = m.roadsJson();
    expect(roads['version'], 1);
    final road = (roads['roads'] as List).single as List<int>; // major road, ~90 m east (tiles: ~0.6 m grid)
    expect(road[0], 1);
    for (final (i, want) in [0, 0, 90, 0].indexed) {
      expect(road[i + 1], closeTo(want, 1));
    }
    expect(fetched.where((u) => u == tiles.tileJsonUrl).length, 1);
    final s = m.state(35.6201, 139.74, [(35.6205, 139.7405), (35.70, 139.74)]); // the second is ~9 km away
    expect(s['pos'], [0, 11]);
    expect(s.containsKey('trail'), isFalse); // the walked path is not shown
    expect(s['heard'], [[45, 55]]);
  });
}
