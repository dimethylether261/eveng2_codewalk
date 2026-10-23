import 'dart:convert';

import 'package:http/http.dart' as http;

import 'discover.dart' show duplicates;
import 'util.dart';

/// OSM spots + Wikipedia articles. A Wikipedia article that is the same place as an OSM spot
/// (same wikipedia tag, or a similar name within 150 m) enriches that spot instead of duplicating it.
List<Json> merge(List<Json> osm, List<Json> wp) {
  final merged = [...osm];
  for (final w in wp) {
    final same = osm.where((o) => o['wikipedia'] == w['wikipedia']).firstOrNull ??
        osm
            .where((o) => duplicates(w['name'] as String, (w['lat'] as num).toDouble(), (w['lon'] as num).toDouble(), [o]))
            .firstOrNull;
    if (same == null) {
      merged.add(w);
      continue;
    }
    same.putIfAbsent('wikipedia', () => w['wikipedia']);
    same.putIfAbsent('wikidata', () => w['wikidata']);
    if (w['name_en'] != null) same.putIfAbsent('name_en', () => w['name_en']);
    final themes = (same['themes'] as List).cast<String>().toList();
    for (final t in (w['themes'] as List).cast<String>()) {
      if (!themes.contains(t)) themes.add(t);
    }
    same['themes'] = themes;
  }
  return merged;
}

String _stripHtml(String? s) => (s ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim();

/// Spot image from Wikidata (P18) + Wikimedia Commons license metadata, or null.
Future<Json?> fetchImage(http.Client client, String? wikidataId, String userAgent) async {
  if (wikidataId == null || !RegExp(r'^Q\d+$').hasMatch(wikidataId)) return null;
  final headers = uaHeaders(userAgent, wikimedia: true);
  try {
    // Same {entities: {Q..: {claims}}} shape either way; Special:EntityData has no CORS for browsers.
    final entity = isWeb
        ? Uri.parse('https://www.wikidata.org/w/api.php').replace(queryParameters: {
            'action': 'wbgetentities', 'ids': wikidataId, 'props': 'claims', 'format': 'json', ...webOrigin,
          })
        : Uri.parse('https://www.wikidata.org/wiki/Special:EntityData/$wikidataId.json');
    var r = await client.get(entity, headers: headers).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final claims = (jsonDecode(utf8.decode(r.bodyBytes))['entities'][wikidataId]['claims'] as Map?) ?? const {};
    final p18 = claims['P18'] as List?;
    if (p18 == null || p18.isEmpty) return null;
    final filename = p18[0]['mainsnak']['datavalue']['value'] as String;
    r = await client.get(
        Uri.parse('https://commons.wikimedia.org/w/api.php').replace(queryParameters: {
          'action': 'query',
          'titles': 'File:$filename',
          'prop': 'imageinfo',
          'iiprop': 'url|extmetadata|user',
          'iiurlwidth': '800',
          'format': 'json',
          ...webOrigin,
        }),
        headers: headers).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final page = (jsonDecode(utf8.decode(r.bodyBytes))['query']['pages'] as Map).values.first as Map;
    final info = (page['imageinfo'] as List)[0] as Map;
    final meta = (info['extmetadata'] as Map?) ?? const {};
    final license = _stripHtml(meta['LicenseShortName']?['value'] as String?);
    if (license.isEmpty) return null;
    // "Own work" photos often leave Artist empty: the uploader is then the author to credit
    // (CC BY-SA and the like require the attribution).
    final artist = _stripHtml(meta['Artist']?['value'] as String?);
    final author = artist.isNotEmpty ? artist : _stripHtml(info['user'] as String?);
    return {
      'url': info['thumburl'] ?? info['url'],
      'license': license,
      'author': author.isEmpty ? '不明' : author,
      'source_url': info['descriptionurl'],
    };
  } catch (_) {
    return null;
  }
}
