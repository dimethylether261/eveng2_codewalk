/// Nearby spots from OpenStreetMap (Overpass API) and tag -> theme mapping.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'characters.dart';
import 'util.dart';

const overpassUrl = 'https://overpass-api.de/api/interpreter';
/// Tried when the main instance is busy or down. (overpass.kumi.systems answered with the same
/// servers and error pages as private.coffee in 2026-10, so it is not a separate fallback. The
/// maps.mail.ru instance is left out of the store build: users' locations would go to one more
/// operator abroad.)
const mirrors = [
  'https://overpass.private.coffee/api/interpreter',
];

/// A busy public instance can take 40-50 s to answer a spot query (measured 2026-10-16); giving up
/// at 30 s threw those answers away. Each instance gets [perServer], all of them [total].
const perServer = Duration(seconds: 75);
const total = Duration(seconds: 150);

final _slopeName = RegExp(r'坂$');
final _shotengaiName = RegExp(r'商店街$');
// Bridge names in the languages of country.dart's table ("Waterloo Bridge", "Pont Neuf", "Oberbaumbrücke"...).
final _bridgeName = RegExp(
    r'(橋|ばし|はし|ブリッジ)$|\bbridge\b|brücke|\bpont\b|\bponte\b|\bpuente\b|\bbrug\b|\bbro\b|bron$|\bmost\b|'
    r'мост|köprü|híd|^cầu\b|다리|대교|大桥|สะพาน',
    caseSensitive: false);
final _siteName = RegExp(r'(跡|跡地|遺構|台場|本陣|一里塚|発祥)');
const _lowInfoKinds = {'memorial', 'wayside_shrine', 'wayside_cross', 'yes', 'plaque', 'board', 'boundary_stone'};
const _lowInfoMemorials = {'plaque', 'board', 'stone', 'blue_plaque'};

/// [japan]: also look for named slopes (「〜坂」), which only exist in Japanese.
String buildQuery(double lat, double lon, int radius, {bool japan = true}) {
  final a = 'around:$radius,${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
  final selectors = [
    '["historic"]',
    '["amenity"="place_of_worship"]',
    '["heritage"]',
    '["memorial"]',
    r'["tourism"~"^(museum|attraction|artwork)$"]',
    '["man_made"="bridge"]',
    r'["bridge"]["highway"~"^(footway|pedestrian|cycleway)$"]',
    '["bridge"]["highway"]',
    r'["man_made"~"^(bridge|tower|water_tower|lighthouse)$"]',
    '["railway"="station"]',
    '["building"]["architect"]',
    '["building"]["wikidata"]',
    if (japan) r'["highway"]["name"~"坂$"]',
    // 商店街: mapped as a named street (often pedestrian) or a retail area, rarely with an article.
    if (japan) r'["highway"]["name"~"商店街$"]',
    if (japan) r'["landuse"="retail"]["name"~"商店街"]',
    '["highway"]["wikidata"]', // streets with their own entry (the Fox and the Owl tell them)
    r'["waterway"~"^(river|canal)$"]["wikipedia"]',
    r'["man_made"~"^(pumping_station|water_works|reservoir_covered)$"]',
    r'["natural"~"^(peak|spring|tree|cliff|water|wetland)$"]',
    r'["leisure"~"^(park|garden)$"]["wikidata"]',
    r'["amenity"~"^(cinema|theatre|music_venue|marketplace)$"]',
    r'["craft"~"^(brewery|winery|distillery)$"]',
    '["man_made"="communications_tower"]',
    '["wikipedia"]',
  ];
  // Select named features around the point once, then filter that set (much lighter
  // for the Overpass server than one around-query per selector).
  final body = selectors.map((s) => 'nwr.n$s;').join();
  return '[out:json][timeout:60];nwr($a)["name"]->.n;($body);out center tags;';
}

