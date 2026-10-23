/// Roads for the glasses minimap from OpenFreeMap's vector tiles (OpenMapTiles schema, zoom 14).
///
/// OpenFreeMap serves the whole planet from a CDN, free, without keys or request limits (attribution:
/// © OpenMapTiles © OpenStreetMap contributors). The tile URL carries the weekly build, so it is read
/// from the TileJSON first. Only the `transportation` layer is read; tiles are kept per session, so
/// walking back and forth does not fetch them again.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'util.dart';

const tileJsonUrl = 'https://tiles.openfreemap.org/planet';
const roadsZoom = 14; // the zoom with every footpath and alley

/// A road as a polyline: (major road?, points as (lat, lon)).
typedef Road = ({bool major, List<(double, double)> points});

// OpenMapTiles `transportation` classes drawn on the minimap (rail, ferry, aerialway... are not).
const _majorClasses = {'motorway', 'trunk', 'primary', 'secondary', 'tertiary'};
const _minorClasses = {'minor', 'service', 'path', 'track'};

/// The tile at [z] holding the point.
(int, int) tileOf(double lat, double lon, int z) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n).floor();
  return (x.clamp(0, n - 1), y.clamp(0, n - 1));
}

/// The tiles covering the square of ±[radiusM] around the point (1 to 4 at zoom 14).
List<(int, int)> tilesAround(double lat, double lon, int radiusM, {int z = roadsZoom}) {
  final dLat = radiusM / 110540, dLon = radiusM / (111320 * math.cos(lat * math.pi / 180));
  final (x0, y0) = tileOf(lat + dLat, lon - dLon, z); // north-west corner: smallest x and y
  final (x1, y1) = tileOf(lat - dLat, lon + dLon, z);
  return [
    for (var x = x0; x <= x1; x++)
      for (var y = y0; y <= y1; y++) (x, y),
  ];
}

// --- Mapbox Vector Tile (protobuf) reading ----------------------------------------------------
// Plain arithmetic instead of bit shifts: the glasses app runs this as JavaScript, where shifts
// are 32-bit.

class _Reader {
  _Reader(this.b, [this.i = 0, int? end]) : end = end ?? b.length;
  final Uint8List b;
  int i;
  final int end;

  bool get more => i < end;

  int varint() {
    var v = 0, mult = 1;
    while (true) {
      final x = b[i++];
      v += (x & 0x7F) * mult;
      if (x < 0x80) return v;
      mult *= 128;
    }
  }

  /// (field number, wire type)
  (int, int) key() {
    final k = varint();
    return (k ~/ 8, k % 8);
  }

  _Reader sub() {
    final n = varint();
    final r = _Reader(b, i, i + n);
    i += n;
    return r;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        i += 8;
      case 2:
        i += varint();
      case 5:
        i += 4;
      default:
        throw const FormatException('vector tile: unknown wire type');
    }
  }

  List<int> packed() {
    final r = sub(), out = <int>[];
    while (r.more) {
      out.add(r.varint());
    }
    return out;
  }
}

int _zigzag(int n) => n % 2 == 0 ? n ~/ 2 : -(n + 1) ~/ 2;

/// The roads in one tile (`transportation` line features of the drawn classes).
List<Road> parseRoadsTile(Uint8List bytes, int z, int x, int y) {
  final tile = _Reader(bytes);
  final roads = <Road>[];
  while (tile.more) {
    final (field, wire) = tile.key();
    if (field != 3 || wire != 2) {
      tile.skip(wire);
      continue;
    }
    final layer = tile.sub();
    String? name;
    var extent = 4096;
    final keys = <String>[], values = <String?>[], features = <_Reader>[];
    while (layer.more) {
      final (f, w) = layer.key();
      switch ((f, w)) {
        case (1, 2):
          final s = layer.sub();
          name = utf8.decode(s.b.sublist(s.i, s.end));
        case (2, 2):
          features.add(layer.sub());
        case (3, 2):
          final s = layer.sub();
          keys.add(utf8.decode(s.b.sublist(s.i, s.end)));
        case (4, 2):
          final v = layer.sub();
          String? str;
          while (v.more) {
            final (vf, vw) = v.key();
            if (vf == 1 && vw == 2) {
              final s = v.sub();
              str = utf8.decode(s.b.sublist(s.i, s.end));
            } else {
              v.skip(vw);
            }
          }
          values.add(str);
        case (5, 0):
          extent = layer.varint();
        default:
          layer.skip(w);
      }
    }
    if (name != 'transportation') continue;
    for (final feature in features) {
      var type = 0;
      List<int> tags = const [], geometry = const [];
      while (feature.more) {
        final (f, w) = feature.key();
        switch ((f, w)) {
          case (2, 2):
            tags = feature.packed();
          case (3, 0):
            type = feature.varint();
          case (4, 2):
            geometry = feature.packed();
          default:
            feature.skip(w);
        }
      }
      if (type != 2) continue; // lines only (no pedestrian areas)
      String? cls;
      for (var t = 0; t + 1 < tags.length; t += 2) {
        if (keys[tags[t]] == 'class') cls = values[tags[t + 1]];
      }
      final major = _majorClasses.contains(cls);
      if (!major && !_minorClasses.contains(cls)) continue;
      for (final line in _lines(geometry)) {
        if (line.length < 2) continue;
        roads.add((major: major, points: [for (final (px, py) in line) _latLon(z, x, y, extent, px, py)]));
      }
    }
  }
  return roads;
}

