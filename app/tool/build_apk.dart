// Builds the release APK with your own portraits, without committing them.
//
// Usage (from app/):
//   ~/development/flutter/bin/dart run tool/build_apk.dart [flutter build apk options, e.g. --build-name=0.2.17]
//
// Portraits: the ones in ../private/portraits/ when that folder exists, or in CODEWALK_PORTRAITS=<dir>;
// otherwise the samples in assets/characters/. They replace the samples only for the build, and the
// samples are put back afterwards (if that is ever interrupted: git checkout assets/characters).
// If `flutter` is not on the PATH, set FLUTTER=/path/to/flutter.
import 'dart:io';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final flutter = await _findFlutter();
  final portraits = Directory(env['CODEWALK_PORTRAITS'] ?? '../private/portraits');
  final ownPortraits = portraits.existsSync();
  if (env['CODEWALK_PORTRAITS'] != null && !ownPortraits) {
    stderr.writeln('CODEWALK_PORTRAITS: ${portraits.path} does not exist');
    exit(1);
  }

  // Use all of the portraits, or stop.
  final samples = Directory('assets/characters')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.png'))
      .toList();
  final saved = <File, List<int>>{};
  if (ownPortraits) {
    String name(File f) => f.uri.pathSegments.last;
    final missing = samples.where((f) => !File('${portraits.path}/${name(f)}').existsSync()).map(name);
    if (missing.isNotEmpty) {
      stderr.writeln('${portraits.path} lacks ${missing.join(', ')}');
      exit(1);
    }
    for (final f in samples) {
      saved[f] = f.readAsBytesSync();
      File('${portraits.path}/${name(f)}').copySync(f.path);
    }
    stdout.writeln('portraits from ${portraits.path}');
  } else {
    stdout.writeln('portraits: the samples in assets/characters/');
  }

  // Ctrl-C reaches flutter too; stay alive to put the samples back.
  final sigint = ProcessSignal.sigint.watch().listen((_) {});
  var code = 1;
  try {
    final build = await Process.start(flutter, [
      'build',
      'apk',
      '--release',
      ...args,
    ], mode: ProcessStartMode.inheritStdio);
    code = await build.exitCode;
  } finally {
    saved.forEach((f, bytes) => f.writeAsBytesSync(bytes));
    await sigint.cancel();
  }
  exit(code);
}

Future<String> _findFlutter() async {
  final env = Platform.environment;
  if (env['FLUTTER'] != null) return env['FLUTTER']!;
  final which = await Process.run('which', ['flutter']);
  if (which.exitCode == 0) return (which.stdout as String).trim();
  final home = '${env['HOME']}/development/flutter/bin/flutter';
  if (File(home).existsSync()) return home;
  stderr.writeln('Flutter not found: install it or set FLUTTER=/path/to/flutter');
  exit(1);
}
