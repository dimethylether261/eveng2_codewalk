/// Prompts for the LLM steps (research, dialogue, check). Texts live in texts.dart.
library;

import 'dart:convert';

import 'characters.dart';
import 'texts.dart';
import 'util.dart';

const codenamePlaceholder = '{{CODENAME}}';
const _indent = JsonEncoder.withIndent(' ');

/// What each specialist looks for in the "今日は何の日" chat call (not tied to a place).
const chatFocus = <String, String>{
  'history': 'この日付に起きた歴史上の出来事、歴史上の人物の誕生日や命日',
  'architecture': 'この日付に完成・開業・開通した建物・橋・駅・道路など、建築や土木にちなむ記念日',
  'nature': 'この日付にちなむ自然・天文・気象・季節の記念日や出来事、動植物や化石の発見',
  'placename': 'この日付の記念日の名前の由来や語呂合わせ、言葉や地名にちなむ記念日',
  'film': 'この日付にちなむアニメ・映画・漫画・ドラマ・音楽の話題（公開日・放送開始日・連載開始・曲の発売日・作者や声優・監督・ミュージシャンの誕生日・記念日など）。'
      '小説だけの話題は使わない（映画化・アニメ化・漫画化された作品なら、その映像や漫画の話として使ってよい）',
  'tech': 'この日付にちなむ発明・技術・製品の発表、技術や通信・鉄道にちなむ記念日',
  'food': 'この日付にちなむ食べ物・飲み物の記念日、食文化にちなむ出来事',
};

/// What was already said at a place, for a revisit (research looks for other facts, the dialogue
/// talks about something else).
String _toldNote(List<String> told, String instruction) =>
    told.isEmpty ? '' : '\n\n$instruction\n${told.map((t) => '- $t').join('\n')}';

String researchUser(Json spot, String theme, String? wikiUrl, {List<String> told = const []}) =>
    _researchBase(spot, theme, wikiUrl) +
    _toldNote(told, '前回までにこの場所で話した内容（これとは違う事実を集める。同じ話題の言い換えもしない）:');

String _researchBase(Json spot, String theme, String? wikiUrl) {
  final tags = (spot['_tags'] as Map?) ?? const {};
  if (spot['kind'] == 'chat') {
    return [
      '雑談の話題: 今日（${tags['date']}）は何の日',
      '知りたい観点: ${chatFocus[theme] ?? chatFocus['history']}',
      '場所とは関係のない話題。この日付にちなむ出来事だけを集め、別の日付の話は使わない。',
      if (themeRules.containsKey(theme)) '注意: ${themeRules[theme]}',
      wikiUrl != null ? 'まずこのページを取得して読む: $wikiUrl' : 'Web検索で情報を探す。',
    ].join('\n');
  }
  if (spot['kind'] == 'area') {
    final town = '${tags['city'] ?? ''} ${spot['name']}'.trim();
    return [
      '町: $town（特定の建物ではなく、この町全体についての雑学を集める）',
      '代表地点の座標: ${spot['lat']}, ${spot['lon']}',
      '知りたい観点: ${areaFocus[theme] ?? areaFocus['history']}（地元の人でも意外と知らないような話を優先）',
      if (themeRules.containsKey(theme)) '注意: ${themeRules[theme]}',
      varietyNote,
      wikiUrl != null ? 'まずこのページを取得して読む: $wikiUrl' : 'Web検索でこの町の情報を探す。',
    ].join('\n');
  }
  final addr = [for (final e in tags.entries) if ((e.key as String).startsWith('addr:')) e.value].join(' ');
  return [
    'スポット名: ${spot['name']}',
    '種類: ${spot['kind'] ?? ''}',
    '座標: ${spot['lat']}, ${spot['lon']}',
    if (addr.isNotEmpty) '住所: $addr',
    if (orgFocus.containsKey(spot['kind']))
      '知りたい観点: ${orgFocus[spot['kind']]}'
    else
      '知りたい観点: ${themeFocus[theme] ?? ''}（観点に合う事実を優先。なければ他の事実でもよい）',
    if (themeRules.containsKey(theme)) '注意: ${themeRules[theme]}',
    varietyNote,
    wikiUrl != null ? 'まずこのページを取得して読む: $wikiUrl' : 'Web検索でこのスポットの情報を探す。',
  ].join('\n');
}

String _fill(String s, {required String sp, String? c, String cn = codenamePlaceholder}) =>
    s.replaceAll('{c}', c ?? commander.name).replaceAll('{sp}', sp).replaceAll('{cn}', cn);

/// Dialogue languages. Fact cards are always written in Japanese (from sources in any language);
/// the dialogue itself is written in the user's language.
const languages = {'ja', 'en'};

/// Extra instructions for an English dialogue (the rest of the system prompt stays Japanese).
const _englishNote = '''

出力言語: 英語（English）
- セリフはすべて自然な英語で書く。事実カードは日本語なので、意味を変えずに英語にして使う。
- 地名・寺社名などの固有名詞は、英語名が与えられていればそれを、なければ一般的なローマ字表記（例: Shinagawa Shrine）を使う。
- 上の日本語の口調の指定（語尾など）は英語に置き換え、各キャラクターの説明にある英語の話し方に従う。
- 長さ: 1セリフは1〜2文、20語程度まで。
- ユーザーのコードネームは日本語と同じく必ず「{{CODENAME}}」と書く。''';

