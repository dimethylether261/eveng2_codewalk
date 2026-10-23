/// On-device cache for spots, area queries and generated dialogues (one JSON document).
///
/// Where the JSON lives is up to the caller: a file on the phone (store_file.dart) or the
/// Even Hub storage in the glasses app (lib/standalone/). This file has no dart:io.
library;

import 'dart:async';
import 'dart:convert';

import 'util.dart';

double _now() => DateTime.now().millisecondsSinceEpoch / 1000;

/// Saves the whole cache as one JSON string.
typedef Persist = Future<void> Function(String json);

class Store {
  Store._(this._persist, this._areas, this._spots, this._dialogues, this._values);

  /// [json]: what [persist] saved last time (null or broken = an empty cache).
  /// [persist] null = in memory only (tests).
  factory Store.fromJson(String? json, {Persist? persist}) {
    var data = <String, dynamic>{};
    if (json != null && json.isNotEmpty) {
      try {
        data = jsonDecode(json) as Json;
      } catch (_) {
        data = {}; // a broken cache is just a cold cache
      }
    }
    Map<String, Json> part(String k) => {for (final e in ((data[k] as Map?) ?? const {}).entries) e.key as String: e.value as Json};
    return Store._(persist, part('areas'), part('spots'), part('dialogues'), part('values'));
  }

  final Persist? _persist;
  final Map<String, Json> _areas, _spots, _dialogues, _values;
  Timer? _saveTimer;

  void _changed() {
    if (_persist == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    await _persist?.call(jsonEncode({'areas': _areas, 'spots': _spots, 'dialogues': _dialogues, 'values': _values}));
  }

  // --- spots -------------------------------------------------------------
  void putArea(String key, List<Json> spots) {
    putSpots(spots);
    _areas[key] = {'ids': [for (final s in spots) s['id']], 'ts': _now()};
    _changed();
  }

  /// Remember spots (so dialogues can be asked for them) without caching the area query.
  void putSpots(List<Json> spots) {
    final now = _now();
    for (final s in spots) {
      _spots[s['id'] as String] = {'json': s, 'ts': now};
    }
    _changed();
  }

  List<Json>? getArea(String key, int ttlS) {
    final row = _areas[key];
    if (row == null || _now() - (row['ts'] as num) > ttlS) return null;
    return [for (final id in (row['ids'] as List)) ?getSpot(id as String)];
  }

  List<Json> spotsWithPrefix(String prefix) =>
      [for (final e in _spots.entries) if (e.key.startsWith(prefix)) _copy(e.value['json'] as Json)];

  Json? getSpot(String id) {
    final row = _spots[id];
    return row == null ? null : _copy(row['json'] as Json);
  }

  /// Deep copy so callers can't mutate the cache by accident.
  static Json _copy(Json j) => jsonDecode(jsonEncode(j)) as Json;

  // --- small values (e.g. the country of a map cell) ----------------------
  void putValue(String key, Object? value) {
    _values[key] = {'v': value, 'ts': _now()};
    _changed();
  }

  /// (value) if stored within [ttlS], else null. A stored null comes back as (null).
  (Object?,)? getValue(String key, int ttlS) {
    final row = _values[key];
    if (row == null || _now() - (row['ts'] as num) > ttlS) return null;
    return (row['v'],);
  }

  // --- dialogues ---------------------------------------------------------
  void putDialogue(String spotId, String theme, String status, {String? reason, Json? dialogue}) {
    _dialogues['$spotId|$theme'] = {'status': status, 'reason': reason, 'dialogue': dialogue, 'ts': _now()};
    _changed();
  }

  /// (status, reason, dialogue, ts) or null.
  (String, String?, Json?, double)? getDialogue(String spotId, String theme) {
    final row = _dialogues['$spotId|$theme'];
    if (row == null) return null;
    final d = row['dialogue'] as Json?;
    return (row['status'] as String, row['reason'] as String?, d == null ? null : _copy(d), (row['ts'] as num).toDouble());
  }

  /// Drop failures recorded as 'bad_key', so a fixed key is tried at once rather than after errorTtlS.
  void forgetKeyErrors() {
    final before = _dialogues.length;
    _dialogues.removeWhere((_, row) => row['status'] == 'error' && row['reason'] == 'bad_key');
    if (_dialogues.length != before) _changed();
  }

  /// Ready dialogues made for a place so far (any theme or round), oldest first, with the slot
  /// they were stored under (`theme`, or `theme|rN` for a revisit).
  List<(String, Json)> readyDialoguesFor(String spotId) {
    final rows = [
      for (final e in _dialogues.entries)
        if (e.key.startsWith('$spotId|') && e.value['status'] == 'ready' && e.value['dialogue'] != null)
          (e.key.substring(spotId.length + 1), e.value),
    ]..sort((a, b) => (a.$2['ts'] as num).compareTo(b.$2['ts'] as num));
    return [for (final (slot, r) in rows) (slot, _copy(r['dialogue'] as Json))];
  }

  /// Forget everything (the settings screen's "delete the conversation cache").
  Future<void> clear() async {
    _areas.clear();
    _spots.clear();
    _dialogues.clear();
    _values.clear();
    await flush();
  }

  /// Every ready dialogue (for the 'what did this cost' summary and debugging).
  int get dialogueCount => _dialogues.values.where((d) => d['status'] == 'ready').length;
}
