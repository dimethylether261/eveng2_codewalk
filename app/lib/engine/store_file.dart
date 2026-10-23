/// The engine cache as a JSON file on the phone.
library;

import 'dart:io';

import 'store.dart';

/// [path] null = in memory only (tests).
Future<Store> openStore(String? path) async {
  if (path == null) return Store.fromJson(null);
  final file = File(path);
  String? json;
  if (await file.exists()) {
    try {
      json = await file.readAsString();
    } catch (_) {
      json = null;
    }
  }
  return Store.fromJson(json, persist: (data) async {
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(data);
    await tmp.rename(path);
  });
}
