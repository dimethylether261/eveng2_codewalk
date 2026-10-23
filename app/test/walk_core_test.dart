import 'dart:convert';

import 'package:codewalk/log_book.dart';
import 'package:codewalk/models.dart';
import 'package:codewalk/standalone/walk_core.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHost implements CoreHost {
  final saved = <String, String>{};
  int changes = 0;
  double spent = 0;

  @override
  void changed() => changes++;

  @override
  Future<void> save(String key, String value) async => saved[key] = value;

  @override
  void spend(double usd) => spent += usd;

  @override
  void debug(String message) {}
}

Dialogue dialogue({String spot = 'osm:node:1', String? image}) => Dialogue.fromJson({
      'spot': {'id': spot, 'name': '品川神社', 'lat': 35.6197, 'lon': 139.7426},
      'theme': 'history',
      'specialist': {'id': 'shiori', 'name': 'フクロウ', 'frequency': '146.35'},
      'commander': {'id': 'ootori', 'name': 'シレイ', 'frequency': '147.20'},
      'lines': [
        {'speaker': 'ootori', 'text': '聞こえるか。', 'source_ids': []},
        {'speaker': 'shiori', 'text': '鳥居に龍がいるのじゃ。', 'source_ids': [1]},
      ],
      'sources': [
        {'id': 1, 'title': '品川神社 - Wikipedia', 'url': 'https://ja.wikipedia.org/wiki/品川神社', 'quote': ''},
      ],
      if (image != null) 'image': {'url': image, 'license': 'CC BY-SA 4.0', 'author': 'Someone', 'source_url': ''},
    });

WalkCore core(FakeHost host, {String? log, Map<String, dynamic> settings = const {}}) =>
    WalkCore(host, storeJson: null, logJson: log, settings: CoreSettings.fromJson(settings));

