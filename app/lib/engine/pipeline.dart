/// Dialogue generation: research (cited facts) -> dialogue -> check -> review.
///
/// Facts are taken only from text blocks that carry API-issued citations, so every fact has
/// a verbatim `cited_text` and a URL that came from the web tools, not from the model's memory.
library;

import 'dart:math' as math;

import 'characters.dart';
import 'claude.dart';
import 'prompts.dart';
import 'review.dart' as rv;
import 'texts.dart';
import 'util.dart';

// Line length is controlled by the prompt only: cutting a line mid-way breaks the
// back-and-forth (the next line answers what was cut).
const maxDialogueLines = 12;

final _nudge = RegExp(r'行ってみ|寄って(み|いけ|行)|向かって(み|くれ)|足を運|訪れてみ|あっちにも|向こうにも|立ち寄');

List<Json> researchTools(EngineConfig c) {
  final domains = c.allowedDomains.isEmpty ? const <String, dynamic>{} : {'allowed_domains': c.allowedDomains};
  return [
    {
      'type': c.webSearchTool,
      'name': 'web_search',
      'max_uses': c.webMaxUses,
      ...domains,
      'user_location': {'type': 'approximate', 'country': 'JP', 'timezone': 'Asia/Tokyo'},
    },
    {
      'type': c.webFetchTool,
      'name': 'web_fetch',
      'max_uses': c.webMaxUses,
      ...domains,
      'citations': {'enabled': true},
      'max_content_tokens': 20000,
    },
  ];
}

/// Research content blocks -> (facts, sources). Uncited text is discarded.
(List<Json>, List<Json>) extractFacts(List<Json> blocks) {
  final fetched = <({String url, String title})>[]; // web_fetch documents in order
  for (final b in blocks) {
    if (b['type'] == 'web_fetch_tool_result') {
      final c = b['content'] as Map?;
      if (c?['type'] == 'web_fetch_result') {
        final url = c!['url'] as String;
        fetched.add((url: url, title: ((c['content'] as Map?)?['title'] as String?) ?? url));
      }
    }
  }

  (String?, String?) locate(Map cit) {
    final url = cit['url'] as String?;
    if (url != null && url.isNotEmpty) return (url, (cit['title'] as String?) ?? url);
    final idx = cit['document_index'];
    final title = cit['document_title'] as String?;
    if (title != null && title.isNotEmpty) {
      for (final d in fetched) {
        if (d.title == title) return (d.url, title);
      }
    }
    if (idx is int && idx >= 0 && idx < fetched.length) return (fetched[idx].url, fetched[idx].title);
    if (fetched.length == 1) return (fetched.first.url, fetched.first.title);
    return (null, null);
  }

  // Consecutive text blocks form one paragraph; a paragraph with >=1 citation is a fact.
  final paragraphs = <(String, List<Map>)>[];
  var curText = '';
  var curCits = <Map>[];
  for (final b in blocks) {
    if (b['type'] != 'text') continue;
    final parts = ((b['text'] ?? '') as String).split('\n\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        paragraphs.add((curText, curCits));
        curText = '';
        curCits = [];
      }
      curText += parts[i];
    }
    curCits = [...curCits, ...((b['citations'] as List?) ?? const []).cast<Map>()];
  }
  paragraphs.add((curText, curCits));

  final sources = <Json>[];
  final facts = <Json>[];
  final seen = <String>{};
  for (final (text, cits) in paragraphs) {
    final claim = normSpace(text).replaceFirst(RegExp(r'^[-・* ]+'), '').trim();
    if (claim.length < 8 || cits.isEmpty || claim.contains('NO_SOURCES') || seen.contains(claim)) continue;
    final quotes = <String>[];
    final srcIds = <int>[];
    for (final c in cits) {
      final (url, title) = locate(c);
      final quote = normSpace(c['cited_text'] as String?);
      if (url == null || quote.isEmpty) continue;
      var src = sources.where((s) => s['url'] == url).firstOrNull;
      if (src == null) {
        src = {'id': sources.length + 1, 'title': title ?? url, 'url': url, 'quote': _cut(quote, 300)};
        sources.add(src);
      }
      srcIds.add(src['id'] as int);
      quotes.add(quote);
    }
    if (srcIds.isEmpty) continue;
    seen.add(claim);
    facts.add({
      'id': facts.length + 1,
      'claim': claim,
      'quote': _cut(quotes.join(' / '), 600),
      'source_ids': (srcIds.toSet().toList()..sort()),
    });
  }
  return (facts.take(8).toList(), sources);
}

