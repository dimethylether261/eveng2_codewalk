import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'g2_bridge.dart' show newPairingCode;
import 'l10n.dart';
import 'log_book.dart';
import 'models.dart';

export 'log_book.dart' show CallFrequency, LogQueries, LogRange;

/// The phone's language if supported, else English.
String systemLang() => langOf(PlatformDispatcher.instance.locale.languageCode);

class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs, this._secure, this._apiKey);

  final SharedPreferences _prefs;
  final FlutterSecureStorage? _secure;
  String _apiKey;

  static const _apiKeyName = 'anthropicApiKey';

  static Future<AppSettings> load() async {
    const secure = FlutterSecureStorage();
    String key;
    try {
      key = await secure.read(key: _apiKeyName) ?? '';
    } catch (_) {
      key = ''; // keystore unavailable: ask again
    }
    final prefs = await SharedPreferences.getInstance();
    // Until 2026-10 the app always used a PC server; switch old installs to the on-device engine once.
    if (prefs.getBool('migratedToLocal') != true) {
      await prefs.remove('serverUrl');
      await prefs.setBool('migratedToLocal', true);
    }
    setLang(prefs.getString('lang') ?? systemLang());
    return AppSettings(prefs, secure, key);
  }

  /// For tests: settings without the platform keystore.
  @visibleForTesting
  AppSettings.forTest(this._prefs, [this._apiKey = '']) : _secure = null {
    setLang(lang);
  }

  /// The user's own Claude API key, kept in the Android keystore (never in shared preferences).
  String get apiKey => _apiKey;
  Future<void> setApiKey(String v) async {
    _apiKey = v.trim();
    await _secure?.write(key: _apiKeyName, value: _apiKey.isEmpty ? null : _apiKey);
    notifyListeners();
  }

  /// Optional contact (email or URL) for the User-Agent that Wikipedia/OpenStreetMap ask for.
  String get contact => _prefs.getString('contact') ?? '';
  set contact(String v) {
    _prefs.setString('contact', v.trim());
    notifyListeners();
  }

  String get userAgent =>
      'CodeWalk/0.1 (personal app; ${contact.isEmpty ? 'https://www.mediawiki.org/wiki/API:Etiquette' : contact})';

  /// true: research reads only Wikipedia and the Agency for Cultural Affairs. false: any site.
  bool get restrictSources => _prefs.getBool('restrictSources') ?? false;
  set restrictSources(bool v) {
    _prefs.setBool('restrictSources', v);
    notifyListeners();
  }

  /// Developer option: use a CodeWalk server instead of the on-device engine. Empty = on device.
  String get serverUrl => _prefs.getString('serverUrl') ?? '';
  set serverUrl(String v) {
    _prefs.setString('serverUrl', v.trim().replaceAll(RegExp(r'/+$'), ''));
    notifyListeners();
  }

  static String _month(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

  /// Estimated Claude API spend this month (USD), summed from each generation's usage.
  double get spentThisMonth => _prefs.getDouble('spend:${_month(DateTime.now())}') ?? 0;
  void addSpend(double usd) {
    final k = 'spend:${_month(DateTime.now())}';
    _prefs.setDouble(k, (_prefs.getDouble(k) ?? 0) + usd);
    notifyListeners();
  }

  /// App and dialogue language ('ja' / 'en'); defaults to the phone's language.
  String get lang => _prefs.getString('lang') ?? systemLang();
  set lang(String v) {
    _prefs.setString('lang', v);
    setLang(v);
    notifyListeners();
  }

  String get codename => _prefs.getString('codename') ?? t.defaultCodename;
  set codename(String v) {
    _prefs.setString('codename', v.trim().isEmpty ? t.defaultCodename : v.trim());
    notifyListeners();
  }

  List<String> get themes {
    // Drops themes that no longer exist (暮らし・インフラ was retired); never leaves none tuned.
    final t = (_prefs.getStringList('themes') ?? defaultThemes).where(themeLabels.containsKey).toList();
    return t.isEmpty ? List.of(defaultThemes) : t;
  }

  /// Returns false when the change is not allowed (turning off the last theme, or an age-gated theme).
  bool setTheme(String theme, bool on) {
    final t = themes.where((e) => e != theme).toList();
    if (on) t.add(theme);
    if (t.isEmpty) return false; // keep at least one frequency tuned
    if (on && adultThemes.contains(theme) && !adultConfirmed) return false;
    _prefs.setStringList('themes', t);
    notifyListeners();
    return true;
  }

  /// The user confirmed they are 20 or older (needed for the 酒・食文化 theme).
  bool get adultConfirmed => _prefs.getBool('adultConfirmed') ?? false;
  set adultConfirmed(bool v) {
    _prefs.setBool('adultConfirmed', v);
    notifyListeners();
  }

  CallFrequency get frequency =>
      CallFrequency.values.firstWhere((e) => e.name == _prefs.getString('frequency'), orElse: () => CallFrequency.normal);
  set frequency(CallFrequency v) {
    _prefs.setString('frequency', v.name);
    notifyListeners();
  }

  /// Serve calls to the CODEWALK app on Even G2 (local link on this phone only).
  bool get g2Enabled => _prefs.getBool('g2Enabled') ?? true;
  set g2Enabled(bool v) {
    _prefs.setBool('g2Enabled', v);
    notifyListeners();
  }

  /// The pairing code the glasses app sends with every request (made on first use).
  String get g2Code {
    final saved = _prefs.getString('g2Code');
    if (saved != null && saved.isNotEmpty) return saved;
    final code = newPairingCode();
    _prefs.setString('g2Code', code);
    return code;
  }

  /// A new pairing code: the glasses must be paired again.
  void renewG2Code() {
    _prefs.setString('g2Code', newPairingCode());
    notifyListeners();
  }

  /// The "conversations are AI-generated and may be inaccurate" notice at start-up was dismissed for good.
  bool get aiNoticeHidden => _prefs.getBool('aiNoticeHidden') ?? false;
  set aiNoticeHidden(bool v) {
    _prefs.setBool('aiNoticeHidden', v);
    notifyListeners();
  }

  /// Which calls get a pin on the walk map and the glasses minimap.
  LogRange get pinRange => LogRange.values.asNameMap()[_prefs.getString('pinRange')] ?? LogRange.today;
  set pinRange(LogRange v) {
    _prefs.setString('pinRange', v.name);
    notifyListeners();
  }

  /// Developer mode: long-press the map to move the simulated position.
  bool get simulate => _prefs.getBool('simulate') ?? false;
  set simulate(bool v) {
    _prefs.setBool('simulate', v);
    notifyListeners();
  }
}

/// Received radio calls, stored as a JSON file on the device (never sent to the server).
class LogStore extends ChangeNotifier with LogQueries {
  LogStore(this._file, this.entries);

  final File _file;
  @override
  final List<LogEntry> entries;

  static Future<LogStore> load() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/radio_log.json');
    var entries = <LogEntry>[];
    if (await f.exists()) {
      try {
        entries = (jsonDecode(await f.readAsString()) as List)
            .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        entries = [];
      }
    }
    return LogStore(f, entries);
  }

  Future<LogEntry> add(Dialogue d, {required bool played, double? heardLat, double? heardLon}) async {
    final e = newEntry(d, played: played, heardLat: heardLat, heardLon: heardLon);
    await _save();
    return e;
  }

  /// Delete every call (the settings screen's "delete the call log").
  Future<void> clear() async {
    entries.clear();
    await _save();
  }

  Future<void> markPlayed(LogEntry e) async {
    e.played = true;
    await _save();
  }

  Future<void> _save() async {
    await _file.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
    notifyListeners();
  }
}
