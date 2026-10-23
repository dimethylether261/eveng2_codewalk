// One dialogue per (spot, theme) to check a character's speech style (real APIs, a few cents each).
//
// Usage (from app/): ANTHROPIC_API_KEY=... ~/development/flutter/bin/dart run tool/tone_samples.dart
import 'dart:io';

import 'package:codewalk/engine/claude.dart';
import 'package:codewalk/engine/characters.dart';
import 'package:codewalk/engine/pipeline.dart' as pipeline;

final samples = <(Map<String, dynamic>, String)>[
  ({'id': 'wp:1740122', 'name': '品川神社', 'lat': 35.6197, 'lon': 139.7426, 'kind': 'shrine', 'wikipedia': 'ja:品川神社', 'themes': ['history'], '_tags': {}}, 'history'),
  ({'id': 'osm:node:13744716801', 'name': 'CINEMALICE', 'lat': 35.6962, 'lon': 139.7578, 'kind': 'cinema', 'themes': ['film'], '_tags': {}}, 'film'),
  ({'id': 'osm:node:4376204494', 'name': '日本の酒情報館', 'lat': 35.6708, 'lon': 139.7507, 'kind': 'museum', 'themes': ['food'], '_tags': {}}, 'food'),
];

Future<void> main() async {
  final llm = Claude(Platform.environment['ANTHROPIC_API_KEY']!, config: const EngineConfig());
  var total = 0.0;
  for (final (spot, theme) in samples) {
    final usage = Usage();
    final sp = specialists[theme]!;
    try {
      final d = await pipeline.generate(llm.withUsage(usage), spot, theme);
      stdout.writeln('\n=== ${spot['name']}（${sp.name}） ${(d['review'] as Map?)?['score']}点  \$${usage.usd?.toStringAsFixed(3)}');
      for (final l in (d['lines'] as List).cast<Map>()) {
        stdout.writeln('  ${l['speaker'] == commander.id ? commander.name : sp.name}: ${(l['text'] as String).replaceAll('{{CODENAME}}', 'ウォーカー')}');
      }
    } catch (e) {
      stdout.writeln('\n=== ${spot['name']}（${sp.name}）: $e  \$${usage.usd?.toStringAsFixed(3)}');
    }
    total += usage.usd ?? 0;
  }
  stdout.writeln('\n合計 \$${total.toStringAsFixed(3)}');
  exit(0);
}
