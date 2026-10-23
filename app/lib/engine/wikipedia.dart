/// Nearby spots from Wikipedia's geosearch, typed with Wikidata (instance of, P31).
/// Japanese Wikipedia everywhere; abroad also the local edition (country.dart), for the places
/// Japanese Wikipedia doesn't know.
///
/// Every spot found here has its own Wikipedia article, so the research step usually finds
/// enough sourced facts. Companies (geotagged at their head office) and schools are kept as
/// small stories, limited to well-known ones; products, software and people are dropped.
/// Classification uses the English labels of Wikidata classes.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'util.dart';

const wpApi = 'https://ja.wikipedia.org/w/api.php';
String wpApiFor(String lang) => lang == 'ja' ? wpApi : 'https://$lang.wikipedia.org/w/api.php';
const wdApi = 'https://www.wikidata.org/w/api.php';

RegExp _i(String p) => RegExp(p, caseSensitive: false);

// Not a place at all: products, services, people.
final _notAPlace = _i(r'payment|card\b|brand|software|website|band\b|human|video game\b|product|service\b');
final _organization = _i(r'business|company|corporation|enterprise|organi[sz]ation|association|holding|conglomerate|publisher|'
    r'developer|chain|airline|manufacturer|kabushiki|radio station|television station|broadcaster|'
    r'governing body|agency|sports team|club|political|government|foundation|institute');
final _school = _i(r'school|university|college|academy|educational');
// Organizations that make or sell things (else: public bodies, clubs, institutes -> history).
final _business = _i(r'business|company|corporation|enterprise|holding|conglomerate|publisher|developer|chain|airline|'
    r'manufacturer|kabushiki|radio station|television station|broadcaster');
const minSitelinks = 3; // "well known": articles in at least this many Wikipedia language editions
const oldSchoolYears = 50; // or a school founded at least this long ago
// The "暮らし・インフラ" theme was retired (2026-10-14): stations, bridges and the like go to the
// Sphinx (architecture & engineering), streets and squares to the Fox and the Owl, utilities to the Seal.
final _themeRules = <(String, RegExp)>[
  ('architecture', _i(r'skyscraper|tower|building|complex|hotel|theat|hall|house|residence|'
      r'structure|architect|art museum|stadium|studio|ship|'
      r'station|termin|depot|canal|bridge|tunnel|port\b|harbo|pier|dam\b|airport|waterfront|artificial island|rail')),
  ('placename', _i(r'\broad\b|street|avenue|\blane\b|square|plaza|sh[oō]tengai|commercial district|shopping district|shopping arcade')),
  ('history', _i(r'shrine|temple|church|cultural heritage|cultural property|historic|ruin|site|'
      r'monument|memorial|tomb|cemetery|castle|battery|fort|museum|heritage|square|plaza|street|canal|'
      r'sh[oō]tengai|commercial district|shopping district|shopping arcade')),
  ('nature', _i(r'park|garden|river|mountain|hill\b|spring|lake|pond|forest|tree|natural monument|'
      r'valley|wetland|cliff')),
  ('film', _i(r'cinema|movie theat|film studio|theat|television studio|animation studio|concert hall|music venue|'
      r'live house|record label|recording studio')),
  ('tech', _i(r'telecommunication|transmitter|radio mast|television tower|observatory|data cent|'
      r'power station|power plant|water supply|water works|sewage|pumping|airport')),
  ('food', _i(r'brewery|distillery|winery|market|confectioner')),
];
final _titleRules = <(String, RegExp)>[
  ('architecture', RegExp(r'(ビル|タワー|ビルディング)$')),
  ('architecture', RegExp(r'(駅|橋)$')),
  ('history', RegExp(r'商店街$')),
  ('placename', RegExp(r'商店街$')),
  ('nature', RegExp(r'(公園|庭園|川|池|山)$')),
  ('film', RegExp(r'(劇場|映画館|座)$')),
];
// Companies: pick a theme from the name (Wikidata has no simple industry label here).
final _companyTitleRules = <(String, RegExp)>[
  ('tech', RegExp(r'電機|電気|電子|通信|製作所|精機|工業|技研|ソニー|東芝|日立|富士通|NEC|日本電気')),
  ('food', RegExp(r'酒造|醸造|ビール|麦酒|食品|製菓|製粉|乳業|水産|味噌|醤油')),
  ('film', RegExp(r'映画|映像|撮影所|アニメ|スタジオ|放送|動画|プロダクション|出版|書房|書店|集英社|小学館|講談社|KADOKAWA|角川|白泉社|秋田書店|双葉社|'
      r'レコード|ミュージック|音楽|エンタテインメント')),
];
final _disambig = RegExp(r'\s*\([^)]*\)$');

