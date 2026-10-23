import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../radio_widgets.dart';
import '../l10n.dart';
import '../models.dart';
import '../radar.dart';
import '../radio_session.dart';
import '../stores.dart';
import 'radio_screen.dart';

String _time(DateTime d) => t.time(d);

class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.log, required this.session});
  final LogStore log;
  final RadioSession session;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  LogRange range = LogRange.today;

  List<LogEntry> _filtered() => widget.log.inRange(range, DateTime.now());

  Future<void> _open(LogEntry e) async {
    if (!e.played) {
      await widget.log.markPlayed(e);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RadioScreen(dialogue: e.dialogue, session: widget.session)));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LogDetailScreen(entry: e, session: widget.session)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) {
        final items = _filtered();
        final points = [for (final e in items) LatLng(e.pinLat, e.pinLon)];
        return Scaffold(
          appBar: AppBar(title: Text(t.logTitle)),
          body: Column(children: [
            SizedBox(
              height: 220,
              child: points.isEmpty
                  ? Center(child: Text(t.noCallsYet))
                  : FlutterMap(
                      key: ValueKey('${range.name}-${items.length}'),
                      options: MapOptions(
                        initialCameraFit: points.length == 1
                            ? null
                            : CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(36), maxZoom: 17),
                        initialCenter: points.first,
                        initialZoom: 16,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'dev.codewalk.codewalk',
                        ),
                        MarkerLayer(markers: [
                          for (var i = 0; i < items.length; i++)
                            Marker(
                              point: points[i],
                              width: 26,
                              height: 26,
                              child: CircleAvatar(
                                backgroundColor: const Color(0xFF1D7A3A),
                                child: Text('${items.length - i}', style: const TextStyle(fontSize: 11, color: Colors.white)),
                              ),
                            ),
                        ]),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                for (final r in LogRange.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(r.label),
                      selected: range == r,
                      onSelected: (_) => setState(() => range = r),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = items[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF1D7A3A),
                      child: Text('${items.length - i}', style: const TextStyle(color: Colors.white)),
                    ),
                    title: Text(e.dialogue.spotName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${e.dialogue.specialist.name} × ${e.dialogue.commander.name}${t.sep}'
                        '${themeLabels[e.dialogue.theme] ?? ''}'),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(_time(e.receivedAt), style: const TextStyle(fontSize: 11)),
                      if (!e.played)
                        Text(t.unplayed, style: const TextStyle(fontSize: 11, color: Color(0xFFC77A12), fontWeight: FontWeight.bold)),
                    ]),
                    onTap: () => _open(e),
                  );
                },
              ),
            ),
          ]),
        );
      },
    );
  }
}

class LogDetailScreen extends StatelessWidget {
  const LogDetailScreen({super.key, required this.entry, required this.session});
  final LogEntry entry;
  final RadioSession session;

  @override
  Widget build(BuildContext context) {
    final d = entry.dialogue;
    return Scaffold(
      appBar: AppBar(
        title: Text(d.spotName),
        actions: [
          IconButton(
            tooltip: t.playCall,
            icon: const Icon(Icons.play_arrow),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RadioScreen(dialogue: d, session: session))),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('${_time(entry.receivedAt)}${t.sep}${d.specialist.frequency}${t.sep}${themeLabels[d.theme] ?? ''}',
            style: Theme.of(context).textTheme.bodySmall),
        if (entry.heardLat != null && entry.heardLon != null && !d.isArea)
          Text(t.heardFrom(d.spotName, distanceM(entry.heardLat!, entry.heardLon!, d.lat, d.lon).round()),
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        for (final l in d.lines) _Bubble(line: l, speaker: d.speaker(l.speaker), right: l.speaker == d.commander.id),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.sourcesOfThisConversation, style: const TextStyle(fontWeight: FontWeight.bold)),
              for (final s in d.sources)
                InkWell(
                  onTap: () {
                    final uri = sourceUri(s.url);
                    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('[${s.id}] ${s.title} ↗', style: const TextStyle(color: Color(0xFF2F5FB3))),
                  ),
                ),
              if (d.image != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(t.photoCredit(d.image!.author, d.image!.license), style: Theme.of(context).textTheme.bodySmall),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.line, required this.speaker, required this.right});
  final DialogueLine line;
  final Speaker speaker;
  final bool right;

  @override
  Widget build(BuildContext context) {
    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: right ? const Color(0xFFE6F4EA) : Colors.white,
          border: Border.all(color: const Color(0xFFD5E2D8)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(speaker.name, style: const TextStyle(fontSize: 11, color: Color(0xFF1D7A3A), fontWeight: FontWeight.bold)),
          Text.rich(TextSpan(children: [
            TextSpan(text: line.text, style: const TextStyle(color: Colors.black87)),
            if (line.sourceIds.isNotEmpty)
              TextSpan(
                  text: ' ${line.sourceIds.map((e) => '[$e]').join()}',
                  style: const TextStyle(fontSize: 10, color: Color(0xFF1D7A3A))),
          ])),
        ]),
      ),
    );
    final avatar = Portrait(speaker.id, width: 34);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: right
            ? [bubble, const SizedBox(width: 8), avatar]
            : [avatar, const SizedBox(width: 8), bubble],
      ),
    );
  }
}
