import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../radio_widgets.dart';
import '../l10n.dart';
import '../models.dart';
import '../radio_session.dart';

/// Radio conversation. Tap to advance; sources are listed at the end.
/// The position lives in [session], shared with the Even G2 display.
class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key, required this.dialogue, required this.session});

  final Dialogue dialogue;
  final RadioSession session;

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

/// How many earlier lines stay visible above the current one.
const historyLines = 3;

class _RadioScreenState extends State<RadioScreen> with SingleTickerProviderStateMixin {
  int shown = 0; // characters typed so far
  int _typedIndex = -1;
  Timer? _typer;
  late final AnimationController _meter =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..repeat(reverse: true);

  RadioSession get session => widget.session;
  Dialogue get d => widget.dialogue;
  int get index => session.index;
  bool get finished => session.finished;
  DialogueLine get line => d.lines[index];

  @override
  void initState() {
    super.initState();
    // Already started when the call was answered on the glasses.
    if (!identical(session.dialogue, d)) session.start(d);
    session.addListener(_onSession);
    _type();
  }

  void _onSession() {
    if (!mounted) return;
    if (!identical(session.dialogue, d)) {
      Navigator.of(context).maybePop(); // ended on the glasses
      return;
    }
    if (session.index != _typedIndex) _type();
    setState(() {});
  }

  void _type() {
    _typer?.cancel();
    _typedIndex = index;
    shown = 0;
    _typer = Timer.periodic(const Duration(milliseconds: 35), (t) {
      if (!mounted) return t.cancel();
      setState(() => shown++);
      if (shown >= line.text.length) t.cancel();
    });
  }

  void _next() {
    if (shown < line.text.length) {
      _typer?.cancel();
      setState(() => shown = line.text.length);
      return;
    }
    session.next();
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    // After this frame: other listeners (walk screen) must not rebuild while the tree is locked.
    final s = session;
    Future.microtask(() {
      if (identical(s.dialogue, d)) s.end();
    });
    _typer?.cancel();
    _meter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speaker = d.speaker(line.speaker);
    return Scaffold(
      backgroundColor: radioBg,
      body: Stack(children: [
        Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(colors: [Color(0xFF10261A), radioBg], radius: 0.9),
          ),
        ),
        SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: finished ? null : _next,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  _speaking(d.commander, speaker),
                  _centerPanel(speaker.frequency),
                  _speaking(d.specialist, speaker),
                ]),
                const SizedBox(height: 12),
                _photo(),
                const SizedBox(height: 12),
                Expanded(child: finished ? _sources() : _dialogueBox(speaker)),
              ]),
            ),
          ),
        ),
        const ScanLines(),
      ]),
    );
  }

  // The character who is not talking is dimmed, like a radio channel on standby.
  Widget _speaking(Speaker who, Speaker current) => AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: finished || who.id == current.id ? 1 : 0.45,
        child: Portrait(who.id, label: who.name),
      );

  Widget _centerPanel(String freq) => Column(children: [
        _tag('PTT'),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: _meter,
          builder: (_, _) => SizedBox(
            height: 34,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(6, (i) {
                final h = finished ? 4.0 : 6 + 26 * (0.5 + 0.5 * sin(_meter.value * pi + i * 1.1)).abs();
                return Container(width: 6, height: h, margin: const EdgeInsets.symmetric(horizontal: 1.5), color: radioGreen);
              }),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(freq,
            style: mono.copyWith(
                color: const Color(0xFF8DFFAE),
                fontSize: 24,
                fontWeight: FontWeight.bold,
                shadows: const [Shadow(color: radioGreen, blurRadius: 8)])),
        const SizedBox(height: 6),
        _tag('MEMORY'),
      ]);

  Widget _tag(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: radioGreen)),
        child: Text(t, style: mono.copyWith(color: radioGreen, fontSize: 10)),
      );

  Widget _photo() {
    final img = d.image;
    return Container(
      height: 150,
      width: double.infinity,
      decoration: BoxDecoration(border: Border.all(color: radioGreen.withValues(alpha: 0.7))),
      child: Stack(fit: StackFit.expand, children: [
        if (img != null)
          ColorFiltered(
            colorFilter: const ColorFilter.mode(Color(0xFF3CFF7A), BlendMode.modulate),
            child: Image.network(img.url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
          )
        else
          const Center(child: Icon(Icons.location_on, color: radioBorder, size: 48)),
        Positioned(
          left: 6,
          bottom: 4,
          right: 6,
          child: Text(
            img == null ? d.spotName : '${d.spotName}　${t.photoCredit(img.author, img.license)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFD8FFE3), fontSize: 11, backgroundColor: Color(0x8C000000)),
          ),
        ),
      ]),
    );
  }

  Widget _dialogueBox(Speaker speaker) {
    final srcs = d.sources.where((s) => line.sourceIds.contains(s.id)).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xD9030C06), border: Border.all(color: radioBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          // Newest at the bottom; if the history doesn't fit, older lines scroll off the top.
          child: SingleChildScrollView(
            reverse: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final prev in d.lines.sublist(max(0, index - historyLines), index)) _pastLine(prev),
              Text(speaker.name, style: const TextStyle(color: radioGreen, fontWeight: FontWeight.bold, letterSpacing: 1)),
              const SizedBox(height: 2),
              Text(line.text.substring(0, min(shown, line.text.length)),
                  style: const TextStyle(color: radioText, fontSize: 16, height: 1.6)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Wrap(spacing: 6, children: [
              for (final s in srcs)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: radioBorder), borderRadius: BorderRadius.circular(10)),
                  child: Text(t.sourceChip(s.id, s.title),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: radioDim, fontSize: 11)),
                ),
            ]),
          ),
          Text('${index + 1}/${d.lines.length} ▼', style: const TextStyle(color: radioGreen)),
        ]),
      ]),
    );
  }

  /// An earlier line, dimmed: who said it and what, so the back-and-forth stays readable.
  Widget _pastLine(DialogueLine l) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.speaker(l.speaker).name,
              style: TextStyle(color: radioGreen.withValues(alpha: 0.55), fontSize: 12, fontWeight: FontWeight.bold)),
          Text(l.text, style: TextStyle(color: radioText.withValues(alpha: 0.5), fontSize: 14, height: 1.5)),
        ]),
      );

  Widget _sources() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xD9030C06), border: Border.all(color: radioBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.sourcesOfThisTalk, style: const TextStyle(color: radioGreen, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final s in d.sources)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('[${s.id}] ${s.title}', style: const TextStyle(color: radioText)),
                  subtitle: Text(displayUrl(s.url), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: radioDim)),
                  trailing: const Icon(Icons.open_in_new, color: radioDim, size: 18),
                  onTap: () {
                    final uri = sourceUri(s.url);
                    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),
            ]),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: radioGreen, foregroundColor: const Color(0xFF04220E)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.endCall),
            ),
          ),
        ]),
      );
}
