import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../radio_widgets.dart';
import '../l10n.dart';
import '../models.dart';
import '../stores.dart';
import '../walk_controller.dart';
import 'radio_screen.dart';

const _fallbackCenter = LatLng(35.6226, 139.7389); // 北品川 (until the first position arrives)

/// Map shows only where you are and spots you already heard about — never spots ahead,
/// so the app doesn't steer where you walk.
class WalkScreen extends StatefulWidget {
  const WalkScreen({super.key, required this.walk, required this.log, required this.settings});

  final WalkController walk;
  final LogStore log;
  final AppSettings settings;

  @override
  State<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends State<WalkScreen> {
  final _map = MapController();
  bool _follow = true;
  LatLng? _lastCentered;

  WalkController get walk => widget.walk;

  @override
  void initState() {
    super.initState();
    walk.addListener(_onWalk);
  }

  @override
  void dispose() {
    walk.removeListener(_onWalk);
    super.dispose();
  }

  void _onWalk() {
    final la = walk.lat, lo = walk.lon;
    if (!_follow || la == null || lo == null) return;
    final p = LatLng(la, lo);
    if (_lastCentered == p) return;
    _lastCentered = p;
    try {
      _map.move(p, _map.camera.zoom);
    } catch (_) {
      // map not laid out yet
    }
  }

  Future<void> _toggle() async {
    if (walk.walking) {
      await walk.stop();
      return;
    }
    final err = await walk.start();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _answer() async {
    final entry = await walk.answer();
    if (entry == null || !mounted) return; // already saved to the log ("あとで")
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RadioScreen(dialogue: entry.dialogue, session: walk.session)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([walk, widget.log, widget.settings, walk.session]),
      builder: (context, _) {
        final me = walk.lat != null ? LatLng(walk.lat!, walk.lon!) : null;
        final heard = widget.log.inRange(widget.settings.pinRange, DateTime.now());
        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: me ?? _fallbackCenter,
              initialZoom: 17,
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _follow) setState(() => _follow = false);
              },
              onLongPress: (_, p) {
                if (widget.settings.simulate) walk.simulateMove(p.latitude, p.longitude);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'dev.codewalk.codewalk',
              ),
              MarkerLayer(markers: [
                for (var i = 0; i < heard.length; i++)
                  Marker(
                    point: LatLng(heard[i].pinLat, heard[i].pinLon),
                    width: 26,
                    height: 26,
                    child: _Pin(label: '${heard.length - i}', played: heard[i].played),
                  ),
                if (me != null)
                  Marker(
                    point: me,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withValues(alpha: 0.18)),
                      alignment: Alignment.center,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: const Color(0xFF2F7CF6), border: Border.all(color: Colors.white, width: 3)),
                      ),
                    ),
                  ),
              ]),
              const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                _topBar(),
                const SizedBox(height: 6),
                _pinRange(),
                if (walk.status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)),
                    child: Text(walk.status, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ],
                const Spacer(),
                if (walk.incoming != null) _IncomingCard(dialogue: walk.incoming!, onAnswer: _answer, onLater: walk.later),
              ]),
            ),
          ),
          if (walk.incoming == null)
            Positioned(
              right: 16,
              bottom: 44,
              child: Column(children: [
                if (!_follow && me != null)
                  FloatingActionButton.small(
                    heroTag: 'follow',
                    onPressed: () {
                      setState(() => _follow = true);
                      _map.move(me, _map.camera.zoom);
                    },
                    child: const Icon(Icons.my_location),
                  ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'walk',
                  onPressed: _toggle,
                  icon: Icon(walk.walking ? Icons.stop : Icons.directions_walk),
                  label: Text(walk.walking ? t.endWalk : t.startWalk),
                ),
              ]),
            ),
        ]);
      },
    );
  }

  /// Which calls are pinned on the map (and the glasses minimap), like the log's period chips.
  Widget _pinRange() => Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 6, children: [
          for (final r in LogRange.values)
            ChoiceChip(
              label: Text(r.label, style: const TextStyle(fontSize: 12)),
              visualDensity: VisualDensity.compact,
              selected: widget.settings.pinRange == r,
              onSelected: (_) => widget.settings.pinRange = r,
            ),
        ]),
      );

  Widget _topBar() => Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Text(walk.walking ? t.walking : t.idle, style: const TextStyle(fontSize: 13)),
            Text('${(walk.walkedM / 1000).toStringAsFixed(1)} km', style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(t.callsLabel, style: const TextStyle(fontSize: 13)),
            Text(t.callsCount(walk.callsThisWalk), style: const TextStyle(fontWeight: FontWeight.bold)),
            if (widget.settings.simulate) ...[
              const SizedBox(width: 8),
              Chip(label: Text(t.devMode), visualDensity: VisualDensity.compact),
            ],
          ]),
        ),
      );
}

class _Pin extends StatelessWidget {
  const _Pin({required this.label, required this.played});
  final String label;
  final bool played;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: played ? const Color(0xFF1D7A3A) : const Color(0xFFE8A33D),
          border: Border.all(color: Colors.white, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
      );
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({required this.dialogue, required this.onAnswer, required this.onLater});

  final Dialogue dialogue;
  final VoidCallback onAnswer;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF07110A),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: radioGreen, width: 2),
          boxShadow: [BoxShadow(color: radioGreen.withValues(alpha: 0.35), blurRadius: 24)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text('CALL',
                style: mono.copyWith(
                    color: radioGreen,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    shadows: const [Shadow(color: radioGreen, blurRadius: 10)])),
            const Spacer(),
            Text(dialogue.commander.frequency, style: mono.copyWith(color: const Color(0xFFC9FFD7), fontSize: 22)),
          ]),
          const SizedBox(height: 8),
          Text(t.incomingFrom(dialogue.commander.name), style: const TextStyle(color: Color(0xFFD5FFE0))),
          Text(
              dialogue.isArea
                  ? t.townTalk(dialogue.spotName, themeLabels[dialogue.theme] ?? '')
                  : t.spotTalk(dialogue.spotName, themeLabels[dialogue.theme] ?? ''),
              style: const TextStyle(color: Color(0xFF7FC893), fontSize: 12)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF8FC79F), side: const BorderSide(color: Color(0xFF3C6B4A))),
                onPressed: onLater,
                child: Text(t.later),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: radioGreen, foregroundColor: const Color(0xFF04220E)),
                onPressed: onAnswer,
                child: Text(t.answer),
              ),
            ),
          ]),
        ]),
      );
}
