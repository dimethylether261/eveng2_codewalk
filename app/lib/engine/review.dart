/// Review a finished dialogue: deterministic rule checks + an LLM rubric score.
///
/// The score (1.0-5.0) decides whether to rewrite once, and picks the most interesting
/// ready dialogue among several nearby spots.
library;

import 'dart:convert';

import 'characters.dart';
import 'claude.dart';
import 'texts.dart';
import 'util.dart';

const maxLineChars = 50;
const maxLineCharsEn = 130; // ~20 words
const minLines = 4; // 4: the short "ひとことネタ" pattern
const maxLines = 12;
const rulePenalty = 0.4;

final reviewSchema = jsonDecode(reviewSchemaJson) as Json;

/// Problems we can detect without an LLM.
List<String> ruleIssues(List<Json> lines, String specialistName, {String lang = 'ja'}) {
  final limit = lang == 'en' ? maxLineCharsEn : maxLineChars;
  final issues = <String>[];
  if (lines.length < minLines || lines.length > maxLines) issues.add('セリフ数が${lines.length}（$minLines〜10が目安）');
  if (lines.isNotEmpty && lines.first['speaker'] != commander.id) issues.add('最初に司令が呼びかけて無線を開いていない');
  for (var i = 1; i < lines.length; i++) {
    final prev = lines[i - 1], cur = lines[i];
    if (prev['speaker'] == cur['speaker']) {
      final who = cur['speaker'] == commander.id ? '司令' : specialistName;
      issues.add('$i〜${i + 1}行目で$whoが2回続けて話している');
      final t = (prev['text'] as String).trimRight();
      if (t.endsWith('？') || t.endsWith('?')) issues.add('$i行目の問いかけに相手が答えないまま$specialistNameが続けている');
    }
  }
  if (lines.isNotEmpty && ['通信終了', '通信終わり', '以上、'].any((w) => (lines.last['text'] as String).contains(w))) {
    issues.add('最後が「通信終了」などの決まり文句になっている');
  }
  for (var i = 0; i < lines.length; i++) {
    final n = (lines[i]['text'] as String).length;
    if (n > limit) issues.add('${i + 1}行目が長い（$n字）');
  }
  return issues;
}

String reviewUser(List<Json> lines, Map<String, String> names, {String? pattern, String lang = 'ja'}) {
  final numbered = [
    for (var i = 0; i < lines.length; i++)
      {'行': i + 1, '話者': names[lines[i]['speaker']] ?? lines[i]['speaker'], 'セリフ': lines[i]['text']},
  ];
  final c = names[commander.id] ?? '司令';
  final sp = names.entries.where((e) => e.key != commander.id).firstOrNull?.value ?? '担当';
  var roles = '登場人物: $c は司令（聞き役。この場所の事実は持ち込まないが、感想や脱線はしてよい）。$sp は事実を話す担当。'
      '{{CODENAME}} は無線を聞いているユーザーのコードネームで、会話の話者ではない（セリフ中の'
      '{{CODENAME}} は実際の名前に置き換わる）。';
  final p = patterns[pattern];
  if (p != null) {
    roles += '\n会話の型: $pattern（${p.name}）: '
        '${p.how.replaceAll('{c}', c).replaceAll('{sp}', sp).replaceAll('{cn}', '{{CODENAME}}')}';
  }
  if (lang == 'en') {
    roles += '\n会話は英語（English）。短さは「1セリフ20語程度まで」を基準にし、英語として自然か、口調が英語でもキャラクターらしいかで採点する。';
  }
  return '$roles\n\n会話:\n${const JsonEncoder.withIndent(' ').convert(numbered)}\n\n採点してください。';
}

Future<Json> review(Claude llm, List<Json> lines, Map<String, String> names, String specialistName,
    {String? pattern, String lang = 'ja'}) async {
  final rules = ruleIssues(lines, specialistName, lang: lang);
  // Editorial judgement: use the dialogue model (Sonnet by default), not the cheap check model.
  final data = await llm.json(reviewSystem, reviewUser(lines, names, pattern: pattern, lang: lang), reviewSchema,
      llm.config.effortReview, step: 'review');
  final raw = (data['scores'] as Map?) ?? const {};
  final scores = {for (final k in reviewCriteria.keys) k: ((raw[k] as num?)?.toInt() ?? 3).clamp(1, 5)};
  final base = scores.values.fold<int>(0, (a, b) => a + b) / scores.length;
  final score = ((base - rulePenalty * rules.length).clamp(1.0, 5.0) * 100).round() / 100;
  final llmIssues = [for (final x in (data['issues'] as List? ?? const [])) '$x'.length > 80 ? '$x'.substring(0, 80) : '$x'];
  return {'score': score, 'scores': scores, 'issues': [...rules, ...llmIssues].take(6).toList()};
}
