import 'package:codewalk/screens/ai_notice.dart';
import 'package:codewalk/stores.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('start-up notice: AI-generated, may be inaccurate; can be hidden for good', (tester) async {
    SharedPreferences.setMockInitialValues({'lang': 'ja'});
    final settings = AppSettings.forTest(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => showAiNotice(context, settings), child: const Text('go'))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI'), findsOneWidget);
    expect(find.textContaining('不正確な情報が含まれる可能性'), findsOneWidget);
    await tester.tap(find.text('わかりました'));
    await tester.pumpAndSettle();
    expect(settings.aiNoticeHidden, isFalse); // shown again next time

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今後は表示しない'));
    await tester.tap(find.text('わかりました'));
    await tester.pumpAndSettle();
    expect(settings.aiNoticeHidden, isTrue);
  });

  testWidgets('the notice follows the language setting', (tester) async {
    SharedPreferences.setMockInitialValues({'lang': 'en'});
    final settings = AppSettings.forTest(await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => showAiNotice(context, settings), child: const Text('go'))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('may contain inaccurate information'), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
  });
}