String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

/// What specialists already said at a place (from earlier conversations, oldest first), so a
/// revisit talks about something else. Commander lines are left out: they carry no facts.
/// Over [max] lines, the latest conversations are kept.
List<String> toldBefore(List<Json> dialogues, {int max = 24}) {
  final told = [
    for (final d in dialogues)
      for (final l in (d['lines'] as List? ?? const []).cast<Json>())
        if (l['speaker'] != commander.id) (l['text'] as String).replaceAll(codenamePlaceholder, 'ウォーカー'),
  ];
  return told.length > max ? told.sublist(told.length - max) : told;
}

Future<(List<Json>, List<Json>)> collectFacts(Claude llm, Json spot, String theme,
    {String? model, List<String> told = const []}) async {
  final user = researchUser(spot, theme, wikipediaUrl(spot['wikipedia'] as String?), told: told);
  final blocks = await llm.research(researchSystem, user, researchTools(llm.config), model: model);
  final found = extractFacts(blocks);
  // How much this research yielded, next to what it cost (the walk log; a paused turn's last request).
  final last = llm.usage?.steps.lastOrNull;
  if (last != null && last['step'] == 'research') last['facts'] = found.$1.length;
  return found;
}

String? pickTheme(Json spot, List<String> requested) {
  final themes = (spot['themes'] as List? ?? const []).cast<String>();
  for (final t in requested) {
    if (themes.contains(t) && specialists.containsKey(t)) return t;
  }
  return null;
}

List<Json> buildLines(List<Json> rawLines, List<Json> facts, String specialistId, Json? check) {
  final byId = {for (final f in facts) f['id'] as int: f};
  final verdict = {
    for (final r in ((check?['results'] as List?) ?? const []).cast<Json>())
      if (r['index'] is int) r['index'] as int: r,
  };
  final out = <Json>[];
  for (var i = 0; i < rawLines.length; i++) {
    final l = rawLines[i];
    final text = normSpace(l['text'] as String?);
    final speaker = l['speaker'];
    if (text.isEmpty || (speaker != commander.id && speaker != specialistId)) continue;
    final v = verdict[i];
    if (v != null &&
        (v['supported'] != true ||
            v['nudge'] == true ||
            v['tasteless'] == true || // never ship a line that makes light of a tragedy
            v['repeat'] == true || // a revisit that retells what the user already heard here
            (speaker == commander.id && v['commander_fact'] == true))) {
      continue;
    }
    if (check != null && v == null) continue; // unchecked line: drop rather than trust
    if (_nudge.hasMatch(text)) continue;
    final factIds = speaker == commander.id
        ? const <int>[]
        : [for (final f in (l['fact_ids'] as List? ?? const [])) if (byId.containsKey(f)) f as int];
    final sourceIds = {for (final f in factIds) ...(byId[f]!['source_ids'] as List).cast<int>()}.toList()..sort();
    out.add({'speaker': speaker, 'text': text, 'source_ids': sourceIds});
  }
  if (out.length > maxDialogueLines) {
    // keep the sign-off at the end
    return [...out.take(maxDialogueLines - 1), out.last];
  }
  return out;
}

