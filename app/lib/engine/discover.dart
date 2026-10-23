/// Landmarks found by web search, kept only when the map confirms they exist nearby.
///
/// 1. Ask Claude (with web search) for interesting named places in the town.
/// 2. Look each name up on the map (Photon, else Overpass) inside a box around the town; keep it
///    only when a map feature with that exact name is there. The map supplies the coordinates,
///    never the LLM.
/// 3. Store as `web:` spots, offered alongside OSM spots.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'characters.dart';
import 'claude.dart';
import 'overpass.dart' as overpass;
import 'texts.dart';
import 'util.dart';

const boxDeg = 0.02; // ~2 km around the town's point
const maxPlaces = 10;
// Map features that are a *place* (not a shop/pub/office that happens to share the name).
const _allowedCategories = {
  'building', 'man_made', 'bridge', 'railway', 'waterway', 'historic', 'natural', 'leisure', 'place', 'boundary',
  'landuse', //
};
const _allowedTypes = {
  'amenity': {
    'place_of_worship', 'townhall', 'library', 'theatre', 'arts_centre', 'fountain', 'community_centre', 'clock',
    'public_bath', //
  },
  'tourism': {'museum', 'attraction', 'artwork', 'viewpoint', 'gallery'},
  'highway': {
    'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'footway', 'pedestrian', 'steps', 'service',
    'trunk', // named bridges / slopes / streets
  },
};
const dupDistanceM = 150.0;

String discoverUser(Json town) {
  final tags = (town['_tags'] as Map?) ?? const {};
  final city = (tags['city'] ?? '') as String;
  final country = tags['country'] as String?;
  final local = tags['local_name'] as String?;
  final abroad = country != null && country != 'jp';
  return '町: $city ${town['name']}${abroad && local != null && local != town['name'] ? '（現地名 $local）' : ''}'
      '（代表地点 ${town['lat']}, ${town['lon']} の周辺${abroad ? '、国コード ${country.toUpperCase()}' : ''}）\n'
      'この町と、そのすぐ近くで探してください。'
      '${abroad ? '\n日本国外の町です。name は現地の地図で使われている正式名称（現地の言葉）で書く。why は日本語で書く。' : ''}';
}

Json? _firstJsonObject(String text) {
  var start = text.indexOf('{');
  while (start != -1) {
    // Try the longest balanced candidate starting here.
    var depth = 0;
    var inStr = false, esc = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == r'\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') inStr = true;
      if (ch == '{') depth++;
      if (ch == '}' && --depth == 0) {
        try {
          final v = jsonDecode(text.substring(start, i + 1));
          if (v is Map<String, dynamic>) return v;
        } catch (_) {}
        break;
      }
    }
    start = text.indexOf('{', start + 1);
  }
  return null;
}