/// (themes, kind) for an OSM element's tags. Empty themes = not a spot.
(List<String>, String) classify(Map<String, String> tags) {
  final themes = <String>[];
  var kind = 'spot';
  void add(String t) {
    if (!themes.contains(t)) themes.add(t);
  }

  bool has(String k) => (tags[k] ?? '').isNotEmpty;
  final name = tags['name'] ?? '';

  if (tags['amenity'] == 'place_of_worship') {
    kind = const {'shinto': 'shrine', 'buddhist': 'temple', 'christian': 'church'}[tags['religion'] ?? ''] ??
        'place_of_worship';
    add('history');
  }
  if (tags.containsKey('historic')) {
    if (kind == 'spot') kind = tags['historic']!;
    add('history');
  }
  if (tags.containsKey('heritage') || tags.containsKey('memorial')) add('history');
  if (tags['tourism'] == 'museum') {
    kind = 'museum';
    add('history');
  }
  // Road segments on a bridge carry the road's name ("第一京浜"); only real bridge names count.
  if (has('bridge') && has('highway') && _bridgeName.hasMatch(name)) {
    kind = 'bridge';
    add('architecture');
    add('placename');
  }
  final manMade = tags['man_made'];
  if (const {'bridge', 'tower', 'lighthouse'}.contains(manMade)) {
    kind = manMade!;
    add('architecture');
    if (manMade == 'bridge' && _bridgeName.hasMatch(name)) add('placename');
    if (manMade == 'tower' && tags['tower:type'] == 'communication') add('tech');
  }
  if (manMade == 'communications_tower') {
    kind = 'communications_tower';
    add('architecture');
    add('tech');
  }
  if (manMade == 'water_tower') {
    kind = 'water_tower';
    add('architecture');
    add('tech');
  }
  if (tags['railway'] == 'station') {
    kind = 'station';
    add('architecture'); // stations are the Sphinx's (architecture & engineering)
  }
  if (has('building') && (has('architect') || has('heritage'))) add('architecture');
  // A shopping street (商店街): how it grew, and its name (the many 〇〇銀座).
  if ((has('highway') || tags['landuse'] == 'retail') && _shotengaiName.hasMatch(name)) {
    kind = 'shotengai';
    add('history');
    add('placename');
  }
  if (has('highway') && _slopeName.hasMatch(name)) {
    kind = 'slope';
    add('nature');
    add('placename');
  }
  final hasWiki = has('wikipedia') || has('wikidata');
  // Streets and squares with their own entry: where the name comes from, and their past.
  if (kind == 'spot' && hasWiki && (has('highway') || tags['place'] == 'square') && !has('bridge')) {
    kind = tags['place'] == 'square' ? 'square' : 'street';
    add('placename');
    add('history');
  }
  // Named buildings that have their own Wikipedia/Wikidata entry (modern landmarks, offices, halls).
  if (has('building') && hasWiki && tags['amenity'] != 'place_of_worship') {
    if (kind == 'spot') kind = 'building';
    add('architecture');
  }
  if (tags['waterway'] == 'river' || tags['waterway'] == 'canal') {
    kind = tags['waterway']!;
    add(tags['waterway'] == 'river' ? 'nature' : 'architecture'); // a canal is civil engineering
    if (tags['waterway'] == 'canal') add('history');
  }
  if (const {'pumping_station', 'water_works', 'reservoir_covered'}.contains(manMade)) {
    kind = manMade!;
    add('tech');
    add('architecture');
  }
  // Public art with a known artist (or its own entry) is a small architecture/art story.
  if (tags['tourism'] == 'artwork' && (has('artist_name') || hasWiki)) {
    if (kind == 'spot') kind = 'artwork';
    add('architecture');
  }
  final natural = tags['natural'];
  if (const {'peak', 'spring', 'tree', 'cliff', 'water', 'wetland'}.contains(natural)) {
    if (kind == 'spot') kind = natural!;
    add('nature');
  }
  if ((tags['leisure'] == 'park' || tags['leisure'] == 'garden') && hasWiki) {
    if (kind == 'spot') kind = tags['leisure']!;
    add('nature');
  }
  final amenity = tags['amenity'];
  if (amenity == 'cinema' || amenity == 'theatre' || amenity == 'music_venue') {
    kind = amenity!;
    add('film');
  }
  if (amenity == 'marketplace') {
    kind = 'marketplace';
    add('food');
  }
  if (const {'brewery', 'winery', 'distillery'}.contains(tags['craft'])) {
    kind = tags['craft']!;
    add('food');
  }
  if (tags['tourism'] == 'attraction' && themes.isEmpty && has('wikipedia')) add('history');
  // Small markers (plaques, boards, little roadside shrines) rarely have enough written about
  // them to make a dialogue; keep them only when they have their own encyclopedia entry.
  // Sites of former buildings/events ("〜跡", 台場, 本陣...) usually have a story even without an article.
  if (!hasWiki &&
      (_lowInfoKinds.contains(kind) || _lowInfoMemorials.contains(tags['memorial'])) &&
      !_siteName.hasMatch(name)) {
    return (<String>[], kind);
  }
  return (themes, kind);
}