/// Lines the fact check would delete, phrased as rewrite instructions (deletion breaks the flow).
List<String> checkIssues(List<Json> rawLines, Json? check) {
  final issues = <String>[];
  for (final r in ((check?['results'] as List?) ?? const []).cast<Json>()) {
    final i = r['index'];
    if (i is! int || i < 0 || i >= rawLines.length) continue;
    final line = rawLines[i];
    final quote = _cut((line['text'] ?? '') as String, 40);
    if (line['speaker'] == commander.id && r['commander_fact'] == true) {
      issues.add('${i + 1}行目の司令「$quote」は、まだ出ていない情報を言っている。驚き・直前の話の言い直し・素朴な疑問に変える');
    } else if (r['supported'] == false) {
      issues.add('${i + 1}行目「$quote」は事実カードで裏付けられない。カードにある事実だけにする');
    }
    if (r['nudge'] == true) issues.add('${i + 1}行目「$quote」はどこかへ行くことをすすめている。削る');
    if (r['tasteless'] == true) {
      issues.add('${i + 1}行目「$quote」は悲しい出来事を軽く扱っていて不謹慎。冗談や連想をやめ、静かに受け止める言い方にする');
    }
    if (r['repeat'] == true) issues.add('${i + 1}行目「$quote」は前回この場所で話したのと同じ話。カードの別の事実にする');
  }
  return issues;
}

/// The riddle (quiz) is the Sphinx's, and only now and then: offered in about this share of its calls.
const riddleChance = 0.25;
const riddler = 'tetsu';

/// A few conversation shapes to offer the writer (it picks the one that suits the facts).
/// Only the Sphinx gets the riddle, and only sometimes (every call would be too much).
List<String> pickPatterns(Character specialist, [math.Random? rng]) {
  final r = rng ?? math.Random();
  final others = patterns.keys.where((p) => p != 'quiz').toList()..shuffle(r);
  if (specialist.id == riddler && r.nextDouble() < riddleChance) {
    return (['quiz', ...others.take(patternChoices - 1)]..shuffle(r));
  }
  return others.take(patternChoices).toList();
}

typedef Draft = (List<Json>, Json?);

/// Write -> fact check -> review, rewriting with feedback while below the threshold.
/// Returns the best (lines, review) or null when no draft survives the fact check.
Future<Draft?> writeDialogue(Claude llm, Json spot, Character specialist, List<Json> facts,
    {List<String>? patternIds, List<String> told = const [], String lang = 'ja'}) async {
  final c = llm.config;
  final names = {commander.id: commander.nameIn(lang), specialist.id: specialist.nameIn(lang)};
  Draft? best;
  Json? feedback;
  final attempts = 1 + (c.reviewEnabled ? c.reviewRewrites : 0);
  var pats = patternIds ?? pickPatterns(specialist);
  for (var attempt = 0; attempt < attempts; attempt++) {
    final draft = await llm.json(dialogueSystem(specialist, patternIds: pats, lang: lang),
        dialogueUser(spot, facts, feedback: feedback, told: told, lang: lang), dialogueSchema(specialist.id, pats),
        c.effortDialogue);
    final rawLines = ((draft['lines'] as List?) ?? const []).cast<Json>();
    final pattern = draft['pattern'] as String?;
    if (pats.contains(pattern)) pats = [pattern!]; // a rewrite keeps the shape the writer chose
    final check = await llm.json(checkSystem, checkUser(facts, rawLines, told: told), checkSchema, c.effortCheck, check: true);
    final lines = buildLines(rawLines, facts, specialist.id, check);
    final flagged = checkIssues(rawLines, check);
    if (lines.where((l) => l['speaker'] == specialist.id && (l['source_ids'] as List).isNotEmpty).length < 2) {
      feedback = {
        'lines': rawLines,
        'score': 1,
        'issues': flagged.isNotEmpty ? flagged : ['事実カードで裏付けられないセリフが多く、ほとんど削除された。カードの事実だけで書くこと'],
      };
      continue;
    }
    Json? r;
    if (c.reviewEnabled) {
      r = await rv.review(llm, lines, names, specialist.nameIn(lang), pattern: pattern, lang: lang);
      r['attempt'] = attempt + 1;
      r['pattern'] = pattern;
      r['removed_lines'] = flagged.length;
      // Deleted lines leave gaps in the back-and-forth: rank such a draft below a clean one.
      r['score'] = ((math.max(1.0, (r['score'] as num) - rv.rulePenalty * flagged.length)) * 100).round() / 100;
    }
    if (best == null || (r != null && best.$2 != null && (r['score'] as num) > (best.$2!['score'] as num))) {
      best = (lines, r);
    }
    // Flagged lines were deleted from this draft; prefer rewriting them over shipping a gap.
    if (r == null || ((r['score'] as num) >= c.reviewThreshold && flagged.isEmpty)) break;
    feedback = {
      'lines': flagged.isNotEmpty ? rawLines : lines,
      'score': r['score'],
      'issues': [...flagged, ...(r['issues'] as List).cast<String>()].take(6).toList().ifEmpty(['もっと自然で面白くする']),
    };
  }
  return best;
}

