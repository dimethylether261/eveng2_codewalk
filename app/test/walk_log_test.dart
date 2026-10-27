import 'dart:convert';
import 'dart:io';

import 'package:codewalk/walk_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('walk_log_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('one JSON Lines file per walk; events after the walk ended still go to it', () async {
    final log = WalkLog(dir, () => true);
    log.event('pos', {'lat': 1}); // before any walk: dropped
    log.startWalk({'lang': 'ja'}, now: DateTime(2026, 10, 24, 9, 5, 7));
    log.event('pos', {'lat': 35.6, 'lon': 139.7});
    log.event('walk_end', {'walked_m': 120});
    log.event('generation', {'type': 'generation', 'outcome': 'ready'});
    final files = await log.files();
    expect(files.map((f) => f.uri.pathSegments.last), ['walk_20261024-090507.jsonl']);
    final lines = files.single.readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
    expect(lines.map((l) => l['type']), ['walk_start', 'pos', 'walk_end', 'generation']);
    expect(lines.first['lang'], 'ja');
    expect(lines.first['t'], endsWith('Z'));
    expect(lines[1]['lon'], 139.7);
    expect(lines[0].containsKey('user'), isFalse); // no position yet
    expect(lines[2]['user'], {'lat': 35.6, 'lon': 139.7, 'age_s': 0}); // where the walker was

    log.startWalk({}, now: DateTime(2026, 10, 24, 18));
    expect(await log.files(), hasLength(2));
    await log.clear();
    expect(await log.files(), isEmpty);
  });

  test('nothing is written while the log is off', () async {
    var on = false;
    final log = WalkLog(dir, () => on);
    log.startWalk({});
    log.event('pos', {'lat': 1});
    expect(await log.files(), isEmpty);
    on = true; // turned on mid-walk: starts with the next walk
    log.event('pos', {'lat': 1});
    expect(await log.files(), isEmpty);
  });
}