List<Json> parseElements(Json data) {
  final spots = <Json>[];
  final seenNames = <String>{};
  for (final el in (data['elements'] as List? ?? const [])) {
    final e = el as Json;
    final tags = <String, String>{
      for (final t in ((e['tags'] as Map?) ?? const {}).entries) t.key as String: '${t.value}',
    };
    if ((tags['bridge:name'] ?? '').isNotEmpty) tags['name'] = tags['bridge:name']!;
    final name = tags['name'];
    if (name == null || name.isEmpty) continue;
    final center = e['center'] as Map?;
    final lat = (e['lat'] ?? center?['lat']) as num?;
    final lon = (e['lon'] ?? center?['lon']) as num?;
    if (lat == null || lon == null) continue;
    final (themes, kind) = classify(tags);
    if (themes.isEmpty) continue;
    // Long features (bridges, roads) come as several ways with the same name.
    if (!seenNames.add(name)) continue;
    final spot = <String, dynamic>{
      'id': 'osm:${e['type']}:${e['id']}',
      'name': name,
      'lat': round6(lat),
      'lon': round6(lon),
      'themes': themes,
      'kind': kind,
    };
    for (final k in ['wikipedia', 'wikidata']) {
      if ((tags[k] ?? '').isNotEmpty) spot[k] = tags[k];
    }
    if ((tags['name:en'] ?? '').isNotEmpty) spot['name_en'] = tags['name:en'];
    spot['_tags'] = {
      for (final t in tags.entries)
        if (!t.key.startsWith('source') && !t.key.startsWith('note') && !t.key.startsWith('fixme')) t.key: t.value,
    };
    spots.add(spot);
  }
  return spots;
}

/// POST an Overpass query, falling back to a mirror when the main instance is busy (429/5xx/timeout).
Future<Json> _query(http.Client client, String userAgent, String query, {String url = overpassUrl}) async {
  Object? last;
  final deadline = DateTime.now().add(total);
  for (final endpoint in [url, ...mirrors.where((m) => m != url)]) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) break;
    try {
      final r = await client
          .post(Uri.parse(endpoint), body: {'data': query}, headers: uaHeaders(userAgent))
          .timeout(left < perServer ? left : perServer);
      if (r.statusCode != 200) throw http.ClientException('overpass ${r.statusCode}');
      return jsonDecode(utf8.decode(r.bodyBytes)) as Json;
    } catch (e) {
      last = e;
    }
  }
  throw last!;
}

Future<List<Json>> fetchSpots(http.Client client, String userAgent, double lat, double lon, int radius,
        {bool japan = true}) async =>
    parseElements(await _query(client, userAgent, buildQuery(lat, lon, radius, japan: japan)));

// --- Towns (町の雑学) ---------------------------------------------------------
// Japanese OSM admin levels: 7 = 市区町村, 9 = 町・大字 (e.g. 北品川), 10 = 丁目 (北品川一丁目).
final _chome = RegExp(r'[一二三四五六七八九十〇0-9０-９]+丁目$');

String buildAreaQuery(double lat, double lon) =>
    '[out:json][timeout:60];is_in(${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)})->.a;'
    '(area.a[boundary=administrative][name];area.a[place~"^(borough|city_district|suburb|quarter|neighbourhood)\$"][name];);'
    'out tags;';

/// Roughly Japan (its islands and some sea): where the Japanese town rules apply when the country is unknown.
bool inJapanBox(double lat, double lon) => lat >= 20 && lat <= 46 && lon >= 122 && lon <= 154;

/// The town containing the point. Japan: admin_level 9 (町・大字), else 10 with 丁目 stripped.
/// Elsewhere ([country] not 'jp'): see [parseAreaAbroad].
Json? parseArea(Json data, double lat, double lon, {String? country}) {
  if (country != null ? country != 'jp' : !inJapanBox(lat, lon)) return parseAreaAbroad(data, lat, lon, country: country);
  final levels = <int, Json>{};
  for (final el in (data['elements'] as List? ?? const [])) {
    final e = el as Json;
    final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final lvl = int.tryParse('${tags['admin_level'] ?? ''}');
    if (lvl == null) continue;
    levels[lvl] = {'id': e['id'], 'tags': tags};
  }
  final town = levels[9] ?? levels[10];
  if (town == null) return null;
  final tags = town['tags'] as Map<String, dynamic>;
  var name = tags['name'] as String;
  if (!levels.containsKey(9)) {
    final stripped = name.replaceAll(_chome, '');
    if (stripped.isNotEmpty) name = stripped;
  }
  final city = ((levels[7]?['tags'] as Map?)?['name'] ?? '') as String;
  final nameEn = (tags['name:en'] ?? '') as String;
  final spot = <String, dynamic>{
    'id': 'area:${town['id']}',
    'name': name,
    'lat': round6(lat),
    'lon': round6(lon),
    'themes': List<String>.of(allThemes),
    'kind': 'area',
    if (nameEn.isNotEmpty) 'name_en': nameEn.replaceAll(RegExp(r'\s*\d+-chome$'), ''),
    '_tags': {'city': city},
  };
  if (levels.containsKey(9)) {
    for (final k in ['wikipedia', 'wikidata']) {
      if ((tags[k] ?? '') != '') spot[k] = tags[k];
    }
  }
  return spot;
}