/// Claude step. Returns cleaned candidate places (names only; no coordinates trusted).
Future<List<Json>> askPlaces(Claude llm, Json town) async {
  final tools = [
    {
      'type': llm.config.webSearchTool,
      'name': 'web_search',
      'max_uses': llm.config.webMaxUses,
      'user_location': {'type': 'approximate', 'country': 'JP', 'timezone': 'Asia/Tokyo'},
    },
  ];
  final blocks = await llm.research(discoverSystem, discoverUser(town), tools, step: 'discover');
  final text = blocks.where((b) => b['type'] == 'text').map((b) => (b['text'] ?? '') as String).join();
  final data = _firstJsonObject(text) ?? const {};
  final out = <Json>[];
  final seen = <String>{};
  for (final p in ((data['places'] as List?) ?? const []).take(maxPlaces)) {
    if (p is! Map) continue;
    // Drop readings / notes in brackets: "御楯橋（みたてばし）" -> "御楯橋"
    final name = '${p['name'] ?? ''}'.replaceAll(RegExp(r'[（(][^）)]*[）)]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final theme = p['theme'];
    if (name.isEmpty || name.length > 40 || !allThemes.contains(theme) || !seen.add(name)) continue;
    if (_norm(name) == _norm(town['name'] as String?)) continue; // the town itself has its own call
    String cut(Object? v, int n) => (v ?? '').toString().length > n ? v.toString().substring(0, n) : (v ?? '').toString();
    out.add({'name': name, 'theme': theme, 'kind': cut(p['kind'], 30), 'why': cut(p['why'], 80)});
  }
  return out;
}

/// Photon (photon.komoot.io): an OSM search for apps, asked once per candidate. Its public
/// instance asks for fair use only; one request a second keeps it gentle.
const photonUrl = 'https://photon.komoot.io/api/';
final photonThrottle = Throttle();

/// Finds each candidate as a map feature near the town: Photon first; when Photon fails, the names
/// not asked yet go to Overpass in one query (busy and slow, but the same OSM data).
class PlaceFinder {
  PlaceFinder(this.client, this.userAgent, {this.url = photonUrl, Duration? minInterval})
      : _throttle = minInterval == null ? photonThrottle : Throttle(minInterval);
  final http.Client client;
  final String userAgent, url;
  final Throttle _throttle;

  /// Name -> the map feature (lat, lon, osm_type, osm_id, type) or null when the map has none.
  /// Throws only when both Photon and Overpass fail (discovery is then retried later).
  Future<Map<String, Json?>> findAll(List<String> names, double lat, double lon) async {
    final out = <String, Json?>{};
    var i = 0;
    try {
      for (; i < names.length; i++) {
        out[names[i]] = await _photon(names[i], lat, lon);
      }
    } catch (_) {
      final rest = names.sublist(i);
      final elements = await overpass.fetchNamed(client, userAgent, rest, lat, lon, boxDeg);
      for (final n in rest) {
        out[n] = pickOverpass(n, elements);
      }
    }
    return out;
  }

  Future<Json?> _photon(String name, double lat, double lon) => _throttle.run(() async {
        final r = await client.get(
            Uri.parse(url).replace(queryParameters: {
              'q': name,
              'lat': '$lat',
              'lon': '$lon',
              'limit': '10',
              'bbox': '${lon - boxDeg},${lat - boxDeg},${lon + boxDeg},${lat + boxDeg}',
              // no lang: the default is the local name (name=*), what the search was asked for
            }),
            headers: uaHeaders(userAgent)).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) throw http.ClientException('photon ${r.statusCode}');
        final features = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['features'] as List? ?? const []).cast<Json>();
        return pickPhoton(name, features);
      });
}

/// Names compared without spaces, middle dots, brackets or hyphens, and ignoring case
/// ("Hôtel de Ville" / "Hôtel-de-ville"); curly apostrophes count as straight ones.
String _norm(String? s) =>
    (s ?? '').toLowerCase().replaceAll(RegExp(r'[\s・･（）()「」\-‐–]'), '').replaceAll('’', "'");

bool _placeTag(String? key, String? value) =>
    _allowedCategories.contains(key) || (_allowedTypes[key]?.contains(value) ?? false);

// Railway points that share a station's name but are not the place (stop positions, buffer stops).
const _minorRailway = {'stop', 'buffer_stop', 'platform', 'switch', 'level_crossing', 'signal'};

/// Lower is better: what a person walking by calls by that name. Sites, bridges and parks first,
/// then buildings, streets, stations; an area before a point.
int _rank(String key, String value, bool point) {
  final tier = key == 'railway' && _minorRailway.contains(value)
      ? 5
      : const {'amenity', 'tourism', 'historic', 'man_made', 'leisure', 'natural', 'waterway', 'bridge'}.contains(key)
          ? 0
          : key == 'building'
              ? 1
              : key == 'highway'
                  ? 2
                  : key == 'railway'
                      ? 3
                      : 4;
  return tier * 2 + (point ? 1 : 0);
}

Json? _best(List<(Json, int)> ranked) {
  if (ranked.isEmpty) return null;
  var best = ranked.first;
  for (final r in ranked.skip(1)) {
    if (r.$2 < best.$2) best = r; // first one wins a tie (the service's own order)
  }
  return best.$1;
}

const _osmTypes = {'N': 'node', 'W': 'way', 'R': 'relation'};

/// The Photon feature that IS this place: exact name match, not a shop/café inside it.
Json? pickPhoton(String name, List<Json> features) => _best([
      for (final f in features)
        if ((f['properties'] as Map?) case final Map p
            when _placeTag(p['osm_key'] as String?, p['osm_value'] as String?) &&
                _norm(p['name'] as String?) == _norm(name) &&
                (f['geometry'] as Map?)?['coordinates'] is List)
          (
            {
              'lat': ((f['geometry'] as Map)['coordinates'] as List)[1],
              'lon': ((f['geometry'] as Map)['coordinates'] as List)[0],
              'osm_type': _osmTypes[p['osm_type']] ?? p['osm_type'],
              'osm_id': p['osm_id'],
              'type': p['osm_value'],
            },
            _rank(p['osm_key'] as String, p['osm_value'] as String, p['osm_type'] == 'N'),
          ),
    ]);

