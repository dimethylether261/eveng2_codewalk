// Runs the on-device engine from the PC: nearby spots -> one dialogue (real APIs, costs a few cents).
//
// Usage (from app/):
//   ANTHROPIC_API_KEY=... CODEWALK_CONTACT=you@example.com \
//     ~/development/flutter/bin/dart run tool/try_dialogue.dart 35.6226 139.7389 [history,architecture]
import 'dart:io';

import 'package:codewalk/engine/claude.dart';
import 'package:codewalk/engine/engine.dart';
import 'package:codewalk/engine/store_file.dart';

Future<void> main(List<String> args) async {
  final lat = double.parse(args[0]), lon = double.parse(args[1]);
  final themes = (args.length > 2 ? args[2] : 'history,architecture,infrastructure').split(',');
  final contact = Platform.environment['CODEWALK_CONTACT'] ?? '';
  final engine = Engine(
    store: await openStore('${Directory.systemTemp.path}/codewalk_try.json'),
    apiKey: Platform.environment['ANTHROPIC_API_KEY'],
    userAgent: 'CodeWalk/0.1 (personal prototype; ${contact.isEmpty ? 'https://www.mediawiki.org/wiki/API:Etiquette' : contact}) dart',
    config: EngineConfig(
        allowedDomains: Platform.environment['CODEWALK_ALLOWED_DOMAINS'] == '*' ? const [] : restrictedDomains),
  );
  final spots = await engine.spots(lat, lon);
  stdout.writeln('${spots.length} spots');
  try {
    stdout.writeln('town: ${(await engine.area(lat, lon))?['name']}');
  } catch (e) {
    stdout.writeln('town lookup failed: $e');
  }
  for (final s in spots) {
    if (!(s['themes'] as List).any(themes.contains)) continue;
    stdout.writeln('\n== ${s['name']} (${s['kind']}, ${s['themes']})');
    Map<String, dynamic> r = {'status': 'pending'};
    for (var i = 0; i < 120 && r['status'] == 'pending'; i++) {
      r = engine.dialogue(s['id'] as String, themes, 'ウォーカー');
      if (r['status'] == 'pending') await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (r['status'] == 'ready') {
      final d = r['dialogue'] as Map<String, dynamic>;
      final names = {(d['commander'] as Map)['id']: (d['commander'] as Map)['name'], (d['specialist'] as Map)['id']: (d['specialist'] as Map)['name']};
      final rv = d['review'] as Map?;
      stdout.writeln('${rv?['score']}点 型:${rv?['pattern']}  \$${(d['usage'] as Map)['usd']}');
      for (final l in (d['lines'] as List).cast<Map>()) {
        stdout.writeln('  ${names[l['speaker']]}: ${l['text']}  ${(l['source_ids'] as List).isEmpty ? '' : l['source_ids']}');
      }
      for (final src in (d['sources'] as List).cast<Map>()) {
        stdout.writeln('  [${src['id']}] ${src['title']}  ${src['url']}');
      }
      break;
    }
    stdout.writeln('  -> $r');
  }
  await engine.idle();
  await engine.store.flush();
  exit(0);
}
