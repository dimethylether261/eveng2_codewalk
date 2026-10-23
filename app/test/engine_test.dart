// Tests for the on-device engine (ported from the earlier Python server's tests).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:codewalk/engine/characters.dart';
import 'package:codewalk/engine/claude.dart';
import 'package:codewalk/engine/discover.dart' as discover;
import 'package:codewalk/engine/engine.dart';
import 'package:codewalk/engine/overpass.dart' as overpass;
import 'package:codewalk/engine/pipeline.dart' as pipeline;
import 'package:codewalk/engine/prompts.dart' as prompts;
import 'package:codewalk/engine/review.dart' as review;
import 'package:codewalk/engine/store_file.dart';
import 'package:codewalk/engine/texts.dart' as texts;
import 'package:codewalk/engine/util.dart';
import 'package:codewalk/engine/country.dart' as country;
import 'package:codewalk/engine/sources.dart' as sources;
import 'package:codewalk/engine/store.dart';
import 'package:codewalk/engine/wikipedia.dart' as wikipedia;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final fixture = jsonDecode(File('test/fixtures/overpass_fixture.json').readAsStringSync()) as Json;
const url = 'https://ja.wikipedia.org/wiki/品川宿';

Json cite(String text, String quote, {String u = url, String title = '品川宿 - Wikipedia'}) => {
      'type': 'text',
      'text': text,
      'citations': [
        {'type': 'web_search_result_location', 'cited_text': quote, 'url': u, 'title': title},
      ],
    };

final researchBlocks = <Json>[
  {'type': 'text', 'text': '調べた結果です。\n\n'},
  cite('品川宿は東海道五十三次の最初の宿場である。', '品川宿は、東海道五十三次の宿場の一つ。第一番目の宿場である。'),
  {'type': 'text', 'text': '\n\n'},
  cite('日本橋を出て最初の宿場だった。', '日本橋から2里の距離にあり'),
  {'type': 'text', 'text': '\n\n根拠のない補足（引用なし）。'},
];

List<Json> factsBlocks(int n) => [
      for (var i = 0; i < n; i++) ...[
        cite('品川宿についての事実その$iです。', '引用文その$iの本文です', u: '$url#$i'),
        {'type': 'text', 'text': '\n\n'},
      ],
    ];

const discovered = [
  {'name': 'ソニーシティ（そにーしてぃ）', 'theme': 'architecture', 'kind': 'office', 'why': '近代的な本社ビル'},
  {'name': '八ツ山橋', 'theme': 'infrastructure', 'kind': 'bridge', 'why': '鉄道をまたぐ橋'}, // already an OSM spot
  {'name': '架空タワー', 'theme': 'architecture', 'kind': 'tower', 'why': '地図に無い'}, // not on the map
  {'name': '品川シーズンテラス', 'theme': 'nonsense', 'kind': 'x', 'why': 'theme invalid'},
  {'name': '北品川', 'theme': 'history', 'kind': 'town', 'why': 'the town itself'},
];

/// Plays the Claude API: research (tools), dialogue, check and review, by the request's system prompt.
class FakeClaude {
  FakeClaude({List<Json>? blocks, this.unsupported = const {}, List<int> reviewScores = const [4], this.strong})
      : blocks = blocks ?? researchBlocks,
        reviewScores = [...reviewScores];
  final List<Json> blocks;
  final List<Json>? strong; // research result for the escalation model
  final Set<int> unsupported;
  final List<int> reviewScores;
  int researchCalls = 0, checks = 0;
  final researchModels = <String>[];
  final dialoguePrompts = <String>[];
  final requests = <Json>[];
  Set<int> Function(int check)? commanderFact;
  Duration delay = Duration.zero;

  Json _msg(List<Json> content, {String stop = 'end_turn'}) => {
        'model': 'x',
        'content': content,
        'stop_reason': stop,
        'usage': {'input_tokens': 100, 'output_tokens': 10},
      };