final _classLabels = <String, String>{}; // Wikidata class QID -> English label (process-wide cache)

/// (themes, kind) from Wikidata class labels, or null to drop the article.
(List<String>, String)? classify(List<String> labels, String title,
    {int sitelinks = 0, int? founded, int? thisYear}) {
  if (labels.any(_notAPlace.hasMatch)) return null;
  if (labels.any(_school.hasMatch)) {
    final old = founded != null && (thisYear ?? DateTime.now().year) - founded >= oldSchoolYears;
    return old || sitelinks >= minSitelinks ? (['history'], 'school') : null;
  }
  final org = labels.where(_organization.hasMatch).toList();
  labels = labels.where((l) => !org.contains(l)).toList(); // "radio station" is an organization, not a station
  if (org.isNotEmpty && !_themeRules.any((r) => labels.any(r.$2.hasMatch))) {
    if (sitelinks < minSitelinks) return null;
    final name = title.replaceAll(_disambig, '');
    final themes = [for (final r in _companyTitleRules) if (r.$2.hasMatch(name)) r.$1];
    if (themes.isEmpty) themes.add(org.any(_business.hasMatch) ? 'tech' : 'history'); // a firm: how it works; a public body: its story
    return (themes, 'company');
  }
  var themes = [for (final r in _themeRules) if (labels.any(r.$2.hasMatch)) r.$1];
  if (themes.isEmpty) {
    final t = title.replaceAll(_disambig, '');
    themes = [for (final r in _titleRules) if (r.$2.hasMatch(t)) r.$1];
  }
  if (themes.isEmpty) return null;
  return (themes, labels.isNotEmpty ? labels.first : 'article');
}

