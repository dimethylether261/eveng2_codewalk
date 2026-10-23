import 'package:codewalk/models.dart';
import 'package:codewalk/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('any number of themes can be tuned; at least one stays on; food needs the age check', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppSettings.forTest(await SharedPreferences.getInstance());
    expect(s.themes, defaultThemes);
    for (final t in ['placename', 'film', 'tech']) {
      expect(s.setTheme(t, true), isTrue);
    }
    expect(s.themes.length, 6); // no upper limit
    expect(s.setTheme('food', true), isFalse); // 20+ not confirmed yet
    s.adultConfirmed = true;
    expect(s.setTheme('food', true), isTrue);
    expect(s.themes.toSet(), themeLabels.keys.toSet());
    for (final t in themeLabels.keys.toList().sublist(1)) {
      s.setTheme(t, false);
    }
    expect(s.setTheme(themeLabels.keys.first, false), isFalse); // the last one stays
    expect(s.themes, [themeLabels.keys.first]);
  });

  test('a retired theme in saved settings is dropped, never leaving none tuned', () async {
    SharedPreferences.setMockInitialValues({'themes': ['infrastructure']});
    final s = AppSettings.forTest(await SharedPreferences.getInstance());
    expect(s.themes, defaultThemes);
    SharedPreferences.setMockInitialValues({'themes': ['infrastructure', 'tech']});
    expect(AppSettings.forTest(await SharedPreferences.getInstance()).themes, ['tech']);
  });

  test('the map pin period is remembered; today by default', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s = AppSettings.forTest(prefs);
    expect(s.pinRange, LogRange.today);
    s.pinRange = LogRange.week;
    expect(AppSettings.forTest(prefs).pinRange, LogRange.week);
    SharedPreferences.setMockInitialValues({'pinRange': 'bogus'});
    expect(AppSettings.forTest(await SharedPreferences.getInstance()).pinRange, LogRange.today);
  });
}