  Future<http.Response> handle(http.Request r) async {
    final body = jsonDecode(r.body) as Json;
    requests.add(body);
    final system = body['system'] as String? ?? '';
    final user = ((body['messages'] as List).first as Map)['content'] as String;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    late Json out;
    if (body['tools'] != null) {
      researchCalls++;
      researchModels.add(body['model'] as String);
      if (system == texts.discoverSystem) {
        out = _msg([
          {'type': 'text', 'text': '見つけました。${jsonEncode({'places': discovered})}'},
        ]);
      } else {
        final strongModel = body['model'] != 'claude-haiku-5-5';
        out = _msg(strongModel && strong != null ? strong! : blocks);
      }
    } else if (user == 'ping') {
      out = _msg([
        {'type': 'text', 'text': 'p'},
      ], stop: 'max_tokens');
    } else if (system == texts.reviewSystem) {
      final v = reviewScores.length > 1 ? reviewScores.removeAt(0) : reviewScores.first;
      out = _msg([
        {
          'type': 'text',
          'text': jsonEncode({
            'scores': {for (final k in texts.reviewCriteria.keys) k: v},
            'issues': v >= 4 ? [] : ['つかみが弱い'],
          }),
        },
      ]);
    } else if (system == texts.checkSystem) {
      checks++;
      final n = (jsonDecode(user.split('会話:\n')[1].split('\n\n')[0]) as List).length;
      final cf = commanderFact?.call(checks) ?? const <int>{};
      out = _msg([
        {
          'type': 'text',
          'text': jsonEncode({
            'results': [
              for (var i = 0; i < n; i++)
                {'index': i, 'supported': !unsupported.contains(i), 'nudge': false, 'commander_fact': cf.contains(i)},
            ],
          }),
        },
      ]);
    } else {
      dialoguePrompts.add(user);
      final schema = (body['output_config'] as Map)['format']['schema'] as Map;
      final sp = (schema['properties']['lines']['items']['properties']['speaker']['enum'] as List).last;
      final pattern = (schema['properties']['pattern']['enum'] as List).first;
      out = _msg([
        {
          'type': 'text',
          'text': jsonEncode({
            'pattern': pattern,
            'lines': [
              {'speaker': 'ootori', 'text': '{{CODENAME}}、聞こえるか。フクロウ、頼む。', 'fact_ids': [1]},
              {'speaker': sp, 'text': 'ここは東海道五十三次の最初の宿場なの。', 'fact_ids': [1]},
              {'speaker': 'ootori', 'text': 'ほう。', 'fact_ids': []},
              {'speaker': sp, 'text': '日本橋を出て最初の宿場だったのよ。', 'fact_ids': [2]},
              {'speaker': sp, 'text': 'あっちにも古い寺があるから行ってみて。', 'fact_ids': []},
              {'speaker': 'ootori', 'text': '品川宿か。今度から見る目が変わりそうだ。', 'fact_ids': []},
            ],
          }),
        },
      ]);
    }
    return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

// --- Wikipedia / Wikidata / Nominatim / Overpass fakes ---

const wpGeo = [
  {'pageid': 11, 'title': '品川インターシティ', 'lat': 35.6285, 'lon': 139.7410},
  {'pageid': 12, 'title': 'すき家 (企業)', 'lat': 35.6286, 'lon': 139.7411},
  {'pageid': 13, 'title': '品川神社', 'lat': 35.61951, 'lon': 139.74051}, // same as the OSM shrine
  {'pageid': 14, 'title': '天王洲運河', 'lat': 35.6210, 'lon': 139.7470},
  {'pageid': 15, 'title': 'NTT品川TWINS', 'lat': 35.6283, 'lon': 139.7415}, // no P31 -> dropped
  {'pageid': 16, 'title': 'ソニーグループ', 'lat': 35.6312, 'lon': 139.7437}, // well-known company HQ
  {'pageid': 17, 'title': '楽天Edy', 'lat': 35.6290, 'lon': 139.7420}, // a product, not a place
];
const wpQid = {11: 'Q1', 12: 'Q2', 13: 'Q3', 14: 'Q4', 15: 'Q5', 16: 'Q6', 17: 'Q7'};
const wdP31 = {
  'Q1': ['C_SKY'], 'Q2': ['C_BIZ'], 'Q3': ['C_SHRINE'], 'Q4': ['C_CANAL'], 'Q5': <String>[], 'Q6': ['C_HOLD'],
  'Q7': ['C_CARD'], //
};
const wdSitelinks = {'Q2': 1, 'Q6': 60, 'Q7': 2};
const wdLabel = {
  'C_SKY': 'skyscraper complex', 'C_BIZ': 'business', 'C_SHRINE': 'Shinto shrine', 'C_CANAL': 'canal',
  'C_HOLD': 'holding company', 'C_CARD': 'proximity card', //
};
const areaFixture = {
  'elements': [
    {'type': 'area', 'id': 3603554304, 'tags': {'admin_level': '7', 'boundary': 'administrative', 'name': '品川区'}},
    {
      'type': 'area',
      'id': 3616885808,
      'tags': {'admin_level': '9', 'boundary': 'administrative', 'name': '北品川', 'wikipedia': 'ja:北品川'},
    },
    {'type': 'area', 'id': 3617011769, 'tags': {'admin_level': '10', 'boundary': 'administrative', 'name': '北品川一丁目'}},
  ],
};
Json photonFeature(String type, int id, double lat, double lon, String key, String value, String name) => {
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': [lon, lat]},
      'properties': {'osm_type': type, 'osm_id': id, 'osm_key': key, 'osm_value': value, 'name': name},
    };

final photon = {
  'ソニーシティ': [
    photonFeature('N', 3624296567, 35.6314, 139.7433, 'amenity', 'cafe', 'タリーズコーヒー ソニーシティ内店'),
    photonFeature('W', 34288649, 35.6311191, 139.7438190, 'building', 'commercial', 'ソニーシティ'),
  ],
  '八ツ山橋': [
    photonFeature('W', 2001, 35.6230, 139.7410, 'highway', 'primary', '八ツ山橋'),
  ],
};

http.Response _json(Object o) => http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

MockClient fakeHttp(FakeClaude claude, {bool overpassDown = false}) => MockClient((r) async {
      final u = r.url.toString();
      final p = r.url.queryParameters;
      if (u.startsWith(apiUrl)) return claude.handle(r);
      if (u.contains('wikipedia.org')) {
        if (p['list'] == 'search') {
          expect(p['srsearch'], startsWith('nearcoord:'));
          return _json({
            'query': {
              'search': [
                {'pageid': 15}, // NTT品川TWINS: no class of its own, kept as a film spot
                {'pageid': 17}, // 楽天Edy: a product, still dropped
              ],
            },
          });
        }
        if (p['list'] == 'geosearch') {
          return _json({
            'query': {'geosearch': wpGeo},
          });
        }
        return _json({
          'query': {
            'pages': {
              for (final i in p['pageids']!.split('|'))
                i: {'pageid': int.parse(i), 'pageprops': {'wikibase_item': wpQid[int.parse(i)]}},
            },
          },
        });
      }
      if (u.contains('wikidata.org/w/api.php')) {
        final ids = p['ids']!.split('|');
        if ((p['props'] ?? '').startsWith('claims')) {
          return _json({
            'entities': {
              for (final q in ids)
                q: {
                  'claims': {
                    'P31': [
                      for (final c in wdP31[q]!) {
                        'mainsnak': {'datavalue': {'value': {'id': c}}},
                      },
                    ],
                  },
                  'sitelinks': {for (var i = 0; i < (wdSitelinks[q] ?? 1); i++) 'l${i}wiki': {}},
                },
            },
          });
        }
        return _json({
          'entities': {
            for (final c in ids) c: {'labels': {'en': {'value': wdLabel[c]}}},
          },
        });
      }
      if (u.contains('photon')) return _json({'type': 'FeatureCollection', 'features': photon[p['q']] ?? []});
      if (u.contains('nominatim')) return _json([]); // country unknown: the Japan box decides
      if (u.contains('overpass')) {
        if (overpassDown) return http.Response('busy', 504);
        return _json(r.body.contains('is_in') ? areaFixture : fixture);
      }
      return http.Response('', 404);
    });

Future<Engine> makeEngine(FakeClaude? claude, {EngineConfig config = const EngineConfig(escalateResearchModel: '')}) async =>
    Engine(
      store: await openStore(null),
      apiKey: claude == null ? null : 'x',
      config: config,
      userAgent: 'test',
      client: fakeHttp(claude ?? FakeClaude()),
      log: (_) {},
    );

Future<Json> waitReady(Engine e, String spotId, List<String> themes, {String codename = 'ウォーカー'}) async {
  for (var i = 0; i < 100; i++) {
    final r = e.dialogue(spotId, themes, codename);
    if (r['status'] != 'pending') return r;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('still pending');
}

Claude fakeLlm(FakeClaude f, {EngineConfig config = const EngineConfig()}) =>
    Claude('x', config: config, client: fakeHttp(f));

Json shrine() => overpass.parseElements(fixture).first;

void main() {
  group('overpass', () {
    test('classify and parse', () {
      final spots = overpass.parseElements(fixture);
      final by = {for (final s in spots) s['name']: s};
      expect(by['品川神社']!['themes'], ['history']);
      expect(by['品川神社']!['kind'], 'shrine');
      expect((by['八ツ山橋']!['themes'] as List).toSet(), {'architecture', 'placename'});
      expect(by['北品川駅']!['themes'], contains('architecture')); // stations: the Sphinx
      expect(by['御殿山坂']!['kind'], 'slope');
      expect(by.containsKey('名無しのコンビニ'), isFalse);
      expect(by.containsKey('第一京浜'), isFalse); // road segment on a bridge, not a bridge name
      expect(by.containsKey('新東京百景') || by.containsKey('小さな稲荷'), isFalse); // low-info markers
      expect(by['板垣退助の墓']!['themes'], ['history']);
      expect(by['品川インターシティ']!['themes'], ['architecture']);
      expect(by['品川インターシティ']!['kind'], 'building');
      expect(by['目黒川']!['themes'], ['nature']);
      expect(by['土蔵相模跡']!['themes'], ['history']);
      expect((by['こぜきばし']!['themes'] as List).toSet(), {'architecture', 'placename'});
      expect(by['円錐石']!['kind'], 'artwork');
      expect(by.containsKey('名もなきオブジェ'), isFalse);
      expect(spots.where((s) => s['name'] == '八ツ山橋').length, 1);
      expect(publicSpot(by['品川神社']!).keys.any((k) => k.startsWith('_')), isFalse);
    });

    test('new themes', () {
      expect(overpass.classify({'name': '潮見坂', 'highway': 'residential'}).$1, ['nature', 'placename']);
      expect(overpass.classify({'name': '〇〇劇場', 'amenity': 'theatre'}).$1, contains('film'));
      expect(overpass.classify({'name': '〇〇酒造', 'craft': 'brewery'}).toString(), (['food'], 'brewery').toString());
      expect(overpass.classify({'name': '電波塔', 'man_made': 'tower', 'tower:type': 'communication'}).$1, contains('tech'));
      expect(overpass.classify({'name': '大イチョウ', 'natural': 'tree'}).toString(), (['nature'], 'tree').toString());
      expect(overpass.classify({'name': 'x公園', 'leisure': 'park'}).$1, isEmpty);
    });

    test('town', () {
      final a = overpass.parseArea(areaFixture, 35.6226, 139.7389)!;
      expect(a['name'], '北品川');
      expect(a['wikipedia'], 'ja:北品川');
      expect((a['_tags'] as Map)['city'], '品川区');
      expect(a['themes'], allThemes);
    });

    test('wikipedia url', () {
      expect(wikipediaUrl('ja:品川宿'), url);
      expect(wikipediaUrl('garbage'), isNull);
    });
  });

  group('abroad', () {
    test('the local Wikipedia edition adds the places Japanese Wikipedia does not know', () async {
      var reverse = 0;
      final requested = <String>[];
      final client = MockClient((r) async {
        final u = r.url.toString();
        final p = r.url.queryParameters;
        if (u.contains('nominatim') && u.contains('/reverse')) {
          reverse++;
          return _json({'address': {'country_code': 'GB'}});
        }
        if (u.contains('overpass')) return _json({'elements': []});
        if (u.contains('wikipedia.org')) {
          final lang = r.url.host.split('.').first;
          requested.add('$lang:${p['list'] ?? p['prop']}');
          if (p['list'] == 'search') return _json({'query': {'search': []}});
          if (p['list'] == 'geosearch') {
            return _json({
              'query': {
                'geosearch': [
                  {'pageid': lang == 'ja' ? 1 : 101, 'title': lang == 'ja' ? 'ビッグ・ベン' : 'Big Ben', 'lat': 51.5007, 'lon': -0.1246},
                  if (lang == 'en') {'pageid': 102, 'title': 'Red Lion, Westminster', 'lat': 51.5025, 'lon': -0.1262},
                  if (lang == 'en') {'pageid': 103, 'title': 'Westminster Pier', 'lat': 51.5016, 'lon': -0.1236},
                ],
              },
            });
          }
          final qids = {1: 'Q1', 101: 'Q1', 102: 'Q2', 103: 'Q3'};
          return _json({
            'query': {
              'pages': {
                for (final i in p['pageids']!.split('|')) i: {'pageid': int.parse(i), 'pageprops': {'wikibase_item': qids[int.parse(i)]}},
              },
            },
          });
        }
        if (u.contains('wikidata.org/w/api.php')) {
          final ids = p['ids']!.split('|');
          if ((p['props'] ?? '').startsWith('claims')) {
            return _json({
              'entities': {
                for (final q in ids)
                  q: {
                    'claims': {
                      'P31': [
                        {'mainsnak': {'datavalue': {'value': {'id': 'Q900'}}}},
                      ],
                    },
                    'sitelinks': {
                      if (q != 'Q3') 'enwiki': {'title': q == 'Q1' ? 'Big Ben' : 'Red Lion, Westminster'},
                      if (q == 'Q1') 'jawiki': {'title': 'ビッグ・ベン'},
                    },
                    if (q == 'Q3') 'labels': {'ja': {'value': 'ウェストミンスター桟橋'}, 'en': {'value': 'Westminster Pier'}},
                  },
              },
            });
          }
          return _json({
            'entities': {for (final c in ids) c: {'labels': {'en': {'value': 'listed building'}}}},
          });
        }
        return http.Response('', 404);
      });
      final e = Engine(store: Store.fromJson(null), apiKey: null, userAgent: 'test', client: client, log: (_) {});
      final spots = await e.spots(51.5007, -0.1246);
      final byName = {for (final s in spots) s['name']: s};
      expect(byName.keys, containsAll(['ビッグ・ベン', 'Red Lion, Westminster']));
      expect(spots.where((s) => s['wikidata'] == 'Q1'), hasLength(1)); // in both editions: kept once
      expect(byName['ビッグ・ベン']!['wikipedia'], 'ja:ビッグ・ベン');
      expect(byName['Red Lion, Westminster']!['wikipedia'], 'en:Red Lion, Westminster'); // researched there
      expect(byName['Red Lion, Westminster']!['name_en'], 'Red Lion, Westminster');
      expect(byName['ウェストミンスター桟橋']!['name_en'], 'Westminster Pier'); // no Japanese article: the Wikidata label
      expect(requested, contains('en:geosearch'));
      expect(requested.where((r) => r.endsWith(':search')), everyElement(startsWith('ja:'))); // film search: Japanese only
      await e.spots(51.501, -0.125, radius: 300); // same 1-degree cell: the country is cached
      expect(reverse, 1);
    });

    test('in Japan (or when the country is unknown) only Japanese Wikipedia is searched', () {
      expect(country.wikisFor('jp'), isEmpty);
      expect(country.wikisFor(null), isEmpty);
      expect(country.wikisFor('fr'), ['fr']);
      expect(country.wikisFor('zz'), ['en']); // not listed: English
      expect(country.countryCell(51.5, -0.12), '51,-1');
    });

    test('a town abroad: the smallest area with an article, named in Japanese or English', () {
      Map<String, dynamic> el(int id, Map<String, String> tags) => {'type': 'area', 'id': id, 'tags': tags};
      final london = {
        'elements': [
          el(1, {'boundary': 'administrative', 'admin_level': '2', 'name': 'United Kingdom', 'wikidata': 'Q145'}),
          el(2, {'boundary': 'administrative', 'admin_level': '6', 'name': 'Greater London', 'wikipedia': 'en:Greater London'}),
          el(3, {
            'boundary': 'administrative', 'admin_level': '8', 'name': 'City of Westminster',
            'name:ja': 'シティ・オブ・ウェストミンスター', 'wikipedia': 'en:City of Westminster',
          }),
          el(4, {'boundary': 'administrative', 'admin_level': '10', 'name': "St James's"}), // no article: skipped
          el(5, {'place': 'quarter', 'name': 'Whitehall', 'wikidata': 'Q1030876', 'wikipedia': 'en:Whitehall'}),
        ],
      };
      final town = overpass.parseArea(london, 51.5045, -0.1270, country: 'gb')!;
      expect(town['id'], 'area:5');
      expect([town['name'], town['name_en'], town['wikipedia']], ['Whitehall', 'Whitehall', 'en:Whitehall']);
      expect((town['_tags'] as Map)['city'], 'シティ・オブ・ウェストミンスター'); // the next larger area, in Japanese
      expect((town['_tags'] as Map)['country'], 'gb');
      // Without the district, the ward-level borough with its Japanese name.
      final noQuarter = {'elements': (london['elements'] as List).where((e) => (e as Map)['id'] != 5).toList()};
      expect(overpass.parseArea(noQuarter, 51.5045, -0.1270, country: 'gb')!['name'], 'シティ・オブ・ウェストミンスター');
      // Country unknown: Japanese rules inside Japan, these rules outside.
      expect(overpass.parseArea(london, 51.5045, -0.1270)!['id'], 'area:5');
      expect(overpass.parseArea(areaFixture, 35.6197, 139.7426)!['name'], '北品川');
      expect(overpass.parseArea({'elements': [el(1, {'boundary': 'administrative', 'admin_level': '4', 'name': 'X', 'wikidata': 'Q1'})]},
          40.7, -74.0, country: 'us'), isNull); // a state is not a town
    });

    test('discovery abroad asks for local official names and searches the map in that country', () async {
      final town = {
        'id': 'area:5', 'name': 'ホワイトホール', 'lat': 51.5045, 'lon': -0.127,
        '_tags': {'city': 'ロンドン', 'local_name': 'Whitehall', 'country': 'gb'},
      };
      final text = discover.discoverUser(town);
      expect(text, allOf(contains('現地名 Whitehall'), contains('国コード GB'), contains('現地の言葉')));
      expect(discover.discoverUser({...town, '_tags': {'city': '品川区'}}), isNot(contains('国コード')));
      final seen = <Map<String, String>>[];
      final finder = discover.PlaceFinder(
          MockClient((r) async {
            seen.add(r.url.queryParameters);
            return _json({'features': []});
          }),
          'test',
          minInterval: Duration.zero);
      await finder.findAll(['Banqueting House'], 51.5045, -0.127);
      // A box around the town; no language: Photon's default is the local name the search asked for.
      expect(seen.single['bbox'], '${-0.127 - 0.02},${51.5045 - 0.02},${-0.127 + 0.02},${51.5045 + 0.02}');
      expect(seen.single.containsKey('lang'), isFalse);
    });

    test('the country lookup is not asked again this launch once it failed', () async {
      var reverse = 0;
      final e = Engine(
        store: Store.fromJson(null),
        apiKey: null,
        userAgent: 'test',
        log: (_) {},
        client: MockClient((r) async {
          final u = r.url.toString();
          if (u.contains('/reverse')) {
            reverse++;
            return http.Response('busy', 503);
          }
          if (u.contains('overpass')) return _json({'elements': []});
          if (u.contains('wikipedia.org')) return _json({'query': {'geosearch': [], 'search': []}});
          return _json({});
        }),
      );
      await e.spots(35.62, 139.74);
      await e.spots(36.62, 140.74); // another 1-degree cell
      expect(reverse, 1);
    });

    test("Nominatim email=: the developer's address, else the user's contact when it is an email", () {
      final expected = appContactEmail.isNotEmpty ? appContactEmail : 'me@example.com';
      expect(nominatimEmail('CodeWalk/0.1 (Even G2 app; me@example.com)'), {'email': expected});
      expect(nominatimEmail('CodeWalk/0.1 (Even G2 app; https://example.com)'),
          appContactEmail.isNotEmpty ? {'email': appContactEmail} : isEmpty);
    });

    test('photo credit: the uploader when Commons leaves the author empty ("Own work")', () async {
      MockClient commons(String artist) => MockClient((r) async {
            final u = r.url.toString();
            if (u.contains('wikidata.org')) {
              return _json({
                'entities': {
                  'Q1': {
                    'claims': {
                      'P18': [
                        {'mainsnak': {'datavalue': {'value': 'Shinagawajinja_syaden.jpg'}}},
                      ],
                    },
                  },
                },
              });
            }
            expect(r.url.queryParameters['iiprop'], contains('user'));
            return _json({
              'query': {
                'pages': {
                  '1': {
                    'imageinfo': [
                      {
                        'url': 'https://upload.wikimedia.org/a.jpg',
                        'user': 'Oouiaui',
                        'extmetadata': {'Artist': {'value': artist}, 'LicenseShortName': {'value': 'CC BY-SA 4.0'}},
                      },
                    ],
                  },
                },
              },
            });
          });
      expect((await sources.fetchImage(commons(''), 'Q1', 'test'))!['author'], 'Oouiaui');
      expect((await sources.fetchImage(commons('<a href="x">Someone</a>'), 'Q1', 'test'))!['author'], 'Someone');
    });

    test('shopping streets (商店街): from the map, Wikidata and discovery, for the Owl and the Fox', () {
      expect(overpass.buildQuery(35.6, 139.7, 400), contains('商店街'));
      expect(overpass.buildQuery(51.5, -0.12, 400, japan: false), isNot(contains('商店街')));
      for (final tags in [
        {'name': '戸越銀座商店街', 'highway': 'pedestrian'},
        {'name': '高砂銀座商店街', 'highway': 'unclassified'},
        {'name': '十条銀座商店街', 'landuse': 'retail'},
      ]) {
        final (themes, kind) = overpass.classify(tags);
        expect([themes, kind], [['history', 'placename'], 'shotengai'], reason: tags['name']);
      }
      expect(overpass.classify({'name': '商店街入口', 'highway': 'bus_stop'}).$1, isEmpty); // not the street itself
      for (final label in ['shōtengai', 'shopping street', 'commercial district']) {
        expect(wikipedia.classify([label], '谷中銀座商店街')!.$1, containsAll(['history', 'placename']), reason: label);
      }
      expect(wikipedia.classify([], '砂町銀座商店街')!.$1, containsAll(['history', 'placename'])); // no class: the title
      final hit = {'lat': '35.6', 'lon': '139.7', 'osm_type': 'way', 'osm_id': 1, 'type': 'pedestrian'};
      final town = {'id': 'area:1', 'name': '戸越', '_tags': {'city': '品川区'}};
      final spot = discover.toSpot({'name': '戸越銀座商店街', 'theme': 'food', 'kind': '', 'why': ''}, hit, town);
      expect((spot['themes'] as List).toSet(), {'food', 'history', 'placename'});
    });

    test('map spots abroad: no Japanese slope search, bridges and streets in other languages', () {
      final q = overpass.buildQuery(51.5, -0.12, 400, japan: false);
      expect(q, isNot(contains('坂')));
      expect(overpass.buildQuery(35.6, 139.7, 400), contains('坂'));
      expect(q, contains('["highway"]["wikidata"]'));
      Map<String, String> bridge(String name) => {'name': name, 'highway': 'primary', 'bridge': 'yes'};
      for (final n in ['Waterloo Bridge', 'Pont Neuf', 'Ponte Vecchio', 'Oberbaumbrücke', 'Västerbron', 'Карамышевский мост', '八ツ山橋']) {
        expect(overpass.classify(bridge(n)).$1, contains('architecture'), reason: n);
      }
      expect(overpass.classify(bridge('A3')).$1, isEmpty); // a road on a bridge, not a named bridge
      final street = overpass.classify({'name': 'Lower Marsh', 'highway': 'residential', 'wikidata': 'Q6693229'});
      expect([street.$1, street.$2], [['placename', 'history'], 'street']);
      expect(overpass.classify({'name': 'Lower Marsh', 'highway': 'residential'}).$1, isEmpty); // no entry: too little to tell
    });

    test('when Overpass is down, map spots from an older answer are used (not just Wikipedia)', () async {
      String? saved;
      final s1 = Store.fromJson(null, persist: (j) async => saved = j);
      final up = Engine(store: s1, apiKey: null, userAgent: 'test', client: fakeHttp(FakeClaude()), log: (_) {});
      final fresh = await up.spots(35.6226, 139.7389);
      await s1.flush();
      // A year minus a day later: past the 7-day cache, still within the stale limit.
      final data = jsonDecode(saved!) as Map<String, dynamic>;
      for (final a in (data['areas'] as Map).values) {
        (a as Map)['ts'] = DateTime.now().millisecondsSinceEpoch / 1000 - 364 * 24 * 3600;
      }
      final logs = <String>[];
      final down = Engine(
          store: Store.fromJson(jsonEncode(data)), apiKey: null, userAgent: 'test',
          client: fakeHttp(FakeClaude(), overpassDown: true), log: logs.add);
      final again = await down.spots(35.6226, 139.7389);
      final osm = fresh.where((x) => (x['id'] as String).startsWith('osm:')).map((x) => x['id']).toSet();
      expect(osm, isNotEmpty);
      expect(again.map((x) => x['id']).toSet().containsAll(osm), isTrue);
      expect(logs, contains(startsWith('using ')));
    });

    test('the glasses app may reach every local edition (network whitelist in g2/app.json)', () {
      final app = jsonDecode(File('../g2/app.json').readAsStringSync()) as Map;
      final net = (app['permissions'] as List).cast<Map>().firstWhere((p) => p['name'] == 'network');
      final allowed = (net['whitelist'] as List).cast<String>().toSet();
      for (final lang in country.allLocalWikis) {
        expect(allowed, contains('https://$lang.wikipedia.org'));
      }
    });
  });

  group('wikipedia', () {
    test('classify', () {
      expect(wikipedia.classify(['business', 'fast food restaurant chain'], 'すき家 (企業)', sitelinks: 1), isNull);
      expect(wikipedia.classify(['holding company', 'conglomerate'], 'ソニーグループ', sitelinks: 60).toString(),
          (['tech'], 'company').toString());
      expect(wikipedia.classify(['business'], '〇〇酒造', sitelinks: 5).toString(), (['food'], 'company').toString());
      // The retired "暮らし・インフラ" theme: nothing is left with no one to tell it.
      expect(wikipedia.classify(['railway station'], 'Surbiton railway station')!.$1, ['architecture']);
      expect(wikipedia.classify(['street'], 'Waterloo Road')!.$1, containsAll(['placename', 'history']));
      expect(wikipedia.classify(['power station'], 'Battersea Power Station')!.$1, containsAll(['architecture', 'tech']));
      expect(wikipedia.classify(['government agency', 'police force'], 'Metropolitan Police', sitelinks: 40)!.$1, ['history']);
      expect(wikipedia.classify(['business'], 'Shell plc', sitelinks: 40)!.$1, ['tech']);
      expect(wikipedia.classify(['elementary school in Japan'], '台場小学校', sitelinks: 1, founded: 1873, thisYear: 2026).toString(),
          (['history'], 'school').toString());
      expect(wikipedia.classify(['elementary school in Japan'], '新設小学校', sitelinks: 1, founded: 2015, thisYear: 2026), isNull);
      expect(wikipedia.classify(['television studio'], 'テレビ東京天王洲スタジオ')!.$1, ['architecture', 'film']);
      expect(wikipedia.classify(['urban park'], '〇〇公園')!.$1, contains('nature'));
    });

    test('company groups collapse to best known', () {
      final spots = wikipedia.dedupeGroups([
        {'name': 'ソニー', 'kind': 'company', 'lat': 35.63, 'lon': 139.74, '_sitelinks': 10},
        {'name': 'ソニーグループ', 'kind': 'company', 'lat': 35.631, 'lon': 139.743, '_sitelinks': 60},
        {'name': 'ソニー銀行', 'kind': 'company', 'lat': 36.0, 'lon': 139.74, '_sitelinks': 5}, // far away
      ]);
      expect(spots.map((s) => s['name']), ['ソニーグループ', 'ソニー銀行']);
    });
  });

  group('pipeline', () {
    test('extract facts keeps only cited paragraphs', () {
      final (facts, sources) = pipeline.extractFacts(researchBlocks);
      expect(facts.map((f) => f['claim']), ['品川宿は東海道五十三次の最初の宿場である。', '日本橋を出て最初の宿場だった。']);
      expect(sources.length, 1);
      expect(sources.first['url'], url);
      expect(facts.every((f) => (f['source_ids'] as List).length == 1 && (f['source_ids'] as List).first == 1), isTrue);
    });

    test('web fetch char location', () {
      final (facts, sources) = pipeline.extractFacts([
        {
          'type': 'web_fetch_tool_result',
          'content': {'type': 'web_fetch_result', 'url': url, 'content': {'type': 'document', 'title': '品川宿'}},
        },
        {
          'type': 'text',
          'text': '品川宿は宿場町として栄えた場所である。',
          'citations': [
            {'type': 'char_location', 'cited_text': '宿場町として栄えた', 'document_index': 0, 'document_title': '品川宿'},
          ],
        },
      ]);
      expect(facts.length, 1);
      expect(sources.first['url'], url);
    });

    test('NO_SOURCES gives no facts', () {
      expect(pipeline.extractFacts([{'type': 'text', 'text': 'NO_SOURCES'}]).$1, isEmpty);
    });

    test('build lines rules', () {
      final (facts, _) = pipeline.extractFacts(researchBlocks);
      final raw = [
        {'speaker': 'ootori', 'text': '{{CODENAME}}、聞こえるか。', 'fact_ids': [1]},
        {'speaker': 'shiori', 'text': 'ここは最初の宿場なの。', 'fact_ids': [1]},
        {'speaker': 'shiori', 'text': 'あっちにも古い寺があるから行ってみて。', 'fact_ids': []},
      ];
      final lines = pipeline.buildLines(raw, facts, 'shiori', null);
      expect(lines.first['source_ids'], isEmpty); // commander never carries facts
      expect(lines.any((l) => (l['text'] as String).contains('行ってみ')), isFalse); // nudge guard
      final check = {
        'results': [for (var i = 0; i < raw.length; i++) {'index': i, 'supported': i != 1, 'nudge': false}],
      };
      expect(pipeline.buildLines(raw, facts, 'shiori', check).any((l) => (l['text'] as String).contains('宿場なの')), isFalse);
    });

    test('a line that makes light of a tragedy is never shipped, and the rewrite is told why', () {
      final (facts, _) = pipeline.extractFacts(researchBlocks);
      final raw = [
        {'speaker': 'ootori', 'text': '{{CODENAME}}、聞こえるか。', 'fact_ids': []},
        {'speaker': 'shiori', 'text': 'ここは最初の宿場なの。', 'fact_ids': [1]},
        {'speaker': 'ootori', 'text': '大火か。焼き芋を思い出すな。', 'fact_ids': []},
      ];
      final check = {
        'results': [
          for (var i = 0; i < raw.length; i++) {'index': i, 'supported': true, 'nudge': false, 'tasteless': i == 2, 'commander_fact': false},
        ],
      };
      expect(pipeline.buildLines(raw, facts, 'shiori', check).map((l) => l['text']), isNot(contains('大火か。焼き芋を思い出すな。')));
      expect(pipeline.checkIssues(raw, check).single, contains('不謹慎'));
    });

    test('a revisit line that retells what was said there before is dropped, and the rewrite is told why', () {
      final (facts, _) = pipeline.extractFacts(researchBlocks);
      final raw = [
        {'speaker': 'ootori', 'text': '{{CODENAME}}、聞こえるか。', 'fact_ids': []},
        {'speaker': 'shiori', 'text': 'ここでは水道管が破裂したことがあるのじゃ。', 'fact_ids': [1]},
      ];
      final check = {
        'results': [
          for (var i = 0; i < raw.length; i++)
            {'index': i, 'supported': true, 'nudge': false, 'tasteless': false, 'commander_fact': false, 'repeat': i == 1},
        ],
      };
      expect(pipeline.buildLines(raw, facts, 'shiori', check).map((l) => l['speaker']), ['ootori']);
      expect(pipeline.checkIssues(raw, check).single, contains('前回'));
      // The check sees what was told before (only on a revisit).
      expect(prompts.checkUser(facts, raw, told: ['水道管が破裂した']), contains('- 水道管が破裂した'));
      expect(prompts.checkUser(facts, raw), isNot(contains('前回')));
    });

    test('told before: specialist lines only, the latest kept when there are many', () {
      Json d(String tag, int n) => {
            'lines': [
              for (var i = 0; i < n; i++) ...[
                {'speaker': 'ootori', 'text': 'へえ'},
                {'speaker': 'shiori', 'text': '$tag$i'},
              ],
            ],
          };
      expect(pipeline.toldBefore([d('a', 2)]), ['a0', 'a1']);
      final told = pipeline.toldBefore([d('a', 20), d('b', 10)]);
      expect(told, hasLength(24));
      expect(told.last, 'b9'); // the latest conversation is never cut off
    });

    test('generate, check_failed and insufficient_sources', () async {
      final f = FakeClaude();
      final d = await pipeline.generate(fakeLlm(f, config: const EngineConfig(escalateResearchModel: '')), shrine(), 'history');
      expect((d['specialist'] as Map)['id'], 'shiori');
      expect((d['commander'] as Map)['frequency'], '147.20');
      expect((d['lines'] as List).cast<Json>().where((l) => l['speaker'] == 'shiori').every((l) => (l['source_ids'] as List).isNotEmpty), isTrue);
      expect((d['sources'] as List).map((s) => (s as Map)['id']).toSet(), {1});
      expect((d['review'] as Map)['pattern'], isNotNull);
      // the request carried the web tools and the dialogue schema with patterns
      final research = f.requests.first;
      expect((research['tools'] as List).map((t) => (t as Map)['name']), ['web_search', 'web_fetch']);
      expect(research.containsKey('fallbacks'), isFalse); // Haiku: no server-side fallback
      final dialogueReq = f.requests.firstWhere((r) => r['tools'] == null && r['system'] != texts.checkSystem);
      expect(dialogueReq['fallbacks'], 'default'); // Sonnet: fallback on
      await expectLater(
          pipeline.generate(fakeLlm(FakeClaude(unsupported: {1, 3}), config: const EngineConfig(escalateResearchModel: '')),
              shrine(), 'history'),
          throwsA(isA<Unavailable>().having((e) => e.reason, 'reason', 'check_failed')));
      await expectLater(
          pipeline.generate(
              fakeLlm(FakeClaude(blocks: [{'type': 'text', 'text': 'NO_SOURCES'}]), config: const EngineConfig(escalateResearchModel: '')),
              shrine(),
              'history'),
          throwsA(isA<Unavailable>().having((e) => e.reason, 'reason', 'insufficient_sources')));
    });

    test('escalates when the cheap model finds few facts', () async {
      final f = FakeClaude(blocks: factsBlocks(2), strong: factsBlocks(6));
      final d = await pipeline.generate(fakeLlm(f), shrine(), 'history');
      expect(f.researchModels, ['claude-haiku-5-5', 'claude-sonnet-5-5']);
      expect((d['review'] as Map)['escalated'], isTrue);
    });

    test('escalates when the score stays low and keeps the better one', () async {
      final f = FakeClaude(blocks: factsBlocks(5), strong: factsBlocks(6), reviewScores: [2, 2, 5]);
      final d = await pipeline.generate(fakeLlm(f), shrine(), 'history');
      expect(f.researchModels, ['claude-haiku-5-5', 'claude-sonnet-5-5']);
      expect((d['review'] as Map)['score'] as num, greaterThan(4));
    });

    test('no escalation when good or disabled', () async {
      var f = FakeClaude(blocks: factsBlocks(5), strong: factsBlocks(6), reviewScores: [5]);
      await pipeline.generate(fakeLlm(f), shrine(), 'history');
      expect(f.researchModels, ['claude-haiku-5-5']);
      f = FakeClaude(blocks: factsBlocks(2), strong: factsBlocks(6), reviewScores: [2]);
      await pipeline.generate(fakeLlm(f, config: const EngineConfig(escalateResearchModel: '')), shrine(), 'history');
      expect(f.researchModels, ['claude-haiku-5-5']);
    });

    test('low review triggers one rewrite with feedback', () async {
      final f = FakeClaude(reviewScores: [2, 5]);
      final d = await pipeline.generate(fakeLlm(f, config: const EngineConfig(escalateResearchModel: '')), shrine(), 'history');
      expect(f.dialoguePrompts.length, 2);
      expect(f.dialoguePrompts[1], contains('つかみが弱い'));
      expect((d['review'] as Map)['attempt'], 2);
    });

    test('commander fact is rewritten, not silently deleted', () async {
      final f = FakeClaude(reviewScores: [5])..commanderFact = (n) => n == 1 ? {2} : {};
      final d = await pipeline.generate(fakeLlm(f, config: const EngineConfig(escalateResearchModel: '')), shrine(), 'history');
      expect(f.dialoguePrompts.length, 2);
      expect(f.dialoguePrompts[1], contains('3行目の司令'));
      expect((d['review'] as Map)['attempt'], 2);
      expect((d['review'] as Map)['removed_lines'], 0);
    });

    test('unrestricted domains omit the filter', () {
      expect(pipeline.researchTools(const EngineConfig()).any((t) => t.containsKey('allowed_domains')), isFalse);
      expect(pipeline.researchTools(const EngineConfig(allowedDomains: restrictedDomains)).first['allowed_domains'],
          restrictedDomains);
    });

    test('codename substitution', () {
      final d = pipeline.withCodename({
        'lines': [
          {'speaker': 'ootori', 'text': '{{CODENAME}}、聞こえるか。'},
        ],
      }, 'ハヤテ');
      expect(((d['lines'] as List).first as Map)['text'], 'ハヤテ、聞こえるか。');
    });
  });

  group('prompts', () {
    test('only the Sphinx poses riddles, and only now and then', () {
      final rng = Random(7);
      var riddles = 0;
      for (var i = 0; i < 400; i++) {
        final sphinx = pipeline.pickPatterns(specialists['architecture']!, rng);
        expect(sphinx.toSet(), hasLength(texts.patternChoices));
        if (sphinx.contains('quiz')) riddles++;
        for (final theme in ['history', 'placename', 'food']) {
          expect(pipeline.pickPatterns(specialists[theme]!, rng), isNot(contains('quiz')), reason: theme);
        }
      }
      expect(riddles, inInclusiveRange(60, 140)); // about a quarter of 400
    });

    test('the Fox speaks Kyoto-style and never quizzes; the Cat no longer says はん', () {
      final fox = specialists['placename']!.persona, cat = specialists['food']!.persona;
      expect(fox, allOf(contains('京言葉'), contains('司令はん'), contains('問題やクイズは出さない')));
      expect(fox, isNot(contains('さて問題')));
      expect(cat, allOf(contains('あたし'), contains('シレイさん')));
      expect(cat, isNot(contains('はん')));
      expect(specialists['architecture']!.persona, contains('謎かけ'));
    });

    test('placeholders are all filled and theme rules applied', () {
      final picked = pipeline.pickPatterns(specialists['food']!, Random(1));
      expect(picked.length, texts.patternChoices);
      final t = prompts.dialogueSystem(specialists['food']!, patternIds: picked);
      expect(RegExp(r'__[A-Z_]+__').hasMatch(t), isFalse);
      expect(t.contains('{sp}') || t.contains('{c}') || t.contains('{cn}'), isFalse);
      expect(t, contains('ネコ'));
      expect(t, contains('シレイ（speaker: "ootori"）')); // the commander comes from characters.dart
      expect(t, contains('飲酒・購入・来店をすすめない'));
      for (final id in picked) {
        expect(t, contains(texts.patterns[id]!.name));
      }
      expect(prompts.dialogueSystem(specialists['history']!), isNot(contains('飲酒')));
      expect(prompts.dialogueSchema('kagura', picked)['properties']['pattern']['enum'], picked);
      expect(prompts.researchUser({'name': 'x坂', 'lat': 0, 'lon': 0, 'kind': 'slope', '_tags': {}}, 'placename', null),
          contains('説がある'));
      expect(prompts.researchUser({'name': '北品川', 'lat': 0, 'lon': 0, 'kind': 'area', '_tags': {'city': '品川区'}}, 'history', 'u'),
          allOf(contains('町: 品川区 北品川'), contains('まずこのページを取得して読む: u')));
    });

    test('review rules and prompt', () {
      final lines = [
        {'speaker': 'shiori', 'text': 'あ'},
        {'speaker': 'shiori', 'text': 'い？'},
        {'speaker': 'shiori', 'text': '通信終了'},
      ];
      final issues = review.ruleIssues(lines, 'シオリ');
      expect(issues.join(), allOf(contains('セリフ数'), contains('最初に司令'), contains('2回続けて'), contains('決まり文句')));
      final text = review.reviewUser([{'speaker': 'ootori', 'text': '聞こえるか'}], {'ootori': 'オオトリ', 'rei': 'レイ'}, pattern: 'report');
      expect(text, allOf(contains('オオトリ は司令'), contains('レイ は事実を話す担当'), contains('調査報告')));
      expect(text, isNot(contains('{sp}')));
    });
  });

  group('discover', () {
    test('pick result skips shops and requires the exact name', () {
      final hit = discover.pickPhoton('ソニーシティ', photon['ソニーシティ']!)!;
      expect([hit['osm_type'], hit['osm_id'], hit['lat'], hit['type']], ['way', 34288649, 35.6311191, 'commercial']);
      expect(discover.pickPhoton('ソニー', photon['ソニーシティ']!), isNull);
    });

    test('the place, not the stop position that shares its name; an area before a point', () {
      final features = [
        photonFeature('N', 1, 35.70, 139.75, 'railway', 'stop', '水道橋'),
        photonFeature('N', 2, 35.70, 139.75, 'historic', 'memorial', '水道橋'),
        photonFeature('W', 3, 35.70, 139.75, 'man_made', 'bridge', '水道橋'),
      ];
      expect(discover.pickPhoton('水道橋', features)!['osm_id'], 3);
      expect(discover.pickPhoton('水道橋', features.take(1).toList())!['osm_id'], 1); // still better than nothing
    });

    test('Overpass by name: any name tag, place tags only (tourism=yes is not a shop)', () {
      final elements = <Json>[
        {'type': 'way', 'id': 1, 'center': {'lat': 35.71, 'lon': 139.75}, 'tags': {'name': '旧伊勢屋質店', 'building': 'yes', 'tourism': 'yes'}},
        {'type': 'node', 'id': 2, 'lat': 35.71, 'lon': 139.75, 'tags': {'name': '旧伊勢屋質店', 'shop': 'pawnbroker'}},
        {'type': 'way', 'id': 3, 'center': {'lat': 35.70, 'lon': 139.76}, 'tags': {'name': 'Ochanomizu', 'name:ja': 'お茶の水 橋', 'man_made': 'bridge'}},
      ];
      final hit = discover.pickOverpass('旧伊勢屋質店', elements)!;
      expect([hit['osm_type'], hit['osm_id'], hit['lat'], hit['type']], ['way', 1, 35.71, 'yes']);
      expect(discover.pickOverpass('お茶の水橋', elements)!['osm_id'], 3); // spaces don't count
      final paris = [
        photonFeature('N', 1, 48.857, 2.352, 'railway', 'station', 'Hôtel de Ville'),
        photonFeature('R', 2, 48.856, 2.352, 'amenity', 'townhall', 'Hôtel de ville'),
      ];
      expect(discover.pickPhoton('Hôtel de Ville', paris)!['osm_id'], 2); // the town hall, though its case differs
      expect(discover.pickPhoton('Hotel de Ville', paris), isNull); // accents still count
      final q = overpass.buildNamesQuery(['お茶の水・橋', 'Nelson"s (Column)'], 35.7, 139.76, 0.02);
      expect(q, allOf(contains('お茶の水・橋|お茶の水橋'), contains(r'Nelson\"s \\(Column\\)'), contains('name:ja')));
    });

    test('Photon down: the rest of the names go to Overpass in one query', () async {
      var photonCalls = 0, overpassCalls = 0;
      final finder = discover.PlaceFinder(
          MockClient((r) async {
            final u = r.url.toString();
            if (u.contains('photon')) {
              photonCalls++;
              return photonCalls == 1
                  ? _json({'features': [photonFeature('W', 9, 35.62, 139.74, 'amenity', 'place_of_worship', '品川神社')]})
                  : http.Response('down', 502);
            }
            overpassCalls++;
            return _json({
              'elements': [
                {'type': 'way', 'id': 2001, 'center': {'lat': 35.623, 'lon': 139.741}, 'tags': {'name': '八ツ山橋', 'man_made': 'bridge'}},
              ],
            });
          }),
          'test',
          minInterval: Duration.zero);
      final hits = await finder.findAll(['品川神社', '八ツ山橋', '架空タワー'], 35.62, 139.74);
      expect([hits['品川神社']!['osm_id'], hits['八ツ山橋']!['osm_id'], hits['架空タワー']], [9, 2001, null]);
      expect([photonCalls, overpassCalls], [2, 1]);
    });

    test('duplicates by nearby similar name', () {
      final existing = [
        {'name': '北品川駅', 'lat': 35.6226, 'lon': 139.7389},
      ];
      expect(discover.duplicates('北品川', 35.6227, 139.7390, existing), isTrue);
      expect(discover.duplicates('北品川', 35.70, 139.7390, existing), isFalse);
    });
  });

  group('cost', () {
    test('claude cost', () {
      expect(claudeCost('claude-haiku-5-5', 50000, 0, 0, 0, 0), closeTo(0.005, 1e-9));
      expect(claudeCost('claude-sonnet-5-5', 0, 1000000, 0, 0, 2), closeTo(10.02, 1e-9));
      expect(claudeCost('claude-haiku-5-5', 200000, 0, 0, 0, 0), closeTo(0.10, 1e-9)); // long-prompt price
      expect(claudeCost('unknown', 1, 1, 0, 0, 0), isNull);
    });
  });

  group('engine', () {
    test('spots merge Wikipedia with OSM', () async {
      final e = await makeEngine(null);
      final spots = await e.spots(35.6226, 139.7389);
      final by = {for (final s in spots) s['name']: s};
      expect(by['品川インターシティ']!['themes'], ['architecture']); // the OSM one, enriched
      expect(by['天王洲運河']!['themes'], ['architecture', 'history']); // a canal: civil engineering
      expect(by.containsKey('すき家') || by.containsKey('楽天Edy'), isFalse);
      expect(by['NTT品川TWINS']!['themes'], ['film']); // found by the film search
      expect(by['ソニーグループ']!['kind'], 'company');
      expect(by['ソニーグループ']!['themes'], ['tech']);
      expect(spots.where((s) => s['name'] == '品川神社').length, 1);
      expect(spots.every((s) => !s.keys.any((k) => k.startsWith('_'))), isTrue);
    });

    test('dialogue flow, cache, codename and errors', () async {
      final f = FakeClaude();
      final e = await makeEngine(f);
      expect(e.health()['llm'], isTrue);
      final spots = await e.spots(35.6226, 139.7389);
      final s = spots.firstWhere((x) => x['name'] == '品川神社');
      expect(e.dialogue(s['id'] as String, ['history'], 'ハヤテ')['status'], 'pending');
      final r = await waitReady(e, s['id'] as String, ['history'], codename: 'ハヤテ');
      expect(r['status'], 'ready');
      expect((((r['dialogue'] as Map)['lines'] as List).first as Map)['text'], startsWith('ハヤテ、'));
      final r2 = e.dialogue(s['id'] as String, ['history'], 'ウォーカー');
      expect((((r2['dialogue'] as Map)['lines'] as List).first as Map)['text'], startsWith('ウォーカー、'));
      expect(f.researchCalls, 1);
      expect(e.dialogue(s['id'] as String, ['architecture'], 'x'), {'status': 'unavailable', 'reason': 'theme_mismatch'});
      expect(e.dialogue('osm:node:0', ['history'], 'x')['reason'], 'unknown_spot');
      final bridge = spots.firstWhere((x) => x['name'] == '八ツ山橋');
      expect(e.prefetch([bridge['id'] as String], ['architecture']), 1);
      await e.idle();
    });

    test('each generation reports its outcome, cost per step and research yield (the walk log)', () async {
      Future<Json> generationEvent(FakeClaude f) async {
        final events = <Json>[];
        final e = Engine(
          store: await openStore(null),
          apiKey: 'x',
          config: const EngineConfig(escalateResearchModel: ''),
          userAgent: 'test',
          client: fakeHttp(f),
          log: (_) {},
          onEvent: events.add,
        );
        final spots = await e.spots(35.6226, 139.7389);
        await waitReady(e, spots.firstWhere((x) => x['name'] == '品川神社')['id'] as String, ['history']);
        await e.idle();
        return events.singleWhere((x) => x['type'] == 'generation');
      }

      final ready = await generationEvent(FakeClaude());
      expect(ready['outcome'], 'ready');
      expect(ready['generated_at'], isA<String>());
      expect(ready['prefetch'], isFalse);
      final steps = ((ready['usage'] as Map)['steps'] as List).cast<Json>();
      expect(steps.map((s) => s['step']), containsAllInOrder(['research', 'dialogue', 'check', 'review']));
      expect(steps.first['facts'], 2);
      expect(steps.first, containsPair('cache_read', 0));
      expect(steps.first['ms'], isA<int>());
      expect(steps.first['stop_reason'], 'end_turn');

      final none = await generationEvent(FakeClaude(blocks: factsBlocks(1)));
      expect(none, containsPair('reason', 'insufficient_sources'));
      expect((((none['usage'] as Map)['steps'] as List).single as Map)['facts'], 1);
    });

    test('a key that checks out clears earlier bad_key failures', () async {
      final e = await makeEngine(FakeClaude());
      final spots = await e.spots(35.6226, 139.7389);
      final id = spots.firstWhere((x) => x['name'] == '品川神社')['id'] as String;
      e.store.putDialogue(id, 'history', 'error', reason: 'bad_key');
      e.store.putDialogue('osm:node:1', 'history', 'error', reason: 'api_error');
      expect(e.dialogue(id, ['history'], 'x'), {'status': 'unavailable', 'reason': 'bad_key'});
      await e.checkKey();
      expect(e.store.getDialogue(id, 'history'), isNull);
      expect(e.store.getDialogue('osm:node:1', 'history'), isNotNull); // other failures keep their TTL
      expect(e.dialogue(id, ['history'], 'x')['status'], 'pending');
      await e.idle();
    });

    test('spots from Wikipedia alone are askable when Overpass is down', () async {
      final e = Engine(
        store: await openStore(null),
        apiKey: 'x',
        config: const EngineConfig(escalateResearchModel: ''),
        userAgent: 'test',
        client: fakeHttp(FakeClaude(), overpassDown: true),
        log: (_) {},
      );
      final spots = await e.spots(35.6226, 139.7389);
      final shrine = spots.firstWhere((x) => x['name'] == '品川神社');
      expect((await waitReady(e, shrine['id'] as String, ['history']))['status'], 'ready');
    });

    test('without key', () async {
      final e = await makeEngine(null);
      expect(e.health()['llm'], isFalse);
      final s = (await e.spots(35.6226, 139.7389)).first;
      expect(e.dialogue(s['id'] as String, (s['themes'] as List).cast<String>(), 'x'),
          {'status': 'unavailable', 'reason': 'no_api_key'});
    });

    test('negative cache', () async {
      final f = FakeClaude(blocks: [{'type': 'text', 'text': 'NO_SOURCES'}]);
      final e = await makeEngine(f);
      final s = (await e.spots(35.6226, 139.7389)).first;
      final themes = (s['themes'] as List).cast<String>();
      e.dialogue(s['id'] as String, themes, 'x');
      expect(await waitReady(e, s['id'] as String, themes), {'status': 'unavailable', 'reason': 'insufficient_sources'});
      e.dialogue(s['id'] as String, themes, 'x');
      expect(f.researchCalls, 1);
    });

    test('best dialogue picks the highest review and reports skips', () async {
      final f = FakeClaude(reviewScores: [5, 3, 3]);
      final e = await makeEngine(f);
      final spots = {for (final x in await e.spots(35.6226, 139.7389)) x['name']: x};
      final a = spots['品川神社']!['id'] as String, b = spots['土蔵相模跡']!['id'] as String;
      const themes = ['history'];
      expect(e.bestDialogue([a, b, 'osm:node:0'], themes, 'x')['status'], 'pending');
      await e.idle();
      final r = e.bestDialogue([b, a, 'osm:node:0'], themes, 'x');
      expect(r['status'], 'ready');
      expect(r['skip'], ['osm:node:0']);
      expect(((r['dialogue'] as Map)['review'] as Map)['score'] as num, greaterThanOrEqualTo(3));
    });

    test('area triggers discovery; spots include confirmed landmarks', () async {
      final f = FakeClaude();
      final e = await makeEngine(f);
      await e.spots(35.6226, 139.7389); // OSM spots known first (八ツ山橋 is one)
      final town = await e.area(35.6226, 139.7389);
      expect(town!['name'], '北品川');
      expect(town['kind'], 'area');
      await e.idle();
      final names = (await e.spots(35.6300, 139.7420, radius: 1000)).map((s) => s['name']).toList();
      expect(names, contains('ソニーシティ'));
      expect(names.where((n) => n == '八ツ山橋').length, 1);
      expect(names, isNot(contains('架空タワー')));
      expect(names, isNot(contains('北品川'))); // the town itself is not a landmark
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('live request jumps ahead of the prefetch queue', () async {
      final f = FakeClaude()..delay = const Duration(milliseconds: 150);
      final e = await makeEngine(f);
      final spots = {for (final x in await e.spots(35.6226, 139.7389)) x['name']: x};
      final ids = [for (final n in ['品川神社', '八ツ山橋', '御殿山坂', '目黒川']) spots[n]!['id'] as String];
      const themes = ['history', 'architecture', 'nature'];
      expect(e.prefetch(ids, themes), 4);
      final sw = Stopwatch()..start();
      final r = await waitReady(e, ids.last, themes);
      expect(r['status'], 'ready');
      // one generation is ~5 calls x 150 ms; four in a row would be ~3 s
      expect(sw.elapsedMilliseconds, lessThan(1800));
      await e.idle();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a conversation cached before the cast was renamed is written again with today\'s names', () async {
      final e = await makeEngine(FakeClaude());
      final spot = shrine();
      e.store.putSpots([spot]);
      e.store.putDialogue(spot['id'] as String, 'history', 'ready', dialogue: {
        'spot': spot,
        'theme': 'history',
        'specialist': {'id': 'shiori', 'name': 'シオリ', 'frequency': '140.15'},
        'commander': {'id': 'ootori', 'name': 'オオトリ', 'frequency': '141.80'},
        'lines': [],
        'sources': [],
      });
      final r = await waitReady(e, spot['id'] as String, ['history']);
      expect(r['status'], 'ready');
      expect((r['dialogue'] as Map)['specialist']['name'], 'フクロウ');
      expect((r['dialogue'] as Map)['commander']['name'], 'シレイ');
      await e.idle();
    });

    test('deleting the cache forgets spots and conversations, on disk too', () async {
      final dir = await Directory.systemTemp.createTemp('cw');
      final path = '${dir.path}/cache.json';
      final s1 = await openStore(path);
      s1.putArea('k', [
        {'id': 'osm:node:1', 'name': 'x', 'lat': 0, 'lon': 0, 'themes': ['history']},
      ]);
      s1.putDialogue('osm:node:1', 'history', 'ready', dialogue: {'theme': 'history'});
      final e = Engine(store: s1, apiKey: null, userAgent: 'test', client: fakeHttp(FakeClaude()), log: (_) {});
      await e.clearCache();
      expect([s1.getSpot('osm:node:1'), s1.getDialogue('osm:node:1', 'history'), s1.dialogueCount], [null, null, 0]);
      final s2 = await openStore(path);
      expect([s2.getArea('k', 100), s2.dialogueCount], [null, 0]);
      await dir.delete(recursive: true);
    });

    test('store survives a reopen', () async {
      final dir = await Directory.systemTemp.createTemp('cw');
      final path = '${dir.path}/cache.json';
      final s1 = await openStore(path);
      s1.putArea('k', [
        {'id': 'osm:node:1', 'name': 'x', 'lat': 0, 'lon': 0, 'themes': ['history']},
      ]);
      s1.putDialogue('osm:node:1', 'history', 'unavailable', reason: 'insufficient_sources');
      await s1.flush();
      final s2 = await openStore(path);
      expect(s2.getArea('k', 100)!.single['name'], 'x');
      expect(s2.getDialogue('osm:node:1', 'history')!.$2, 'insufficient_sources');
      await dir.delete(recursive: true);
    });
  });

  group('film and chat', () {
    test('music counts for the monkey: live venues, concert halls, record labels; works get introduced', () {
      expect(overpass.classify({'name': '〇〇ライブハウス', 'amenity': 'music_venue'}).$1, ['film']);
      expect(wikipedia.classify(['concert hall'], '〇〇ホール')!.$1, contains('film'));
      expect(wikipedia.classify(['business'], '〇〇レコード', sitelinks: 5)!.$1, contains('film'));
      expect(texts.themeRules['film'], allOf(contains('音楽'), contains('何が魅力か'), contains('ネタバレ')));
      expect(prompts.dialogueSystem(specialists['film']!), contains('どこが魅力なのか'));
    });

    test('film search keeps place articles, never incidents or products', () {
      expect(wikipedia.withFilm(null, ['bridge'], '聖橋')?.$1, ['film']);
      expect(wikipedia.withFilm((['history'], 'shrine'), ['Shinto shrine'], '神田明神')?.$1, ['history', 'film']);
      expect(wikipedia.withFilm(null, ['murder'], '秋葉原通り魔事件'), isNull);
      expect(wikipedia.withFilm(null, ['proximity card', 'product'], '楽天Edy'), isNull);
      expect(wikipedia.classify(['business'], '小学館', sitelinks: 10)!.$1, contains('film'));
    });

    test('chat spot: one per day, any specialist, researched from that date page, not a place', () async {
      final e = await makeEngine(FakeClaude());
      final s = e.chatSpot(35.62, 139.74, DateTime(2026, 10, 14, 9));
      expect(s['id'], 'chat:2026-10-14');
      expect(s['kind'], 'chat');
      expect(s['themes'], allThemes); // any specialist can tell it
      expect(wikipediaUrl(s['wikipedia'] as String?), 'https://ja.wikipedia.org/wiki/10月14日');
      expect(e.chatSpot(35.70, 139.70, DateTime(2026, 10, 14, 18))['lat'], 35.62); // same day: same call
      final full = {...s, '_tags': {'date': '10月14日'}};
      final research = prompts.researchUser(full, 'film', wikipediaUrl(s['wikipedia'] as String?));
      expect(research, allOf(contains('今日（10月14日）は何の日'), contains('https://ja.wikipedia.org/wiki/10月14日')));
      expect(prompts.dialogueUser(full, []), contains('場所の名前を出さず'));
      // each specialist has its own angle on the date
      expect(prompts.researchUser(full, 'food', null), contains('食べ物・飲み物の記念日'));
      expect(prompts.researchUser(full, 'history', null), contains('歴史上の出来事'));
      for (final t in allThemes) {
        expect(prompts.chatFocus.containsKey(t), isTrue, reason: t);
      }
      // and it can be asked for like any spot
      expect(e.dialogue(s['id'] as String, ['film'], 'x')['status'], 'pending');
      await e.idle();
      expect(e.dialogue(s['id'] as String, ['film'], 'x')['status'], 'ready');
    });
  });

  group('revisits', () {
    test('a revisit is a new conversation: another specialist first, told what was said before', () async {
      final f = FakeClaude();
      final e = await makeEngine(f);
      final by = {for (final x in await e.spots(35.6226, 139.7389)) x['name']: x};
      final bridge = by['八ツ山橋']!['id'] as String; // architecture, infrastructure, placename
      const themes = ['architecture', 'placename'];
      e.dialogue(bridge, themes, 'x');
      await e.idle();
      final r0 = e.dialogue(bridge, themes, 'x');
      expect(r0['status'], 'ready', reason: '$r0');
      final first = r0['dialogue'] as Map;
      expect(first['theme'], 'architecture');

      expect(e.dialogue(bridge, themes, 'x', round: 1)['status'], 'pending'); // not the cached one
      await e.idle();
      final r1 = e.dialogue(bridge, themes, 'x', round: 1);
      expect(r1['status'], 'ready', reason: '$r1');
      final second = r1['dialogue'] as Map;
      expect(second['theme'], 'placename'); // someone who hasn't spoken here yet
      final research = f.requests.where((r) => r['tools'] != null).last;
      final user = ((research['messages'] as List).first as Map)['content'] as String;
      expect(user, contains('前回までにこの場所で話した内容'));
      expect(user, contains('最初の宿場')); // a line the first conversation told
      expect(f.dialoguePrompts.last, contains('同じ話はしない'));
      // round 0 is still the first conversation (cached)
      expect((e.dialogue(bridge, themes, 'x')['dialogue'] as Map)['theme'], 'architecture');
    });

    test('a place with one specialist gets the same one again, with a new conversation', () async {
      final f = FakeClaude();
      final e = await makeEngine(f);
      final shrine = (await e.spots(35.6226, 139.7389)).firstWhere((x) => x['name'] == '品川神社')['id'] as String;
      e.dialogue(shrine, ['history'], 'x');
      await e.idle();
      e.dialogue(shrine, ['history'], 'x', round: 1);
      await e.idle();
      expect((e.dialogue(shrine, ['history'], 'x', round: 1)['dialogue'] as Map)['theme'], 'history');
      expect(f.researchCalls, 2);
      expect(pipeline.toldBefore([for (final (_, d) in e.store.readyDialoguesFor(shrine)) d]).every((t) => !t.contains('{{CODENAME}}')), isTrue);
    });
  });

  group('english', () {
    test('English dialogues: English names, speech styles and output language; separate cache', () async {
      final t = prompts.dialogueSystem(specialists['film']!, lang: 'en');
      expect(t, allOf(contains('Monkey'), contains('Ook'), contains('Commander'), contains('出力言語: 英語')));
      expect(t, isNot(contains('サル（speaker')));
      expect(prompts.dialogueSystem(specialists['film']!), isNot(contains('出力言語: 英語')));
      expect(prompts.dialogueUser({'name': '品川神社', 'name_en': 'Shinagawa Shrine'}, [], lang: 'en'),
          allOf(contains('英語名: Shinagawa Shrine'), contains('English')));
      expect(overpass.parseElements({
        'elements': [
          {'type': 'node', 'id': 1, 'lat': 35.6, 'lon': 139.7, 'tags': {'name': '品川神社', 'name:en': 'Shinagawa Shrine', 'amenity': 'place_of_worship', 'religion': 'shinto'}},
        ],
      }).single['name_en'], 'Shinagawa Shrine');

      final f = FakeClaude();
      final e = await makeEngine(f);
      final shrine = (await e.spots(35.6226, 139.7389)).firstWhere((x) => x['name'] == '品川神社')['id'] as String;
      e.dialogue(shrine, ['history'], 'x');
      await e.idle();
      expect(e.dialogue(shrine, ['history'], 'x', lang: 'en')['status'], 'pending'); // its own conversation
      await e.idle();
      final en = e.dialogue(shrine, ['history'], '', lang: 'en')['dialogue'] as Map;
      expect((en['specialist'] as Map)['name'], 'Owl');
      expect((en['commander'] as Map)['name'], 'Commander');
      expect(en['lang'], 'en');
      expect(((en['lines'] as List).first as Map)['text'], startsWith('Walker')); // default codename in English
      expect(((e.dialogue(shrine, ['history'], 'x')['dialogue'] as Map)['specialist'] as Map)['name'], 'フクロウ');
      expect(review.ruleIssues([for (var i = 0; i < 6; i++) {'speaker': i.isEven ? 'ootori' : 'shiori', 'text': 'a' * 100}], 'Owl', lang: 'en'),
          isEmpty); // ~20 English words is fine
    });
  });
}
