import 'dart:convert';
import 'dart:io';

import 'package:codewalk/models.dart';
import 'package:codewalk/radar.dart';
import 'package:codewalk/stores.dart';
import 'package:flutter_test/flutter_test.dart';

LogEntry entry(String spotId, DateTime at) => LogEntry(
      id: '$spotId-${at.millisecondsSinceEpoch}',
      receivedAt: at,
      played: true,
      dialogue: Dialogue.fromJson({
        'spot': {'id': spotId, 'name': spotId, 'lat': 0, 'lon': 0},
        'theme': 'history',
        'specialist': {'id': 'shiori', 'name': 'フクロウ', 'frequency': '146.35'},
        'commander': {'id': 'ootori', 'name': 'シレイ', 'frequency': '147.20'},
        'lines': [],
        'sources': [],
      }),
    );

void main() {
  test('places heard in the last hour stay quiet; counts tell how many times each was heard', () {
    final now = DateTime(2026, 10, 15, 12);
    final log = LogStore(File('${Directory.systemTemp.path}/unused.json'), [
      entry('osm:1', now.subtract(const Duration(minutes: 20))),
      entry('osm:2', now.subtract(const Duration(minutes: 90))),
      entry('osm:2', now.subtract(const Duration(days: 2))),
    ]);
    expect(log.recentlyHeard(now, revisitAfter), {'osm:1'});
    expect(log.heardCounts, {'osm:1': 1, 'osm:2': 2});
    expect(log.recentlyHeard(now.add(const Duration(hours: 1)), revisitAfter), isEmpty); // osm:1 can ring again
  });

  test("today's calls only: the pins on the walk map and the glasses", () {
    final now = DateTime(2026, 10, 15, 0, 30);
    final log = LogStore(File('${Directory.systemTemp.path}/unused.json'), [
      entry('osm:1', now.subtract(const Duration(minutes: 20))),
      entry('osm:2', now.subtract(const Duration(minutes: 40))), // yesterday 23:50
    ]);
    expect([for (final e in log.today(now)) e.dialogue.spotId], ['osm:1']);
    expect(log.inRange(LogRange.today, now), log.today(now));
    expect(log.inRange(LogRange.week, now.add(const Duration(days: 6, hours: 23, minutes: 30))).length, 1); // osm:2 is just over 7 days old
    expect(log.inRange(LogRange.all, now).length, 2);
  });

  test('conversations saved with an old frequency show the current one', () {
    final old = entry('osm:1', DateTime(2026, 10, 1));
    final j = old.toJson();
    ((j['dialogue'] as Map)['specialist'] as Map)['frequency'] = '140.15';
    expect(LogEntry.fromJson(j).dialogue.specialist.frequency, '146.35');
  });

  test('calls saved under an old name show the current one (English stays English)', () {
    final j = entry('osm:1', DateTime(2026, 10, 1)).toJson();
    ((j['dialogue'] as Map)['specialist'] as Map)['name'] = 'シオリ';
    ((j['dialogue'] as Map)['commander'] as Map)['name'] = 'オオトリ';
    final old = LogEntry.fromJson(j).dialogue;
    expect([old.specialist.name, old.commander.name], ['フクロウ', 'シレイ']);
    ((j['dialogue'] as Map)['specialist'] as Map)['name'] = 'Owl';
    expect(LogEntry.fromJson(j).dialogue.specialist.name, 'Owl');
  });

  test('deleting the call log empties it on disk too', () async {
    final dir = await Directory.systemTemp.createTemp('cw-log');
    final file = File('${dir.path}/radio_log.json');
    final log = LogStore(file, [entry('osm:1', DateTime(2026, 10, 1)), entry('osm:2', DateTime(2026, 10, 2))]);
    await log.clear();
    expect(log.entries, isEmpty);
    expect(jsonDecode(await file.readAsString()), isEmpty);
    expect(log.heardCounts, isEmpty); // places heard before can ring again
    await dir.delete(recursive: true);
  });
}