extension<T> on List<T> {
  List<T> ifEmpty(List<T> other) => isEmpty ? other : this;
}

double _score(Draft? d) => d == null ? -1.0 : ((d.$2?['score'] ?? 3.0) as num).toDouble();

/// [told]: what was said at this place before (a revisit): research and writing look for something else.
/// [lang]: language of the dialogue ('ja' or 'en'). Research reads sources in any language (the local
/// Wikipedia abroad, web pages) and writes the fact cards in Japanese either way.
Future<Json> generate(Claude llm, Json spot, String theme,
    {Json? image, List<String> told = const [], String lang = 'ja'}) async {
  final c = llm.config;
  final specialist = specialists[theme]!;
  final canEscalate = c.escalateResearchModel.isNotEmpty && c.escalateResearchModel != c.researchModel;
  var escalated = false;

  var (facts, sources) = await collectFacts(llm, spot, theme, told: told);
  // Few facts from the cheap model: look again with the stronger one before writing anything.
  if (canEscalate && facts.length < c.escalateMinFacts) {
    final (f2, s2) = await collectFacts(llm, spot, theme, model: c.escalateResearchModel, told: told);
    escalated = true;
    if (f2.length > facts.length) (facts, sources) = (f2, s2);
  }
  if (facts.length < c.minFacts) throw Unavailable('insufficient_sources');

  var result = await writeDialogue(llm, spot, specialist, facts, told: told, lang: lang);
  // Still below the bar with the cheap model's facts: richer facts from the stronger model, one more try.
  if (canEscalate && !escalated && c.reviewEnabled && _score(result) < c.reviewThreshold) {
    final (f2, s2) = await collectFacts(llm, spot, theme, model: c.escalateResearchModel, told: told);
    escalated = true;
    if (f2.length >= c.minFacts) {
      final result2 = await writeDialogue(llm, spot, specialist, f2, told: told, lang: lang);
      if (_score(result2) > _score(result)) (result, facts, sources) = (result2, f2, s2);
    }
  }
  if (result == null) throw Unavailable('check_failed');
  final (lines, review) = result;
  review?['escalated'] = escalated;
  final used = {for (final l in lines) ...(l['source_ids'] as List).cast<int>()};
  return {
    'spot': {
      'id': spot['id'],
      'name': lang == 'en' && (spot['name_en'] ?? '') != '' ? spot['name_en'] : spot['name'],
      'lat': spot['lat'],
      'lon': spot['lon'],
      'kind': spot['kind'] ?? 'spot',
    },
    'lang': lang,
    'theme': theme,
    'specialist': {'id': specialist.id, 'name': specialist.nameIn(lang), 'frequency': specialist.frequency},
    'commander': {'id': commander.id, 'name': commander.nameIn(lang), 'frequency': commander.frequency},
    'lines': lines,
    'sources': [for (final s in sources) if (used.contains(s['id'])) s],
    'image': image,
    'review': review,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
  };
}

Json withCodename(Json dialogue, String codename) {
  var name = codename.trim();
  if (name.length > 20) name = name.substring(0, 20);
  if (name.isEmpty) name = dialogue['lang'] == 'en' ? 'Walker' : 'ウォーカー';
  return {
    ...dialogue,
    'lines': [
      for (final l in (dialogue['lines'] as List).cast<Json>())
        {...l, 'text': (l['text'] as String).replaceAll(codenamePlaceholder, name)},
    ],
  };
}
