/// The call log's queries and the settings enums, without Flutter: shared by the phone app
/// (LogStore) and the glasses app's standalone core (lib/standalone/, compiled to JavaScript).
library;

import 'l10n.dart';
import 'models.dart';

/// How often the radio may ring.
enum CallFrequency {
  more(Duration(minutes: 2)),
  normal(Duration(minutes: 5)),
  less(Duration(minutes: 15));

  const CallFrequency(this.minInterval);
  final Duration minInterval;
  String get label => t.frequencyLabels[name]!;
}

/// A period of the call log: the log list and the map pins (walk map, glasses minimap).
enum LogRange {
  today,
  week,
  all;

  String get label => switch (this) { today => t.rangeToday, week => t.rangeWeek, all => t.rangeAll };
}

/// Received calls, newest first, and what the radar needs to know about them.
mixin LogQueries {
  List<LogEntry> get entries;

  Set<String> get heardSpotIds => entries.map((e) => e.dialogue.spotId).toSet();

  /// Calls received today (local time), newest first.
  List<LogEntry> today(DateTime now) {
    final start = DateTime(now.year, now.month, now.day);
    return [for (final e in entries) if (!e.receivedAt.isBefore(start)) e];
  }

  /// Calls in [range], newest first.
  List<LogEntry> inRange(LogRange range, DateTime now) => switch (range) {
        LogRange.today => today(now),
        LogRange.week => [for (final e in entries) if (now.difference(e.receivedAt) < const Duration(days: 7)) e],
        LogRange.all => entries,
      };

  /// Places heard within [cooldown] of [now]: they stay quiet until it has passed.
  Set<String> recentlyHeard(DateTime now, Duration cooldown) => {
        for (final e in entries)
          if (now.difference(e.receivedAt) < cooldown) e.dialogue.spotId,
      };

  /// How many times each place was heard (0 = new): the next call there is a new conversation.
  Map<String, int> get heardCounts {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.dialogue.spotId] = (counts[e.dialogue.spotId] ?? 0) + 1;
    }
    return counts;
  }

  /// Put a new call at the top of the log.
  LogEntry newEntry(Dialogue d, {required bool played, double? heardLat, double? heardLon}) {
    final now = DateTime.now();
    final e = LogEntry(
      id: '${now.millisecondsSinceEpoch}',
      receivedAt: now,
      played: played,
      dialogue: d,
      heardLat: heardLat,
      heardLon: heardLon,
    );
    entries.insert(0, e);
    return e;
  }
}
