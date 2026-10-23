import 'package:flutter/material.dart';

import '../api.dart';
import '../backend_host.dart';
import '../radio_widgets.dart';
import '../engine/claude.dart';
import '../g2_bridge.dart';
import '../models.dart';
import '../l10n.dart';
import '../stores.dart';
import 'character_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen(
      {super.key, required this.settings, required this.host, required this.g2, required this.log, required this.onClearCache});
  final AppSettings settings;
  final BackendHost host;
  final G2Bridge g2;
  final LogStore log;

  /// Deletes the conversation cache (WalkController.clearCache: the walk forgets it too).
  final Future<void> Function() onClearCache;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _codename = TextEditingController(text: widget.settings.codename);
  late final _server = TextEditingController(text: widget.settings.serverUrl);
  late final _apiKey = TextEditingController(text: widget.settings.apiKey);
  late final _contact = TextEditingController(text: widget.settings.contact);
  String? _health, _keyStatus;
  bool _showKey = false;

  AppSettings get s => widget.settings;

  Future<void> _saveKey() async {
    await s.setApiKey(_apiKey.text);
    if (s.apiKey.isEmpty) {
      setState(() => _keyStatus = t.keyDeleted);
      return;
    }
    setState(() => _keyStatus = t.checking);
    try {
      await widget.host.engine.checkKey();
      setState(() => _keyStatus = t.keyOk);
    } on ClaudeError catch (e) {
      setState(() => _keyStatus = e.badKey ? t.keyBad : t.keyCheckFailed(e.status));
    } catch (_) {
      setState(() => _keyStatus = t.networkFailed);
    }
  }

  Future<void> _check() async {
    s.serverUrl = _server.text;
    if (s.serverUrl.isEmpty) {
      setState(() => _health = t.onDevice);
      return;
    }
    setState(() => _health = t.checking);
    try {
      final h = await ApiClient(s.serverUrl).health();
      final provider = {'anthropic': 'Claude', 'openai': 'ChatGPT', 'gemini': 'Gemini'}[h['provider']] ?? '';
      setState(() => _health = h['llm'] == true
          ? t.serverOk(provider, '${h['model'] ?? ''}')
          : t.serverOkNoKey);
    } catch (e) {
      setState(() => _health = t.serverUnreachable);
    }
  }

  /// A portrait that opens the character's profile card.
  Widget _profileButton(CharacterProfile p, double width) => Semantics(
        button: true,
        label: t.introOf(p.name),
        child: InkWell(onTap: () => showCharacterProfile(context, p), child: Portrait(p.id, width: width)),
      );

  Future<void> _toggleTheme(String theme, bool on) async {
    if (on && adultThemes.contains(theme) && !s.adultConfirmed) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.ageTitle),
          content: Text(t.ageQuestion),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.no)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.yes20)),
          ],
        ),
      );
      if (ok != true) return;
      s.adultConfirmed = true;
    }
    if (!s.setTheme(theme, on) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(on ? t.themeCannotTurnOn : t.themeAtLeastOne)));
    }
  }

  Future<bool> _confirmDelete(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: Text(t.delete),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _clearCache() async {
    if (!await _confirmDelete(t.clearCacheTitle, t.clearCacheBody)) return;
    await widget.onClearCache();
    if (!mounted) return;
    setState(() {}); // the cached count
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.cacheCleared)));
  }

  Future<void> _clearLog() async {
    if (!await _confirmDelete(t.clearLogTitle, t.clearLogBody)) return;
    await widget.log.clear();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.logCleared)));
  }

  @override
  void initState() {
    super.initState();
    widget.g2.onClients = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    widget.g2.onClients = null;
    _codename.dispose();
    _server.dispose();
    _apiKey.dispose();
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(t.settingsTitle)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Text(t.language, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 16),
            SegmentedButton<String>(
              segments: [for (final l in supportedLangs) ButtonSegment(value: l, label: Text(l == 'ja' ? const JaText().languageName : const EnText().languageName))],
              selected: {s.lang},
              onSelectionChanged: (v) => s.lang = v.first,
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _codename,
            decoration: InputDecoration(labelText: t.codename, helperText: t.codenameHelp),
            onSubmitted: (v) => s.codename = v,
            onTapOutside: (_) => s.codename = _codename.text,
          ),
          const SizedBox(height: 24),
          Text(t.tuneIn, style: Theme.of(context).textTheme.titleMedium),
          Text(t.tuneInHelp, style: const TextStyle(fontSize: 12)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _profileButton(commanderProfileNow, 36),
            title: Text(t.commanderRow),
            subtitle: Text(t.commanderRowSub(commanderProfileNow.name, commanderProfileNow.frequency)),
            onTap: () => showCharacterProfile(context, commanderProfileNow),
          ),
          for (final theme in themeLabels.keys)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: _profileButton(characterProfilesNow[theme]!, 36),
              title: Text(themeLabels[theme]!),
              subtitle: Text(
                  '${characterProfilesNow[theme]!.name}${t.sep}${characterProfilesNow[theme]!.frequency}${t.sep}${t.themeTopics[theme]}'),
              value: s.themes.contains(theme),
              onChanged: (v) => _toggleTheme(theme, v),
            ),
          const SizedBox(height: 16),
          Text(t.callFrequency, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<CallFrequency>(
            segments: [for (final f in CallFrequency.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {s.frequency},
            onSelectionChanged: (v) => s.frequency = v.first,
          ),
          Text(t.frequencyHelp(s.frequency.minInterval.inMinutes),
              style: const TextStyle(fontSize: 12)),
          const Divider(height: 40),
          Text('Claude API', style: Theme.of(context).textTheme.titleMedium),
          Text(t.claudeApiHelp, style: const TextStyle(fontSize: 12)),
          TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: t.apiKeyLabel,
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
          Row(children: [
            TextButton(onPressed: _saveKey, child: Text(t.saveAndCheck)),
            if (_keyStatus != null) Expanded(child: Text(_keyStatus!, style: const TextStyle(fontSize: 12))),
          ]),
          Text(t.spentThisMonth(s.spentThisMonth.toStringAsFixed(2)),
              style: const TextStyle(fontSize: 12)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.restrictSources),
            subtitle: Text(t.restrictSourcesHelp),
            value: s.restrictSources,
            onChanged: (v) => s.restrictSources = v,
          ),
          TextField(
            controller: _contact,
            decoration: InputDecoration(labelText: t.contact, helperText: t.contactHelp, helperMaxLines: 3),
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (v) => s.contact = v,
            onTapOutside: (_) => s.contact = _contact.text,
          ),
          const Divider(height: 40),
          Text(t.logSection, style: Theme.of(context).textTheme.titleMedium),
          ListenableBuilder(
            listenable: widget.log,
            builder: (context, _) => Text(t.logCount(widget.log.entries.length), style: const TextStyle(fontSize: 12)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _clearLog,
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.delete_outline),
              label: Text(t.clearLog),
            ),
          ),
          Text(t.cacheCount(widget.host.cachedDialogues), style: const TextStyle(fontSize: 12)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _clearCache,
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.cleaning_services_outlined),
              label: Text(t.clearCache),
            ),
          ),
          const Divider(height: 40),
          Text('Even G2', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.showOnG2),
            subtitle: Text(!s.g2Enabled
                ? t.off
                : widget.g2.clients > 0
                    ? t.g2Connected
                    : t.g2Waiting),
            value: s.g2Enabled,
            onChanged: (v) => s.g2Enabled = v,
          ),
          Text(t.g2Help, style: const TextStyle(fontSize: 12)),
          if (s.g2Enabled) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.g2Code, style: Theme.of(context).textTheme.labelLarge),
                  SelectableText(formatCode(s.g2Code), style: mono.copyWith(fontSize: 22, letterSpacing: 2)),
                ]),
              ),
              TextButton(onPressed: s.renewG2Code, child: Text(t.g2NewCode)),
            ]),
            Text(t.g2CodeHelp, style: const TextStyle(fontSize: 12)),
          ],
          const Divider(height: 40),
          Text(t.developer, style: Theme.of(context).textTheme.titleMedium),
          TextField(
            controller: _server,
            decoration: InputDecoration(labelText: t.serverUrl, helperText: t.serverUrlHelp),
            keyboardType: TextInputType.url,
          ),
          Row(children: [
            TextButton(onPressed: _check, child: Text(t.save)),
            if (_health != null) Expanded(child: Text(_health!, style: const TextStyle(fontSize: 12))),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.simulate),
            subtitle: Text(t.simulateHelp),
            value: s.simulate,
            onChanged: (v) => s.simulate = v,
          ),
          const SizedBox(height: 16),
          Text(t.aiNotice, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Text(t.privacy, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}