/// The place tag of an OSM feature found by name on Overpass, or null when it is a shop, office
/// or the like (discover's idea of a place, on the feature's full tags).
(String, String)? placeTagOf(Map tags) {
  if (tags.containsKey('shop') || tags.containsKey('office') || tags.containsKey('craft')) return null;
  for (final k in ['amenity', 'tourism']) {
    final v = tags[k];
    if (v != null && v != 'yes' && !_allowedTypes[k]!.contains(v)) return null; // tourism=yes says nothing
  }
  final hw = tags['highway'];
  if (hw is String && _allowedTypes['highway']!.contains(hw)) return ('highway', hw);
  for (final k in ['amenity', 'tourism']) {
    final v = tags[k];
    if (v is String && v != 'yes') return (k, v);
  }
  for (final k in _allowedCategories) {
    final v = tags[k];
    if (v is String) return (k, v);
  }
  return null;
}

/// The Overpass element (`out tags center`) that IS this place, by any of its name tags.
Json? pickOverpass(String name, List<Json> elements) => _best([
      for (final el in elements)
        if ((el['tags'] as Map?) case final Map tags
            when overpass.nameKeys.any((k) => _norm(tags[k] as String?) == _norm(name)))
          if (placeTagOf(tags) case (final key, final value))
            if ((el['center'] as Map?) ?? el case final Map at when at['lat'] != null)
              (
                {'lat': at['lat'], 'lon': at['lon'], 'osm_type': el['type'], 'osm_id': el['id'], 'type': value},
                _rank(key, value, el['type'] == 'node'),
              ),
    ]);

/// Same place already offered: a nearby spot whose name equals or contains this one (北品川 / 北品川駅).
bool duplicates(String name, double lat, double lon, List<Json> existing) {
  final n = _norm(name);
  for (final e in existing) {
    final en = _norm(e['name'] as String?);
    if (en.isNotEmpty &&
        (en.contains(n) || n.contains(en)) &&
        distanceM(lat, lon, (e['lat'] as num).toDouble(), (e['lon'] as num).toDouble()) <= dupDistanceM) {
      return true;
    }
  }
  return false;
}

String spotId(String name, String townId) =>
    'web:${sha1.convert(utf8.encode('$townId|$name')).toString().substring(0, 12)}';

Json toSpot(Json place, Json hit, Json town) => {
      'id': spotId(place['name'] as String, town['id'] as String),
      'name': place['name'],
      'lat': round6(double.parse('${hit['lat']}')),
      'lon': round6(double.parse('${hit['lon']}')),
      // A shopping street tells its history and its name (the many 〇〇銀座), whichever theme was picked.
      'themes': (place['name'] as String).endsWith('商店街')
          ? {place['theme'], 'history', 'placename'}.toList()
          : [place['theme']],
      'kind': (place['kind'] as String).isNotEmpty ? place['kind'] : '${hit['type'] ?? 'spot'}',
      'source': 'web',
      '_tags': {
        'addr:city': (town['_tags'] as Map?)?['city'] ?? '',
        'addr:town': town['name'],
        'osm': 'osm:${hit['osm_type']}:${hit['osm_id']}',
        'why': place['why'],
      },
    };

/// Full discovery for one town. `existing` = spots already offered (OSM), to skip duplicates.
Future<List<Json>> discover(Claude llm, Json town, PlaceFinder finder, List<Json> existing) async {
  final places = await askPlaces(llm, town);
  final knownIds = {for (final e in existing) e['id']};
  final spots = <Json>[];
  final tlat = (town['lat'] as num).toDouble(), tlon = (town['lon'] as num).toDouble();
  final hits = await finder.findAll([for (final p in places) p['name'] as String], tlat, tlon);
  for (final p in places) {
    final hit = hits[p['name']];
    if (hit == null || knownIds.contains('osm:${hit['osm_type']}:${hit['osm_id']}')) continue;
    final lat = double.parse('${hit['lat']}'), lon = double.parse('${hit['lon']}');
    if (duplicates(p['name'] as String, lat, lon, [...existing, ...spots])) continue;
    spots.add(toSpot(p, hit, town));
  }
  return spots;
}