void main() {
  test('settings from the phone page: unknown values fall back, never an empty topic list', () {
    final s = CoreSettings.fromJson({'lang': 'en', 'themes': ['infrastructure'], 'frequency': 'often', 'codename': ' '});
    expect(s.lang, 'en');
    expect(s.themes, defaultThemes);
    expect(s.frequency, CallFrequency.normal);
    expect(s.codename, 'Walker');
    expect(CoreSettings.fromJson({'themes': ['film', 'food'], 'pinRange': 'week'}).themes, ['film', 'food']);
    expect(CoreSettings.fromJson({}).pinRange, LogRange.today);
  });

  test('answering a call logs it as played and plays it; the glasses state follows the gestures', () async {
    final host = FakeHost();
    final c = core(host);
    c.incoming = dialogue(image: 'https://upload.wikimedia.org/a.jpg');
    var state = c.g2State();
    expect((state['incoming'] as Map)['spot'], '品川神社');

    await c.command('answer');
    expect(c.incoming, isNull);
    expect(c.log.entries.single.played, isTrue);
    expect(jsonDecode(host.saved['log']!) as List, hasLength(1)); // saved to the Even Hub storage
    state = c.g2State();
    final call = state['call'] as Map;
    expect(call['index'], 0);
    expect((call['lines'] as List).first, {'id': 'ootori', 'who': 'シレイ', 'text': '聞こえるか。'});
    expect((call['photo'] as Map)['url'], 'https://upload.wikimedia.org/a.jpg'); // the glasses fetch it themselves

    await c.command('next');
    expect((c.g2State()['call'] as Map)['index'], 1);
    await c.command('next');
    expect((c.g2State()['call'] as Map)['finished'], isTrue);
    await c.command('end');
    expect(c.g2State()['call'], isNull);
  });

  test('"later" keeps the call unplayed; replay from the phone page plays it and marks it played', () async {
    final host = FakeHost();
    final c = core(host);
    c.incoming = dialogue();
    await c.command('later');
    final e = c.log.entries.single;
    expect(e.played, isFalse);
    expect(c.status, isNotEmpty); // "saved to the log"

    await c.replay(e.id);
    expect(c.session.active, isTrue);
    expect(e.played, isTrue);
    expect(c.logList().single['played'], isTrue);
  });

  test('the log survives a restart (and a broken log starts over)', () async {
    final host = FakeHost();
    final c = core(host);
    c.incoming = dialogue();
    await c.command('answer');
    final again = core(FakeHost(), log: host.saved['log']);
    expect(again.log.entries.single.dialogue.spotName, '品川神社');
    expect(again.log.heardCounts, {'osm:node:1': 1});
    expect(core(FakeHost(), log: '{broken').log.entries, isEmpty);
  });

  test('the phone page log: today, the last 7 days, or all of it, newest first', () {
    final c = core(FakeHost());
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    for (final (id, at) in [
      ('today', now),
      ('3 days', now.subtract(const Duration(days: 3))),
      ('10 days', now.subtract(const Duration(days: 10))),
    ]) {
      c.log.entries.add(LogEntry(id: id, receivedAt: at, played: true, dialogue: dialogue(), heardLat: 35.62, heardLon: 139.74));
    }
    List<Object?> ids(LogRange r) => [for (final e in c.logList(range: r)) e['id']];
    expect(ids(LogRange.today), now.isAfter(startOfToday.add(const Duration(seconds: 1))) ? ['today'] : anything);
    expect(ids(LogRange.week), ['today', '3 days']);
    expect(ids(LogRange.all), ['today', '3 days', '10 days']);
  });

  test('the phone page catalog lists every topic with its character, in the chosen language', () {
    final ja = core(FakeHost()).catalog();
    final themes = (ja['themes'] as List).cast<Map<String, dynamic>>();
    expect(themes.map((t) => t['id']), containsAll(['history', 'film', 'food']));
    expect(themes.firstWhere((t) => t['id'] == 'history')['name'], 'フクロウ');
    expect(themes.firstWhere((t) => t['id'] == 'food')['adult'], isTrue);
    final en = core(FakeHost(), settings: {'lang': 'en'}).catalog();
    expect(((en['themes'] as List).first as Map)['name'], 'Owl');
  });

  test('walking without a key says so instead of standing by', () {
    final c = core(FakeHost());
    c.start();
    expect(c.walking, isTrue);
    expect(c.status, contains('API'));
    c.stop();
  });

  test('a new key forgets the old key\'s bad_key failures (other failures stay)', () async {
    final host = FakeHost();
    final ts = DateTime.now().millisecondsSinceEpoch / 1000;
    final store = jsonEncode({
      'dialogues': {
        'osm:node:1|history': {'status': 'error', 'reason': 'bad_key', 'dialogue': null, 'ts': ts},
        'osm:node:2|history': {'status': 'error', 'reason': 'api_error', 'dialogue': null, 'ts': ts},
      },
    });
    final c = WalkCore(host, storeJson: store, logJson: null, settings: CoreSettings(apiKey: 'sk-old'));
    c.updateSettings(CoreSettings(apiKey: 'sk-new'));
    await c.flush();
    final dialogues = (jsonDecode(host.saved['store']!) as Map)['dialogues'] as Map;
    expect(dialogues.keys, ['osm:node:2|history']);
  });

  test('saved data: deleting the log and the cache (the phone page buttons)', () async {
    final host = FakeHost();
    final c = core(host);
    c.incoming = dialogue();
    await c.command('answer');
    await c.clearLog();
    expect(c.log.entries, isEmpty);
    expect(jsonDecode(host.saved['log']!), isEmpty);
    await c.clearCache();
    expect(c.cachedDialogues, 0);
    expect(host.saved['store'], isNotNull); // the emptied cache is saved too
  });

  test('a long press on the ring starts and ends the walk', () async {
    final c = core(FakeHost());
    await c.command('walk');
    expect(c.walking, isTrue);
    await c.command('walk');
    expect(c.walking, isFalse);
  });
}