/// Year from a Wikidata time claim ("+1873-00-00T00:00:00Z").
int? _year(List claims) {
  for (final c in claims) {
    final t = ((((c as Map)['mainsnak'] as Map?)?['datavalue'] as Map?)?['value'] as Map?)?['time'];
    final m = RegExp(r'^[+-](\d{1,4})-').firstMatch('${t ?? ''}');
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

Future<Json> _get(http.Client client, String url, String ua, Map<String, String> params) async {
  final r = await client
      .get(Uri.parse(url).replace(queryParameters: {'format': 'json', ...webOrigin, ...params}),
          headers: uaHeaders(ua, wikimedia: true))
      .timeout(const Duration(seconds: 25));
  if (r.statusCode != 200) throw http.ClientException('wikimedia ${r.statusCode}');
  return jsonDecode(utf8.decode(r.bodyBytes)) as Json;
}

Iterable<List<T>> _chunks<T>(List<T> xs, int n) sync* {
  for (var i = 0; i < xs.length; i += n) {
    yield xs.sublist(i, i + n > xs.length ? xs.length : i + n);
  }
}

/// Words that mark an article about a place as connected to anime / film / manga / dramas.
const filmSearchTerms = '"ロケ地" OR "撮影場所" OR "撮影に使われ" OR "舞台とした作品" OR "題材とした作品" '
    'OR "登場する作品" OR "登場作品" OR "聖地巡礼" OR "ミュージックビデオ" OR "歌詞に登場" OR "楽曲の舞台"';

/// Articles that are about an incident rather than a place (never a light film chat).
final _incident = RegExp(r'(事件|事故|災害|空襲)$');

/// Page ids of nearby articles that mention a film / anime / manga connection (one search request).
Future<Set<int>> filmPageIds(http.Client client, String userAgent, double lat, double lon, int radius) async {
  final r = await _get(client, wpApi, userAgent, {
    'action': 'query',
    'list': 'search',
    'srsearch': 'nearcoord:${radius.clamp(10, 10000)}m,$lat,$lon ($filmSearchTerms)',
    'srlimit': '50',
    'srprop': '',
  });
  return {for (final h in (r['query']['search'] as List)) (h as Map)['pageid'] as int};
}

/// Adds the 'film' theme to an article the film search found; keeps articles that would otherwise
/// be dropped (no other theme) unless they are not a place at all.
(List<String>, String)? withFilm((List<String>, String)? res, List<String> labels, String title) {
  if (res != null) return (res.$1.contains('film') ? res.$1 : [...res.$1, 'film'], res.$2);
  if (labels.any(_notAPlace.hasMatch) || _incident.hasMatch(title.replaceAll(_disambig, ''))) return null;
  return (['film'], labels.isNotEmpty ? labels.first : 'article');
}

/// [lang]: the Wikipedia edition ('ja', or a local one abroad). Spots from other editions get
/// their Japanese article title as the name when there is one (else the local title), and keep
/// the local article for research.
Future<List<Json>> fetchSpots(http.Client client, String userAgent, double lat, double lon, int radius,
    {String lang = 'ja'}) async {
  final api = wpApiFor(lang);
  // The film search is best effort: without it the spots are just not tagged for film.
  // Its keywords are Japanese, so it only runs on Japanese Wikipedia.
  final filmIds = lang == 'ja'
      ? filmPageIds(client, userAgent, lat, lon, radius).catchError((Object _) => <int>{})
      : Future.value(<int>{});
  final geo = ((await _get(client, api, userAgent, {
    'action': 'query',
    'list': 'geosearch',
    'gscoord': '$lat|$lon',
    'gsradius': '${radius.clamp(10, 10000)}',
    'gslimit': '100',
  }))['query']['geosearch'] as List)
      .cast<Json>();
  if (geo.isEmpty) return [];
  final film = await filmIds;
  final byId = {for (final g in geo) g['pageid'] as int: g};
  final qid = <int, String>{};
  for (final ids in _chunks(byId.keys.toList(), 50)) {
    final pages = (await _get(client, api, userAgent, {
      'action': 'query',
      'prop': 'pageprops',
      'ppprop': 'wikibase_item',
      'pageids': ids.join('|'),
    }))['query']['pages'] as Map;
    for (final p in pages.values) {
      final q = ((p as Map)['pageprops'] as Map?)?['wikibase_item'];
      if (q != null) qid[p['pageid'] as int] = q as String;
    }
  }
  final classes = <String, List<String>>{};
  final notability = <String, int>{};
  final founded = <String, int?>{};
  final enTitle = <String, String>{}; // English Wikipedia title, used as the English name
  final jaTitle = <String, String>{}; // Japanese Wikipedia title (abroad: the name, when there is one)
  final label = <String, Map<String, String>>{}; // Wikidata labels in ja / en (abroad: names in a script we can show)
  for (final qs in _chunks(qid.values.toSet().toList(), 50)) {
    final ents = (await _get(client, wdApi, userAgent, {
      'action': 'wbgetentities',
      'props': 'claims|sitelinks|labels',
      'languages': 'ja|en',
      'ids': qs.join('|'),
    }))['entities'] as Map;
    for (final MapEntry(key: q, value: e) in ents.entries) {
      final claims = ((e as Map)['claims'] as Map?) ?? const {};
      classes[q as String] = [
        for (final c in (claims['P31'] as List? ?? const []))
          if ((c as Map)['mainsnak']?['datavalue'] != null)
            if (c['mainsnak']['datavalue']['value']?['id'] case final String id) id,
      ];
      notability[q] = ((e['sitelinks'] as Map?) ?? const {})
          .keys
          .where((k) => (k as String).endsWith('wiki') && k != 'commonswiki')
          .length;
      founded[q] = _year(claims['P571'] as List? ?? const []);
      final en = (((e['sitelinks'] as Map?)?['enwiki'] as Map?)?['title']) as String?;
      if (en != null) enTitle[q] = en;
      final ja = (((e['sitelinks'] as Map?)?['jawiki'] as Map?)?['title']) as String?;
      if (ja != null) jaTitle[q] = ja;
      label[q] = {
        for (final MapEntry(key: l, value: v) in ((e['labels'] as Map?) ?? const {}).entries)
          if ((v as Map)['value'] case final String text) l as String: text,
      };
    }
  }
  final missing = ({for (final cs in classes.values) ...cs}..removeWhere(_classLabels.containsKey)).toList()..sort();
  for (final ids in _chunks(missing, 50)) {
    final ents = (await _get(client, wdApi, userAgent, {
      'action': 'wbgetentities',
      'props': 'labels',
      'languages': 'en',
      'ids': ids.join('|'),
    }))['entities'] as Map;
    for (final MapEntry(key: q, value: e) in ents.entries) {
      _classLabels[q as String] = ((((e as Map)['labels'] as Map?)?['en'] as Map?)?['value'] ?? '') as String;
    }
  }
  final spots = <Json>[];
  for (final MapEntry(key: pid, value: g) in byId.entries) {
    final q = qid[pid];
    if (q == null) continue;
    final labels = [for (final c in classes[q] ?? const <String>[]) _classLabels[c] ?? '']..removeWhere((l) => l.isEmpty);
    var res = classify(labels, g['title'] as String, sitelinks: notability[q] ?? 0, founded: founded[q]);
    if (film.contains(pid)) res = withFilm(res, labels, g['title'] as String);
    if (res == null) continue;
    final (themes, kind) = res;
    final title = g['title'] as String;
    final en = lang == 'en' ? title : enTitle[q] ?? label[q]?['en'];
    // Abroad: a Japanese name if there is one, else English, else the local title. A local
    // script (Hangul, Thai, Cyrillic...) only as a last resort: the glasses may not show it.
    final name = lang == 'ja' ? title : jaTitle[q] ?? label[q]?['ja'] ?? en ?? title;
    spots.add({
      'id': lang == 'ja' ? 'wp:$pid' : 'wp:$lang:$pid',
      'name': name.replaceAll(_disambig, ''),
      'lat': round6(g['lat'] as num),
      'lon': round6(g['lon'] as num),
      'themes': themes,
      'kind': kind,
      'wikipedia': '$lang:$title',
      'wikidata': q,
      if (en != null) 'name_en': en.replaceAll(_disambig, ''),
      '_tags': <String, dynamic>{},
      '_sitelinks': notability[q] ?? 0,
    });
  }
  return dedupeGroups(spots);
}

const groupPrefix = 3; // "ソニー…" / "NTT…": same leading 3+ characters
const groupDistanceM = 1000.0;

/// Group companies nearby share a name ("ソニー", "ソニーグループ", "ソニーエナジー・デバイス"):
/// keep only the best-known one so the radio doesn't repeat the same story.
List<Json> dedupeGroups(List<Json> spots) {
  bool sameGroup(Json a, Json b) {
    final x = a['name'] as String, y = b['name'] as String;
    var n = 0;
    while (n < x.length && n < y.length && x[n] == y[n]) {
      n++;
    }
    return n >= groupPrefix &&
        distanceM((a['lat'] as num).toDouble(), (a['lon'] as num).toDouble(), (b['lat'] as num).toDouble(),
                (b['lon'] as num).toDouble()) <=
            groupDistanceM;
  }

  final kept = <Json>[];
  // Most-known first; ties keep the geosearch order (Dart's sort is not stable).
  final order = [for (var i = 0; i < spots.length; i++) i]..sort((i, j) {
      final c = ((spots[j]['_sitelinks'] ?? 0) as int).compareTo((spots[i]['_sitelinks'] ?? 0) as int);
      return c != 0 ? c : i.compareTo(j);
    });
  for (final sp in order.map((i) => spots[i])) {
    if (sp['kind'] == 'company' && kept.any((k) => k['kind'] == 'company' && sameGroup(sp, k))) continue;
    kept.add(sp);
  }
  return kept;
}
