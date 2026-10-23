/// JavaScript entry for the glasses app: `dart compile js` turns this into g2/public/codewalk_core.js,
/// which defines `globalThis.createCodewalkCore(host, storeJson, logJson, settingsJson)`.
/// See g2/src/local.ts for the TypeScript side (types in g2/src/core.d.ts).
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../log_book.dart';
import 'walk_core.dart';

/// The host object passed in from TypeScript.
extension type JsHost(JSObject _) implements JSObject {
  external void changed();
  external JSPromise<JSAny?> save(String key, String value);
  external void spend(double usd);
  external void debug(String message);
}

class _Host implements CoreHost {
  _Host(this.js);
  final JsHost js;

  @override
  void changed() => js.changed();

  @override
  Future<void> save(String key, String value) => js.save(key, value).toDart;

  @override
  void spend(double usd) => js.spend(usd);

  @override
  void debug(String message) => js.debug(message);
}

@JSExport()
class CoreApi {
  CoreApi(this._core);
  final WalkCore _core;

  void settings(String json) => _core.updateSettings(CoreSettings.fromJson(jsonDecode(json) as Map<String, dynamic>));
  void position(double lat, double lon, double speed) => _core.position(lat, lon, speed);
  void start() => _core.start();
  void stop() => _core.stop();
  bool walking() => _core.walking;
  JSPromise<JSAny?> command(String cmd) => _core.command(cmd).toJS;
  JSPromise<JSAny?> replay(String id) => _core.replay(id).toJS;
  String state() => jsonEncode(_core.g2State());
  String roads() => jsonEncode(_core.minimap.roadsJson());
  /// [range]: 'today' | 'week' | 'all' (anything else: all).
  String log(String range) =>
      jsonEncode(_core.logList(range: LogRange.values.firstWhere((r) => r.name == range, orElse: () => LogRange.all)));
  String catalog() => jsonEncode(_core.catalog());
  JSPromise<JSString> checkKey() => _core.checkKey().then((r) => r.toJS).toJS;
  JSPromise<JSAny?> flush() => _core.flush().toJS;
  int cachedDialogues() => _core.cachedDialogues;
  int logCount() => _core.log.entries.length;
  JSPromise<JSAny?> clearLog() => _core.clearLog().toJS;
  JSPromise<JSAny?> clearCache() => _core.clearCache().toJS;
}

JSObject _create(JsHost host, String storeJson, String logJson, String settingsJson) {
  final core = WalkCore(
    _Host(host),
    storeJson: storeJson,
    logJson: logJson,
    settings: CoreSettings.fromJson(jsonDecode(settingsJson.isEmpty ? '{}' : settingsJson) as Map<String, dynamic>),
  );
  return createJSInteropWrapper(CoreApi(core));
}

void main() {
  globalContext['createCodewalkCore'] = _create.toJS;
}