/// MoveTo / LineTo commands -> polylines in tile pixels.
List<List<(int, int)>> _lines(List<int> g) {
  final lines = <List<(int, int)>>[];
  var px = 0, py = 0, i = 0;
  while (i < g.length) {
    final cmd = g[i] % 8, count = g[i] ~/ 8;
    i++;
    if (cmd == 7) continue; // ClosePath: no parameters
    for (var k = 0; k < count && i + 1 < g.length; k++) {
      px += _zigzag(g[i]);
      py += _zigzag(g[i + 1]);
      i += 2;
      if (cmd == 1) lines.add([]);
      if (lines.isNotEmpty) lines.last.add((px, py));
    }
  }
  return lines;
}

(double, double) _latLon(int z, int x, int y, int extent, int px, int py) {
  final n = math.pow(2, z).toDouble();
  final lon = (x + px / extent) / n * 360 - 180;
  final t = math.pi * (1 - 2 * (y + py / extent) / n);
  final lat = math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi;
  return (lat, lon);
}

// --- fetching ------------------------------------------------------------------------------

/// The roads that come within ±[radiusM] of the point (whole polylines, so a road leaving the
/// square is not cut off at its edge).
List<Road> roadsNear(List<Road> roads, double lat, double lon, int radiusM) {
  final dLat = radiusM / 110540, dLon = radiusM / (111320 * math.cos(lat * math.pi / 180));
  bool near((double, double) p) => (p.$1 - lat).abs() <= dLat && (p.$2 - lon).abs() <= dLon;
  return [
    for (final r in roads)
      if (r.points.any(near)) r,
  ];
}

/// Road tiles from OpenFreeMap, kept for the session.
class RoadTiles {
  RoadTiles(this.client, this.userAgent, {this.tileJson = tileJsonUrl});
  final http.Client client;
  final String userAgent, tileJson;

  String? _template; // e.g. https://tiles.openfreemap.org/planet/<build>/{z}/{x}/{y}.pbf
  final _tiles = <(int, int), List<Road>>{};
  static const _keepTiles = 16;

  /// All roads in the tile (x, y) at [roadsZoom]. Throws when it can't be fetched.
  Future<List<Road>> tile((int, int) t) async {
    final kept = _tiles[t];
    if (kept != null) return kept;
    var r = await _get(t, await _url());
    if (r.statusCode == 404) {
      _template = null; // a new weekly build replaced ours
      r = await _get(t, await _url());
    }
    if (r.statusCode != 200) throw http.ClientException('tile ${r.statusCode}');
    final roads = r.bodyBytes.isEmpty ? <Road>[] : parseRoadsTile(r.bodyBytes, roadsZoom, t.$1, t.$2);
    if (_tiles.length >= _keepTiles) _tiles.remove(_tiles.keys.first);
    _tiles[t] = roads;
    return roads;
  }

  Future<http.Response> _get((int, int) t, String template) => client
      .get(Uri.parse(template.replaceAll('{z}', '$roadsZoom').replaceAll('{x}', '${t.$1}').replaceAll('{y}', '${t.$2}')),
          headers: uaHeaders(userAgent))
      .timeout(const Duration(seconds: 30));

  Future<String> _url() async {
    final known = _template;
    if (known != null) return known;
    final r = await client.get(Uri.parse(tileJson), headers: uaHeaders(userAgent)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw http.ClientException('tilejson ${r.statusCode}');
    final tiles = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['tiles'];
    if (tiles is! List || tiles.isEmpty) throw const FormatException('tilejson: no tiles');
    return _template = tiles.first as String;
  }
}