// Abroad, admin level numbers mean different things in every country (a London ward is 10, a US
// city 8, a French commune 8): instead of a level, take the smallest area that has an article to
// research. Mapped districts (suburb, quarter, neighbourhood) count too, ranked below wards.
const _placeRank = {'borough': 9, 'city_district': 9, 'suburb': 10, 'quarter': 11, 'neighbourhood': 12};
const _minAbroadRank = 5; // below states and regions (2 country, 3-4 state / region)

/// The smallest area around the point with a Wikipedia article or a Wikidata item, or null.
/// The name is Japanese or English when the map has it (the glasses may not show other scripts).
Json? parseAreaAbroad(Json data, double lat, double lon, {String? country}) {
  final areas = <({int rank, Json id, Map<String, dynamic> tags})>[];
  for (final el in (data['elements'] as List? ?? const [])) {
    final e = el as Json;
    final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rank = tags['boundary'] == 'administrative'
        ? int.tryParse('${tags['admin_level'] ?? ''}')
        : _placeRank[tags['place']];
    if (rank == null || rank < _minAbroadRank) continue;
    areas.add((rank: rank, id: {'id': e['id']}, tags: tags));
  }
  areas.sort((a, b) => b.rank.compareTo(a.rank)); // smallest first
  final i = areas.indexWhere((a) => (a.tags['wikipedia'] ?? '') != '' || (a.tags['wikidata'] ?? '') != '');
  if (i < 0) return null;
  final town = areas[i];
  final tags = town.tags;
  String? pick(Map<String, dynamic> t, String key) => (t[key] ?? '') == '' ? null : t[key] as String;
  final local = tags['name'] as String;
  final en = pick(tags, 'name:en') ?? (RegExp(r'^[\u0020-\u024F]+$').hasMatch(local) ? local : null);
  bool known(Map<String, dynamic> t) => (t['wikipedia'] ?? '') != '' || (t['wikidata'] ?? '') != '';
  // The city around it: the next larger area, preferring one with an article (a well-known name).
  final bigger = areas.skip(i + 1).where((a) => a.rank < town.rank);
  final larger = bigger.where((a) => known(a.tags)).firstOrNull ?? bigger.firstOrNull;
  final cityTags = larger?.tags ?? const <String, dynamic>{};
  return {
    'id': 'area:${town.id['id']}',
    'name': pick(tags, 'name:ja') ?? en ?? local,
    'lat': round6(lat),
    'lon': round6(lon),
    'themes': List<String>.of(allThemes),
    'kind': 'area',
    'name_en': ?en,
    'wikipedia': ?pick(tags, 'wikipedia'),
    'wikidata': ?pick(tags, 'wikidata'),
    '_tags': {
      'city': pick(cityTags, 'name:ja') ?? pick(cityTags, 'name:en') ?? pick(cityTags, 'name') ?? '',
      'local_name': local,
      'country': ?country,
    },
  };
}

// --- Places by name (discover.dart, when Photon is down) ----------------------------

/// The name tags a place may be known by.
const nameKeys = ['name', 'name:ja', 'name:en', 'alt_name', 'official_name', 'old_name', 'short_name'];

/// A regex literal inside an Overpass QL string: regex metacharacters, then the QL string escapes.
String _qlRegex(String s) =>
    s.replaceAllMapped(RegExp(r'[\\^$.|?*+()\[\]{}]'), (m) => '\\${m[0]}').replaceAll('\\', '\\\\').replaceAll('"', '\\"');

/// Every feature in the box (±[box] degrees) named one of [names]: as written, and without spaces
/// or middle dots (OSM names vary on those), in any case. One query for a whole town.
String buildNamesQuery(List<String> names, double lat, double lon, double box) {
  final variants = {
    for (final n in names) ...[n, n.replaceAll(RegExp(r'[\s・･]'), ''), n.replaceAll('・', '')],
  }.where((v) => v.isNotEmpty).toList()
    ..sort();
  final bbox = [lat - box, lon - box, lat + box, lon + box].map((v) => v.toStringAsFixed(6)).join(',');
  return '[out:json][timeout:90];nwr[~"^(${nameKeys.map(_qlRegex).join('|')})\$"~"^(${variants.map(_qlRegex).join('|')})\$",i]'
      '($bbox);out tags center;';
}

Future<List<Json>> fetchNamed(http.Client client, String userAgent, List<String> names, double lat, double lon,
        double box) async =>
    names.isEmpty
        ? const []
        : ((await _query(client, userAgent, buildNamesQuery(names, lat, lon, box)))['elements'] as List? ?? const [])
            .cast<Json>();

Future<Json?> fetchArea(http.Client client, String userAgent, double lat, double lon, {String? country}) async =>
    parseArea(await _query(client, userAgent, buildAreaQuery(lat, lon)), lat, lon, country: country);
