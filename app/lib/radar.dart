// Pure decision logic for when the radio rings. Kept free of Flutter/plugins so it can be unit-tested.
import 'dart:math';

import 'models.dart';

const triggerRadiusM = 60.0;
const prefetchRadiusM = 300.0;
const refetchDistanceM = 150.0;
const refetchInterval = Duration(minutes: 3);

/// Spots ahead whose conversations are written before the user gets there. Each costs a
/// conversation whether or not it is heard, so only the nearest few (was 6 until 2026-10-17).
const prefetchAhead = 3;
const maxWalkingSpeedMps = 4.0; // ~14 km/h: above this (bike, car) the radio stays quiet

double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = (lat2 - lat1) * pi / 180, dl = (lon2 - lon1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

bool matchesThemes(Spot s, List<String> themes) => s.themes.any(themes.contains);

/// Tuned themes, least-heard first (ties keep the user's order), so one theme doesn't
/// take every call. The engine picks the first theme in this order that a spot has.
List<String> rotateThemes(List<String> tuned, Iterable<String> recentlyHeardThemes) {
  final count = {for (final t in tuned) t: 0};
  for (final t in recentlyHeardThemes) {
    if (count.containsKey(t)) count[t] = count[t]! + 1;
  }
  final order = [...tuned];
  order.sort((a, b) {
    final c = count[a]!.compareTo(count[b]!);
    return c != 0 ? c : tuned.indexOf(a).compareTo(tuned.indexOf(b));
  });
  return order;
}

int _themeRank(Spot s, List<String> themes) {
  final ranks = s.themes.map(themes.indexOf).where((i) => i >= 0);
  return ranks.isEmpty ? 1 << 20 : ranks.reduce((a, b) => a < b ? a : b);
}

/// Spots worth generating a dialogue for in advance (near, unheard, matching themes).
List<Spot> prefetchCandidates({
  required List<Spot> spots,
  required double lat,
  required double lon,
  required List<String> themes,
  required Set<String> excluded,
}) =>
    spots
        .where((s) => !excluded.contains(s.id) && matchesThemes(s, themes))
        .where((s) => distanceM(lat, lon, s.lat, s.lon) <= prefetchRadiusM)
        .toList()
      ..sort((a, b) => distanceM(lat, lon, a.lat, a.lon).compareTo(distanceM(lat, lon, b.lat, b.lon)));

/// The spot the user is passing right now, or null when the radio should stay quiet.
Spot? spotToCall({
  required List<Spot> spots,
  required double lat,
  required double lon,
  required double speedMps,
  required List<String> themes,
  required Set<String> excluded,
  required DateTime now,
  required DateTime? lastCallAt,
  required Duration minInterval,
}) {
  final c = candidatesToCall(
      spots: spots,
      lat: lat,
      lon: lon,
      speedMps: speedMps,
      themes: themes,
      excluded: excluded,
      now: now,
      lastCallAt: lastCallAt,
      minInterval: minInterval);
  return c.isEmpty ? null : c.first;
}

/// All spots in range that may ring now, least-heard theme first, then nearest.
/// The engine picks the most interesting ready dialogue among them.
List<Spot> candidatesToCall({
  required List<Spot> spots,
  required double lat,
  required double lon,
  required double speedMps,
  required List<String> themes,
  required Set<String> excluded,
  required DateTime now,
  required DateTime? lastCallAt,
  required Duration minInterval,
}) {
  if (speedMps > maxWalkingSpeedMps) return [];
  if (lastCallAt != null && now.difference(lastCallAt) < minInterval) return [];
  final inRange = <(Spot, int, double)>[];
  for (final s in spots) {
    if (excluded.contains(s.id) || !matchesThemes(s, themes)) continue;
    final d = distanceM(lat, lon, s.lat, s.lon);
    if (d <= triggerRadiusM) inRange.add((s, _themeRank(s, themes), d));
  }
  inRange.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3));
  return [for (final e in inRange.take(5)) e.$1];
}

/// The current town, when no spot is calling: rings once per town, under the same quiet rules.
Spot? areaToCall({
  required Spot? area,
  required double speedMps,
  required List<String> themes,
  required Set<String> excluded,
  required DateTime now,
  required DateTime? lastCallAt,
  required Duration minInterval,
}) {
  if (area == null || excluded.contains(area.id) || !matchesThemes(area, themes)) return null;
  if (speedMps > maxWalkingSpeedMps) return null;
  if (lastCallAt != null && now.difference(lastCallAt) < minInterval) return null;
  return area;
}

/// A place can ring again this long after it was last heard (with a new conversation).
const revisitAfter = Duration(hours: 1);

/// After this long without any call during a walk, a "今日は何の日" chat call may ring.
const chatAfter = Duration(minutes: 15);

/// The chat call (not tied to a place) is due: walking at a walking pace and nothing rang for
/// [chatAfter] since the walk started. (Whether it was already heard today is checked by the
/// caller: the chat spot's id is per day.)
bool chatDue({
  required double speedMps,
  required DateTime now,
  required DateTime walkStartedAt,
  required DateTime? lastCallAt,
}) {
  if (speedMps > maxWalkingSpeedMps) return false;
  final quietSince = lastCallAt != null && lastCallAt.isAfter(walkStartedAt) ? lastCallAt : walkStartedAt;
  return now.difference(quietSince) >= chatAfter;
}

bool shouldRefetch({
  required double lat,
  required double lon,
  required double? lastLat,
  required double? lastLon,
  required DateTime now,
  required DateTime? lastAt,
}) {
  if (lastLat == null || lastLon == null || lastAt == null) return true;
  return distanceM(lat, lon, lastLat, lastLon) > refetchDistanceM || now.difference(lastAt) > refetchInterval;
}
