import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'backend_host.dart';
import 'l10n.dart';
import 'screens/ai_notice.dart';
import 'screens/log_screens.dart';
import 'screens/settings_screen.dart';
import 'screens/walk_screen.dart';
import 'stores.dart';
import 'walk_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final log = await LogStore.load();
  final notifier = Notifier();
  await notifier.init();
  final host = await BackendHost.create(settings);
  runApp(CodeWalkApp(walk: WalkController(settings, log, notifier, host)));
}

class CodeWalkApp extends StatelessWidget {
  const CodeWalkApp({super.key, required this.walk});
  final WalkController walk;

  @override
  // Rebuilds when the language changes (Settings), so every screen picks up the new texts.
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: walk.settings,
        builder: (context, _) => MaterialApp(
          title: 'CODEWALK',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF1D7A3A), useMaterial3: true),
          locale: Locale(walk.settings.lang),
          supportedLocales: [for (final l in supportedLangs) Locale(l)],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: HomeShell(walk: walk),
        ),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.walk});
  final WalkController walk;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Tapping the "CALL" notification brings the user back to the walk tab, where the card waits.
    widget.walk.notifier.onTap = () => setState(() => tab = 0);
    if (!widget.walk.settings.aiNoticeHidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAiNotice(context, widget.walk.settings);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.walk.appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused) widget.walk.host.flush(); // save the cache before Android may kill us
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.walk;
    return Scaffold(
      body: IndexedStack(index: tab, children: [
        WalkScreen(walk: w, log: w.log, settings: w.settings),
        LogScreen(log: w.log, session: w.session),
        SettingsScreen(settings: w.settings, host: w.host, g2: w.g2, log: w.log, onClearCache: w.clearCache),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.directions_walk), label: t.tabWalk),
          NavigationDestination(icon: const Icon(Icons.radio), label: t.tabLog),
          NavigationDestination(icon: const Icon(Icons.settings), label: t.tabSettings),
        ],
      ),
    );
  }
}
