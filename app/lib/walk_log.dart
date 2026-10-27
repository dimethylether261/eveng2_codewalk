import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'engine/util.dart';

/// The walk log (Settings > Developer, off by default): one JSON Lines file per walk, kept on this
/// phone, for improving the app later. It holds the route, what the radio did, and each conversation's
/// generation (outcome, time taken, API usage). The settings screen shares or deletes the files.
///
/// Each line is `{"t": <UTC ISO 8601>, "type": ..., ...}`. Every event but `pos` also carries
/// `user`: where the walker was then (the latest `pos`, with its age in seconds).
class WalkLog extends ChangeNotifier {
  WalkLog(this.dir, this._enabled);

  final Directory dir;
  final bool Function() _enabled;
  File? _file;
  Future<void> _writes = Future.value();
  ({double lat, double lon, DateTime at})? _lastPos;

  static Future<WalkLog> create(bool Function() enabled) async {
    final docs = await getApplicationDocumentsDirectory();
    return WalkLog(Directory('${docs.path}/walk_logs'), enabled);
  }

  /// A walk started: later events go to a new file until the next walk, so a conversation that
  /// finishes after the walk ended still lands in that walk's file.
  void startWalk(Json info, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _file = _enabled() ? File('${dir.path}/walk_${_stamp(at)}.jsonl') : null;
    event('walk_start', {...info, 'utc_offset_min': at.timeZoneOffset.inMinutes}, at);
    notifyListeners();
  }

  /// Appends an event to the current walk's file (nothing when the log is off or no walk started).
  void event(String type, [Json data = const {}, DateTime? now]) {
    final f = _file;
    if (f == null || !_enabled()) return;
    final at = now ?? DateTime.now();
    final pos = _lastPos;
    if (type == 'pos') _lastPos = (lat: (data['lat'] as num).toDouble(), lon: (data['lon'] as num).toDouble(), at: at);
    final String line;
    try {
      line = jsonEncode({
        ...data,
        if (type != 'pos' && pos != null)
          'user': {'lat': pos.lat, 'lon': pos.lon, 'age_s': at.difference(pos.at).inSeconds},
        't': at.toUtc().toIso8601String(),
        'type': type,
      });
    } catch (e) {
      debugPrint('walk log: $type not written ($e)'); // e.g. a NaN: never break the walk for the log
      return;
    }
    _writes = _writes
        .then((_) async {
          await dir.create(recursive: true);
          await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
        })
        .catchError((Object e) => debugPrint('walk log: $e'));
  }

  /// Waits for the pending writes.
  Future<void> flush() => _writes;

  /// The walk files, oldest first.
  Future<List<File>> files() async {
    await _writes;
    if (!await dir.exists()) return [];
    final files = await dir.list().where((e) => e is File && e.path.endsWith('.jsonl')).cast<File>().toList();
    return files..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Delete every walk file (a walk in progress starts a fresh file with its next event).
  Future<void> clear() async {
    for (final f in await files()) {
      await f.delete();
    }
    notifyListeners();
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
