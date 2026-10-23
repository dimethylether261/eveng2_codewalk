import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Local link for the CODEWALK Even Hub app (g2/), which runs inside the Even Realities app on
/// this phone and draws on the glasses.
///
/// Listens on 127.0.0.1 only (other devices can't reach it). Every request carries the pairing code
/// (`?t=`, shown in the settings and entered once in the glasses app), so a web page open in the
/// phone's browser can neither read the walk nor send commands; requests for another host name
/// (DNS rebinding) are refused too, and so is everything for a while after repeated wrong codes.
/// - `GET /hello`  `{"app":"codewalk"}`, without the code: lets the glasses app see that this app runs
/// - `GET /ws`     WebSocket: sends the state as JSON on every change, receives `{"cmd": ...}`
/// - `GET /state`  the same state once (fallback when WebSockets are dropped)
/// - `GET /cmd?c=` a command (fallback)
/// - `GET /roads`  roads for the minimap (fetched when the state's map.roadsVersion changes)
/// - `GET /photo`  the photo of the call being played (only that one: not a general proxy)
/// - `GET /portrait?id=` a character portrait (PNG)
/// Commands: answer, later, next, prev, end.
class G2Bridge {
  G2Bridge(
      {required this.state,
      required this.onCommand,
      required this.token,
      this.roads,
      this.photo,
      this.portrait,
      this.port = defaultPort});

  static const defaultPort = 8765;

  /// The pairing code the glasses app must send (see [normalizeCode]).
  final String Function() token;

  /// Wrong codes in a row before the bridge refuses everything for [lockout].
  static const maxFailures = 30;
  static const lockout = Duration(minutes: 5);
  int _failures = 0;
  DateTime? _lockedUntil;

  /// Current state for the glasses (see [G2State]).
  final Map<String, dynamic> Function() state;
  final void Function(String cmd) onCommand;
  final Map<String, dynamic> Function()? roads;

  /// Image bytes and content type of the current call's photo, or null.
  final Future<(List<int>, String)?> Function()? photo;

  /// PNG of a character portrait, or null for an unknown id.
  final Future<List<int>?> Function(String id)? portrait;
  final int port;

  HttpServer? _server;
  final _sockets = <WebSocket>{};
  String _last = '';

  bool get running => _server != null;
  int? get boundPort => _server?.port;
  int get clients => _sockets.length;

  /// Called when a glasses client connects or disconnects (for the settings screen).
  VoidCallback? onClients;

  /// Called when glasses connect (e.g. to fetch map data they will need).
  VoidCallback? onConnect;

  static const commands = {'answer', 'later', 'next', 'prev', 'end', 'walk'};

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
    _server = server;
    server.listen(_handle, onError: (Object e) => debugPrint('[g2] $e'));
  }

  Future<void> stop() async {
    for (final s in _sockets.toList()) {
      await s.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    onClients?.call();
  }

  void _cors(HttpResponse r) {
    // The Even app's WebView loads the glasses app from its own origin.
    r.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, OPTIONS')
      ..set('Cache-Control', 'no-store');
  }

  /// Why [req] is refused (an HTTP status), or null when it may go on.
  int? _refusal(HttpRequest req) {
    final host = req.headers.host;
    if (host != '127.0.0.1' && host != 'localhost') return HttpStatus.forbidden;
    if (req.uri.path == '/hello') return null;
    final locked = _lockedUntil;
    if (locked != null && DateTime.now().isBefore(locked)) return HttpStatus.tooManyRequests;
    if (!_sameCode(normalizeCode(req.uri.queryParameters['t'] ?? ''), normalizeCode(token()))) {
      if (++_failures >= maxFailures) {
        _failures = 0;
        _lockedUntil = DateTime.now().add(lockout);
      }
      return HttpStatus.unauthorized;
    }
    return null; // (a right code does not reset the count: it would let guesses slip in between)
  }

  /// Compares without stopping at the first difference.
  static bool _sameCode(String a, String b) {
    if (a.isEmpty || a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'OPTIONS') {
        final refused = _refusal(req);
        if (refused != null) {
          _cors(req.response);
          req.response.statusCode = refused;
          await req.response.close();
          return;
        }
      }
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _sockets.add(ws);
        onClients?.call();
        onConnect?.call();
        ws.add(_encode());
        ws.listen(
          (msg) {
            try {
              final cmd = (jsonDecode(msg as String) as Map)['cmd'];
              if (commands.contains(cmd)) onCommand(cmd as String);
            } catch (_) {}
          },
          onDone: () {
            _sockets.remove(ws);
            onClients?.call();
          },
          cancelOnError: true,
        );
        return;
      }
      final res = req.response;
      _cors(res);
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
      } else if (req.uri.path == '/hello') {
        res.headers.contentType = ContentType.json;
        res.write('{"app":"codewalk"}');
      } else if (req.uri.path == '/state') {
        res.headers.contentType = ContentType.json;
        res.write(_encode());
      } else if (req.uri.path == '/photo' && photo != null) {
        final p = await photo!();
        if (p == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers.contentType = ContentType.parse(p.$2);
          res.add(p.$1);
        }
      } else if (req.uri.path == '/portrait' && portrait != null) {
        final png = await portrait!(req.uri.queryParameters['id'] ?? '');
        if (png == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers.contentType = ContentType('image', 'png');
          res.add(png);
        }
      } else if (req.uri.path == '/roads' && roads != null) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(roads!()));
      } else if (req.uri.path == '/cmd' && commands.contains(req.uri.queryParameters['c'])) {
        onCommand(req.uri.queryParameters['c']!);
        res.headers.contentType = ContentType.json;
        res.write(_encode());
      } else {
        res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    } catch (e) {
      debugPrint('[g2] request failed: $e');
    }
  }

  String _encode() => jsonEncode(state());

  /// Push the state to connected glasses if it changed.
  void changed() {
    if (_sockets.isEmpty) return;
    final s = _encode();
    if (s == _last) return;
    _last = s;
    for (final ws in _sockets.toList()) {
      ws.add(s);
    }
  }
}

/// Letters and digits that are hard to mix up (no 0/O, 1/I/L).
const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// A new pairing code: 8 characters (about 40 bits), shown as `ABCD-EFGH`.
String newPairingCode([math.Random? random]) {
  final r = random ?? math.Random.secure();
  return List.generate(8, (_) => _codeAlphabet[r.nextInt(_codeAlphabet.length)]).join();
}

/// A code as typed: case, spaces and hyphens do not matter.
String normalizeCode(String code) => code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// `ABCDEFGH` -> `ABCD-EFGH`, for reading it out.
String formatCode(String code) {
  final c = normalizeCode(code);
  return c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;
}
