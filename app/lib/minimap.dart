import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'engine/vector_tiles.dart' as tiles;

/// Data for the Even G2 minimap (a radar-style map drawn by the glasses app).
///
/// Everything is sent as whole metres east (x) / north (y) of [origin], so the glasses only
/// translate and scale. Shows roads and places where a call was heard —
/// never spots the user hasn't heard yet (the app doesn't steer the walk).
class MiniMap {
  MiniMap({http.Client? client, required String userAgent, DateTime Function()? now})
      : _tiles = tiles.RoadTiles(client ?? http.Client(), userAgent),
        _now = now ?? DateTime.now;

  /// Roads come from OpenFreeMap's vector tiles (see vector_tiles.dart).
  final tiles.RoadTiles _tiles;
  final DateTime Function() _now;

  static const roadsRadiusM = 600;
  static const refetchAfterM = 300.0; // fetch new roads when this far from the last fetch
  static const viewRadiusM = 400.0; // heard places sent around the user

  /// Waits after failed fetches in a row: 10 s, 20 s, 40 s, then every minute.
  static const retryAfter = [Duration(seconds: 10), Duration(seconds: 20), Duration(seconds: 40), Duration(minutes: 1)];

  (double, double)? origin; // where roads were fetched (lat, lon)
  final _byTile = <(int, int), List<tiles.Road>>{}; // roads near [origin], per tile
  var _missing = <(int, int)>{}; // tiles around [origin] not fetched yet
  int roadsVersion = 0;
  int _generation = 0; // bumped with every new [origin]: late tiles for an old one are dropped
  bool _fetching = false, _filling = false;
  int _failures = 0;
  DateTime? _failedAt;

  Iterable<tiles.Road> get _roads => _byTile.values.expand((r) => r);

  static (int, int) toXY((double, double) origin, double lat, double lon) {
    final (olat, olon) = origin;
    final x = (lon - olon) * 111320 * math.cos(olat * math.pi / 180);
    final y = (lat - olat) * 110540;
    return (x.round(), y.round());
  }

  static double _dist((double, double) a, (double, double) b) {
    final (x, y) = toXY(a, b.$1, b.$2);
    return math.sqrt(x * x + y * y);
  }

  bool get _waiting {
    final failed = _failedAt;
    return failed != null && _now().difference(failed) < retryAfter[math.min(_failures, retryAfter.length) - 1];
  }

  void _failed() {
    _failures++;
    _failedAt = _now(); // the map still works without roads (position + heard places)
  }

  /// Fetch roads around the user when needed (first time, after walking away, or to finish the
  /// tiles around that failed). The tile under the user comes first, so the map shows roads as soon
  /// as it arrives; the tiles around it are fetched together afterwards and each one calls [onMore]
  /// when it adds roads. Returns true when the first roads of a new place arrived.
  Future<bool> maybeFetchRoads(double lat, double lon, {void Function()? onMore}) async {
    if (_fetching) return false;
    final o = origin;
    final moved = o == null || _dist(o, (lat, lon)) >= refetchAfterM;
    if (!moved && _missing.isEmpty) return false;
    if (_waiting) return false;
    if (!moved) {
      unawaited(_fill(onMore));
      return false;
    }
    _fetching = true;
    try {
      final center = tiles.tileOf(lat, lon, tiles.roadsZoom);
      final roads = await _tiles.tile(center);
      _generation++;
      origin = (lat, lon);
      _byTile
        ..clear()
        ..[center] = tiles.roadsNear(roads, lat, lon, roadsRadiusM);
      _missing = {...tiles.tilesAround(lat, lon, roadsRadiusM)}..remove(center);
      roadsVersion++;
      _failures = 0;
      _failedAt = null;
      unawaited(_fill(onMore));
      return true;
    } catch (_) {
      _failed();
      return false;
    } finally {
      _fetching = false;
    }
  }

  /// The tiles around [origin] still missing, fetched together.
  Future<void> _fill(void Function()? onMore) async {
    final o = origin;
    if (_filling || o == null || _missing.isEmpty) return;
    _filling = true;
    final generation = _generation;
    var failed = false;
    try {
      await Future.wait([
        for (final t in _missing.toList())
          _tiles.tile(t).then((roads) {
            if (generation != _generation) return;
            _missing.remove(t);
            final near = tiles.roadsNear(roads, o.$1, o.$2, roadsRadiusM);
            if (near.isEmpty) return;
            _byTile[t] = near;
            roadsVersion++;
            onMore?.call();
          }, onError: (Object _) {
            failed = true;
          }),
      ]);
      if (generation != _generation) return;
      if (failed) {
        _failed();
      } else {
        _failures = 0;
        _failedAt = null;
      }
    } finally {
      _filling = false;
    }
  }

  /// Small per-update state: position and heard places (sent with every state change).
  Map<String, dynamic> state(double lat, double lon, Iterable<(double, double)> heard) {
    final o = origin ?? (lat, lon);
    final pos = toXY(o, lat, lon);
    bool near((int, int) p) => (p.$1 - pos.$1).abs() <= viewRadiusM && (p.$2 - pos.$2).abs() <= viewRadiusM;
    return {
      'origin': [o.$1, o.$2],
      'roadsVersion': origin == null ? 0 : roadsVersion,
      'pos': [pos.$1, pos.$2],
      'heard': [
        for (final h in heard)
          if (toXY(o, h.$1, h.$2) case final p when near(p)) [p.$1, p.$2],
      ],
    };
  }

  /// Roads, fetched by the glasses only when [roadsVersion] changes:
  /// `[major(0/1), x1, y1, x2, y2, ...]` per road, points closer than 2 m dropped.
  Map<String, dynamic> roadsJson() {
    final o = origin;
    if (o == null) return {'version': 0, 'roads': []};
    final roads = <List<int>>[];
    for (final r in _roads) {
      final flat = <int>[r.major ? 1 : 0];
      (int, int)? last;
      for (final (lat, lon) in r.points) {
        final p = toXY(o, lat, lon);
        if (last != null && (p.$1 - last.$1).abs() < 2 && (p.$2 - last.$2).abs() < 2) continue;
        flat..add(p.$1)..add(p.$2);
        last = p;
      }
      if (flat.length >= 5) roads.add(flat);
    }
    return {'version': roadsVersion, 'origin': [o.$1, o.$2], 'roads': roads};
  }
}