String dialogueSystem(Character specialist, {List<String>? patternIds, String lang = 'ja'}) {
  final theme = specialists.entries.where((e) => e.value.id == specialist.id).firstOrNull?.key ?? '';
  final themeRule = themeRules.containsKey(theme) ? '- ${themeRules[theme]}\n' : '';
  final sp = specialist.nameIn(lang);
  final patternText = (patternIds ?? patterns.keys.toList()).map((id) {
    final p = patterns[id]!;
    return _fill('- $id（${p.name}）: ${p.how}\n  流れの例: ${p.example.join(' → ')}', sp: sp, c: commander.nameIn(lang));
  }).join('\n');
  final text = dialogueSystemTemplate
      .replaceAll('__CID__', commander.id)
      .replaceAll('__CROLE__', commander.roleIn(lang))
      .replaceAll('__CPERSONA__', commander.personaIn(lang))
      .replaceAll('__C__', commander.nameIn(lang))
      .replaceAll('__SPID__', specialist.id)
      .replaceAll('__SP__', sp)
      .replaceAll('__ROLE__', specialist.roleIn(lang))
      .replaceAll('__PERSONA__', specialist.personaIn(lang))
      .replaceAll('__LINES__', dialogueLines)
      .replaceAll('__CHARS__', '$lineChars')
      .replaceAll('__FACTS__', factsPerDialogue)
      .replaceAll('__THEME_RULE__', themeRule)
      .replaceAll('__PATTERNS__', patternText);
  return lang == 'en' ? text + _englishNote : text;
}

List<Json> _cards(List<Json> facts) =>
    [for (final f in facts) {'fact_id': f['id'], '事実': f['claim'], '出典の原文': f['quote']}];

String dialogueUser(Json spot, List<Json> facts,
    {Json? feedback, List<String> told = const [], String lang = 'ja'}) {
  final chat = spot['kind'] == 'chat';
  final nameEn = spot['name_en'] as String?;
  if (lang == 'en' && nameEn != null && nameEn.isNotEmpty) spot = {...spot, 'name': '${spot['name']}（英語名: $nameEn）'};
  var text = chat
      ? '話題: ${spot['name']}（場所とは関係のない、散歩中のちょっとした雑談の無線）\n\n事実カード:\n${_indent.convert(_cards(facts))}'
          '\n\nこれは場所の無線ではありません。最初の呼びかけでは場所の名前を出さず、「少し雑談でもするか」のように切り出してください。'
          '今日の日付にちなむ出来事や人物・作品についての事実はこのカードだけを使い、あとは自由に雑談して会話を書いてください。'
      : 'スポット: ${spot['name']}\n\n事実カード:\n${_indent.convert(_cards(facts))}'
          '\n\nこの場所についての事実はこのカードだけを使い、あとは自由に雑談して会話を書いてください。';
  text += _toldNote(told, '前回までにこの場所で話した内容（同じ話はしない。前に聞いたことがあるとわかる切り出しにしてもよい）:');
  if (lang == 'en') text += '\n\n会話は英語で書いてください（English）。';
  if (feedback != null) {
    final prev = [
      for (final l in (feedback['lines'] as List).cast<Json>()) {'speaker': l['speaker'], 'text': l['text']},
    ];
    text += '\n\n前回の案（編集者の評価は5点満点で ${feedback['score']}）:\n${_indent.convert(prev)}'
        '\n\n直すべき点:\n${(feedback['issues'] as List).map((x) => '- $x').join('\n')}'
        '\n\n上の点を直して、もう一度最初から書いてください。事実のルールは同じです。';
  }
  return text;
}

Json dialogueSchema(String specialistId, List<String> patternIds) => {
      'type': 'object',
      'properties': {
        'lines': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'speaker': {
                'type': 'string',
                'enum': [commander.id, specialistId],
              },
              'text': {'type': 'string'},
              'fact_ids': {
                'type': 'array',
                'items': {'type': 'integer'},
              },
            },
            'required': ['speaker', 'text', 'fact_ids'],
            'additionalProperties': false,
          },
        },
        'pattern': {'type': 'string', 'enum': patternIds},
      },
      'required': ['pattern', 'lines'],
      'additionalProperties': false,
    };

/// [told]: what was said at this place before (a revisit), so the check can catch a repeat.
String checkUser(List<Json> facts, List<Json> lines, {List<String> told = const []}) {
  final numbered = [
    for (var i = 0; i < lines.length; i++) {'index': i, 'speaker': lines[i]['speaker'], 'text': lines[i]['text']},
  ];
  return '事実カード:\n${_indent.convert(_cards(facts))}\n\n会話:\n${_indent.convert(numbered)}'
      '${_toldNote(told, '前回までにこの場所で話した内容:')}\n\nすべてのセリフを判定してください。';
}

final checkSchema = jsonDecode(checkSchemaJson) as Json;
