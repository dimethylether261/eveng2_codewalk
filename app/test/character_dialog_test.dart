import 'package:codewalk/engine/characters.dart' as engine;
import 'package:codewalk/l10n.dart';
import 'package:codewalk/models.dart';
import 'package:codewalk/screens/character_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => setLang('ja'));

  test('profiles match the characters used for dialogue (names, frequencies, ids)', () {
    expect(characterProfiles.keys.toSet(), themeLabels.keys.toSet());
    for (final MapEntry(key: theme, value: p) in characterProfiles.entries) {
      final c = engine.specialists[theme]!;
      expect((p.id, p.name, p.frequency), (c.id, c.name, c.frequency), reason: theme);
      expect(themePortraits[theme], p.id);
    }
    expect((commanderProfile.id, commanderProfile.name, commanderProfile.frequency),
        (engine.commander.id, engine.commander.name, engine.commander.frequency));
  });

  testWidgets('tapping opens a card with a large portrait and the profile', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showCharacterProfile(context, characterProfiles['film']!),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('サル'), findsOneWidget);
    expect(find.text('146.90'), findsOneWidget);
    expect(find.textContaining('ヘッドホン'), findsOneWidget);
    expect(find.text('話し方'), findsNothing); // the card is about who they are, not how they talk
    await tester.tap(find.text('Close')); // the Material "close" label (English test locale)
    await tester.pumpAndSettle();
    expect(find.text('サル'), findsNothing);
  });

  test('English profiles match the English names used in English dialogues', () {
    for (final MapEntry(key: theme, value: p) in characterProfilesEn.entries) {
      expect((p.id, p.name), (engine.specialists[theme]!.id, engine.specialists[theme]!.nameEn), reason: theme);
    }
    expect(commanderProfileEn.name, engine.commander.nameEn);
    setLang('en');
    expect(characterProfilesNow['film']!.name, 'Monkey');
    expect(themeLabels['film'], 'Anime, film & music');
    setLang('ja');
    expect(characterProfilesNow['film']!.name, 'サル');
  });
}
