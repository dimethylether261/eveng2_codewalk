import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'engine/claude.dart';
import 'engine/engine.dart';
import 'engine/store.dart';
import 'engine/store_file.dart';
import 'stores.dart';

/// Owns the on-device engine and rebuilds it when the key or source settings change.
/// The cache (spots, dialogues) is shared across rebuilds.
class BackendHost {
  BackendHost._(this.settings, this._store) {
    _rebuild();
    settings.addListener(_onSettings);
  }

  static Future<BackendHost> create(AppSettings settings) async {
    final dir = await getApplicationSupportDirectory();
    return BackendHost._(settings, await openStore('${dir.path}/engine_cache.json'));
  }

  final AppSettings settings;
  final Store _store;
  late Engine _engine;
  String _signature = '', _apiKey = '';

  String get _currentSignature =>
      '${settings.apiKey}|${settings.restrictSources}|${settings.userAgent}';

  void _rebuild() {
    _signature = _currentSignature;
    _apiKey = settings.apiKey;
    _engine = Engine(
      store: _store,
      apiKey: settings.apiKey,
      userAgent: settings.userAgent,
      config: EngineConfig(allowedDomains: settings.restrictSources ? restrictedDomains : const []),
      log: (m) => debugPrint('[engine] $m'),
      onUsage: (u) {
        final usd = u['usd'];
        if (usd is num) settings.addSpend(usd.toDouble());
      },
    );
  }

  void _onSettings() {
    if (_currentSignature == _signature) return;
    if (settings.apiKey != _apiKey) _store.forgetKeyErrors();
    _rebuild();
  }

  Engine get engine => _engine;

  /// The backend the walk uses right now: a developer server if one is set, else on device.
  Backend get backend => settings.serverUrl.isNotEmpty ? ApiClient(settings.serverUrl) : LocalBackend(_engine);

  Future<void> flush() => _store.flush();

  /// How many conversations are cached on this phone.
  int get cachedDialogues => _store.dialogueCount;

  Future<void> clearCache() => _engine.clearCache();
}
