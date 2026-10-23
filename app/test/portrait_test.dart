import 'dart:io';

import 'package:codewalk/radio_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every character portrait renders to a PNG; unknown ids do not', (tester) async {
    // Set CODEWALK_PORTRAIT_OUT=<dir> to also write them out (e.g. to look at them).
    final out = Platform.environment['CODEWALK_PORTRAIT_OUT'];
    await tester.runAsync(() async {
      for (final id in portraitIds) {
        final png = await portraitPng(id);
        expect(png, isNotNull, reason: id);
        expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]); // PNG signature
        if (out != null) File('$out/${portraitFiles[id]}.png').writeAsBytesSync(png);
      }
      expect(await portraitPng('../etc/passwd'), isNull);
    });
  });
}
