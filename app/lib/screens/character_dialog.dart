import 'package:flutter/material.dart';

import '../radio_widgets.dart';
import '../l10n.dart';

/// What users read about a character (the prompt-side persona lives in engine/characters.dart;
/// keep the two consistent when a character changes).
class CharacterProfile {
  const CharacterProfile({
    required this.id,
    required this.name,
    required this.frequency,
    required this.role,
    required this.bio,
  });

  final String id, name, frequency, role, bio;
}

const commanderProfile = CharacterProfile(
  id: 'ootori',
  name: 'シレイ',
  frequency: '147.20',
  role: '司令（いつもの聞き役）',
  bio: '帽子にサングラス、パイプがトレードマークの年長の指揮官。任務口調だが、雑学には素直に感心する。少し天然で、担当たちには振り回されがち。',
);

/// By theme (same keys as themeLabels).
const characterProfiles = <String, CharacterProfile>{
  'history': CharacterProfile(
    id: 'shiori',
    name: 'フクロウ',
    frequency: '146.35',
    role: '歴史・史跡担当',
    bio: '物知りな年寄りのフクロウの先生。点の事実を、時代の流れにつなげて話すのが得意。夜型で、昼間はちょっと眠そう。シレイとは先生と生徒のような間柄。',
  ),
  'architecture': CharacterProfile(
    id: 'tetsu',
    name: 'スフィンクス',
    frequency: '147.65',
    role: '建築・土木担当',
    bio: '大昔から建物を見てきたスフィンクス。普段は無口だが、構造の話になると止まらなくなる。百年前を「つい最近」と言う。ときどき神話のように謎かけを出してくる。シレイとは昔からの同僚で、遠慮がない。',
  ),
  'nature': CharacterProfile(
    id: 'midori',
    name: 'キョウリュウ',
    frequency: '146.70',
    role: '自然・地形担当',
    bio: '化石……なのになぜか話せる。のんびり屋でマイペースで、数百年を「ほんの少し前」と言う。地中に埋もれていただけあって地形に詳しい。',
  ),
  'placename': CharacterProfile(
    id: 'kotoha',
    name: 'キツネ',
    frequency: '148.05',
    role: '地名・言葉担当',
    bio: 'お稲荷さんゆかりの、はんなりした京言葉のキツネ。言葉や名前の機微に通じていて、思わせぶりな言い方でシレイを化かすのが好き。由来に諸説あるときは、言い切らずに「〜という説がある」と話す慎重派。',
  ),
  'film': CharacterProfile(
    id: 'rei',
    name: 'サル',
    frequency: '146.90',
    role: 'アニメ・映画・音楽担当',
    bio: 'ヘッドホンが手放せない、映画・アニメ・漫画と音楽が大好きなサル。元気でせっかち。作品へのリスペクトは人一倍で、ネタバレは絶対にしない。',
  ),
  'tech': CharacterProfile(
    id: 'gear',
    name: 'アザラシ',
    frequency: '147.45',
    role: 'ガジェット・テック担当',
    bio: 'ノートパソコンが手放せない、新しもの好きのアザラシ。陸ではのそのそしているが、仕組みの話になると止まらない。防水かどうかがつい気になる。特定の商品の宣伝はしない主義。',
  ),
  'food': CharacterProfile(
    id: 'kagura',
    name: 'ネコ',
    frequency: '148.30',
    role: '酒・食文化担当（20歳以上）',
    bio: 'コック帽がトレードマークの、食文化の語り部のネコ。おおらかで面倒見がいい。猫舌だけど、食べ物の話は大好き。飲酒や来店はすすめず、歴史や文化として話す。',
  ),
};

/// Radio-style card: a large portrait and who the character is.
const commanderProfileEn = CharacterProfile(
  id: 'ootori',
  name: 'Commander',
  frequency: '147.20',
  role: 'Commander (always opens the call)',
  bio: "A veteran commander with a cap, sunglasses and a pipe. Talks like he's on a mission, but is honestly impressed "
      'by trivia, and a little absent-minded. The specialists tend to run circles around him.',
);

const characterProfilesEn = <String, CharacterProfile>{
  'history': CharacterProfile(id: 'shiori', name: 'Owl', frequency: '146.35', role: 'History & heritage',
      bio: 'A wise old owl professor. Loves turning single facts into the story of how history flowed. '
          'Treats the Commander like a student.'),
  'architecture': CharacterProfile(id: 'tetsu', name: 'Sphinx', frequency: '147.65', role: 'Architecture & engineering',
      bio: "A sphinx who has watched buildings for thousands of years. Usually quiet, but can't stop once structures "
          "come up. Now and then poses a riddle, as sphinxes do. An old colleague of the Commander, and not shy with him."),
  'nature': CharacterProfile(id: 'midori', name: 'Dino', frequency: '146.70', role: 'Nature & terrain',
      bio: 'A fossil... that somehow talks. Laid-back and in no hurry. Having been buried in the ground, '
          'it knows the lay of the land.'),
  'placename': CharacterProfile(id: 'kotoha', name: 'Fox', frequency: '148.05', role: 'Place names & words',
      bio: 'An elegant fox from the Inari shrines with a soft Kyoto manner. Knows the nuances of names and loves '
          'leading the Commander on before revealing the trick. Careful, too: when a name has several origin stories, it says so.'),
  'film': CharacterProfile(id: 'rei', name: 'Monkey', frequency: '146.90', role: 'Anime, film & music',
      bio: 'A monkey who never takes off its headphones and loves films, anime, manga and music. Hyper and '
          'impatient. Deeply respects the works, and never spoils them.'),
  'tech': CharacterProfile(id: 'gear', name: 'Seal', frequency: '147.45', role: 'Gadgets & tech',
      bio: "A gadget-loving seal glued to its laptop. Can't stop talking about how things work. Never advertises products."),
  'food': CharacterProfile(id: 'kagura', name: 'Cat', frequency: '148.30', role: 'Sake & food culture (20+)',
      bio: "A cat in a chef's hat who tells stories of food culture. Warm and caring. Never pushes drinking or "
          "shopping: it's all history and culture."),
};

/// Profiles in the app's language.
CharacterProfile get commanderProfileNow => t.lang == 'en' ? commanderProfileEn : commanderProfile;
Map<String, CharacterProfile> get characterProfilesNow => t.lang == 'en' ? characterProfilesEn : characterProfiles;

Future<void> showCharacterProfile(BuildContext context, CharacterProfile p) => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: radioBg,
        shape: const RoundedRectangleBorder(side: BorderSide(color: radioGreen, width: 1.5)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Center(child: Portrait(p.id, width: 200)),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(p.name, style: const TextStyle(color: radioText, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Text(p.frequency, style: mono.copyWith(color: radioGreen, fontSize: 16)),
            ]),
            Text(p.role, style: const TextStyle(color: radioDim, fontSize: 13)),
            const Divider(color: radioBorder, height: 24),
            Text(p.bio, style: const TextStyle(color: radioText, fontSize: 14, height: 1.6)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).closeButtonLabel, style: const TextStyle(color: radioGreen)),
              ),
            ),
          ]),
        ),
      ),
    );
