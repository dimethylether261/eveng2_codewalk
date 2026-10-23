import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

const radioBg = Color(0xFF050B07);
const radioPanel = Color(0xFF0A1F12);
const radioGreen = Color(0xFF3CFF7A);
const radioText = Color(0xFFC8FFD6);
const radioDim = Color(0xFF74C48B);
const radioBorder = Color(0xFF2A8A4A);
const mono = TextStyle(fontFamily: 'monospace');

/// Character portrait: the image in assets/characters/, or a drawn face for unknown ids.
class Portrait extends StatelessWidget {
  const Portrait(this.characterId, {super.key, this.width = 104, this.label});

  final String characterId;
  final double width;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final Widget box = portraitIds.contains(characterId)
        ? SizedBox(
            width: width,
            height: width / portraitAspect,
            child: Image.asset(portraitAsset(characterId), fit: BoxFit.cover, filterQuality: FilterQuality.medium),
          )
        : Container(
            width: width,
            height: width * 132 / 104,
            decoration: BoxDecoration(color: radioPanel, border: Border.all(color: radioGreen, width: 2)),
            child: CustomPaint(painter: _PortraitPainter(characterId)),
          );
    if (label == null) return box;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      box,
      const SizedBox(height: 4),
      Text(label!, style: const TextStyle(color: radioDim, fontSize: 11, letterSpacing: 2)),
    ]);
  }
}

/// Portrait image per character id, in assets/characters/ (commander + theme specialists).
/// Files are named after the characters (the ids are kept: dialogues and logs store them).
/// Same as PORTRAIT_FILES in g2/src/photo.ts.
const portraitFiles = {
  'ootori': 'commander',
  'shiori': 'owl',
  'tetsu': 'sphinx',
  'midori': 'dino',
  'kotoha': 'fox',
  'rei': 'monkey',
  'gear': 'seal',
  'kagura': 'cat',
};

/// Character ids with a portrait image.
final portraitIds = portraitFiles.keys.toSet();

/// Proportions of the portrait images (292 x 332).
const portraitAspect = 292 / 332;

String portraitAsset(String id) => 'assets/characters/${portraitFiles[id]}.png';

/// The portrait image file (PNG), e.g. for the Even G2 display. Null for an unknown id.
Future<Uint8List?> portraitPng(String id) async {
  if (!portraitIds.contains(id)) return null;
  final data = await rootBundle.load(portraitAsset(id));
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Drawn fallback for ids without an image (e.g. old log entries of a retired character).
class _PortraitPainter extends CustomPainter {
  _PortraitPainter(this.id);
  final String id;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 104, size.height / 132);
    final dark = Paint()..color = const Color(0xFF164D2A);
    final mid = Paint()..color = const Color(0xFF1F6B3A);
    final skin = Paint()..color = const Color(0xFF3FAE64);
    final line = Paint()
      ..color = const Color(0xFFC9FFD7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final light = Paint()..color = const Color(0xFFC9FFD7).withValues(alpha: 0.85);

    // shoulders + neck + face
    canvas.drawPath(
        Path()
          ..moveTo(14, 132)
          ..cubicTo(18, 100, 34, 92, 52, 92)
          ..cubicTo(70, 92, 86, 100, 90, 132)
          ..close(),
        mid);
    canvas.drawRect(const Rect.fromLTWH(43, 80, 18, 16), Paint()..color = const Color(0xFF2D8A4C));
    if (id == 'shiori') {
      canvas.drawPath(
          Path()
            ..moveTo(24, 88)
            ..lineTo(24, 56)
            ..cubicTo(22, 24, 82, 24, 80, 56)
            ..lineTo(80, 88)
            ..close(),
          dark);
    }
    if (id == 'midori') { // long hair down to the shoulders
      canvas.drawPath(
          Path()
            ..moveTo(22, 100)
            ..lineTo(24, 56)
            ..cubicTo(22, 22, 82, 22, 80, 56)
            ..lineTo(82, 100)
            ..close(),
          dark);
    }
    canvas.drawOval(const Rect.fromLTWH(31, 33, 42, 52), skin);

    switch (id) {
      case 'ootori': // grey crew cut + beard
        canvas.drawPath(
            Path()
              ..moveTo(30, 52)
              ..cubicTo(30, 26, 74, 26, 74, 52)
              ..cubicTo(68, 40, 36, 40, 30, 52),
            light);
        canvas.drawPath(
            Path()
              ..moveTo(34, 66)
              ..cubicTo(38, 88, 66, 88, 70, 66)
              ..cubicTo(64, 76, 40, 76, 34, 66),
            light);
        canvas.drawRect(const Rect.fromLTWH(40, 54, 8, 3), Paint()..color = radioBg);
        canvas.drawRect(const Rect.fromLTWH(56, 54, 8, 3), Paint()..color = radioBg);
      case 'shiori': // bob hair + round glasses
        canvas.drawPath(
            Path()
              ..moveTo(30, 52)
              ..cubicTo(32, 30, 72, 30, 74, 52)
              ..cubicTo(64, 44, 46, 42, 30, 52),
            dark);
        canvas.drawCircle(const Offset(44, 60), 6, line);
        canvas.drawCircle(const Offset(60, 60), 6, line);
        canvas.drawLine(const Offset(50, 60), const Offset(54, 60), line);
        _smile(canvas);
      case 'tetsu': // hard hat
        canvas.drawPath(
            Path()
              ..moveTo(26, 50)
              ..cubicTo(26, 22, 78, 22, 78, 50)
              ..close(),
            light);
        canvas.drawRect(const Rect.fromLTWH(22, 48, 60, 5), light);
        canvas.drawRect(const Rect.fromLTWH(41, 60, 8, 3), Paint()..color = radioBg);
        canvas.drawRect(const Rect.fromLTWH(55, 60, 8, 3), Paint()..color = radioBg);
      case 'machi': // cap + big grin
        canvas.drawPath(
            Path()
              ..moveTo(30, 48)
              ..cubicTo(30, 28, 74, 28, 74, 48)
              ..close(),
            dark);
        canvas.drawRect(const Rect.fromLTWH(56, 44, 26, 5), dark);
        canvas.drawCircle(const Offset(44, 60), 3, Paint()..color = radioBg);
        canvas.drawCircle(const Offset(60, 60), 3, Paint()..color = radioBg);
        canvas.drawArc(const Rect.fromLTWH(42, 64, 20, 12), 0, 3.14, true, light);
      case 'midori': // long hair + a leaf
        canvas.drawPath(
            Path()
              ..moveTo(30, 52)
              ..cubicTo(32, 28, 72, 28, 74, 52)
              ..cubicTo(60, 40, 44, 40, 30, 52),
            dark);
        canvas.save();
        canvas.translate(70, 34);
        canvas.rotate(0.6);
        canvas.drawOval(const Rect.fromLTWH(-4, -9, 8, 18), light);
        canvas.restore();
        canvas.drawArc(const Rect.fromLTWH(39, 57, 10, 6), 3.4, 2.6, false, line);
        canvas.drawArc(const Rect.fromLTWH(55, 57, 10, 6), 3.4, 2.6, false, line);
        _smile(canvas);
      case 'kotoha': // twin buns + bangs
        canvas.drawCircle(const Offset(32, 34), 9, dark);
        canvas.drawCircle(const Offset(72, 34), 9, dark);
        canvas.drawPath(
            Path()
              ..moveTo(30, 52)
              ..cubicTo(30, 28, 74, 28, 74, 52)
              ..lineTo(66, 46)
              ..lineTo(58, 50)
              ..lineTo(50, 45)
              ..lineTo(42, 50)
              ..lineTo(36, 46)
              ..close(),
            dark);
        canvas.drawCircle(const Offset(44, 60), 3, Paint()..color = radioBg);
        canvas.drawLine(const Offset(56, 60), const Offset(64, 60), line); // wink
        _smile(canvas);
      case 'rei': // messy hair + square glasses
        canvas.drawPath(
            Path()
              ..moveTo(28, 54)
              ..lineTo(30, 34)
              ..lineTo(38, 38)
              ..lineTo(44, 26)
              ..lineTo(52, 34)
              ..lineTo(60, 26)
              ..lineTo(66, 36)
              ..lineTo(74, 32)
              ..lineTo(76, 54)
              ..cubicTo(66, 42, 40, 42, 28, 54),
            dark);
        canvas.drawRect(const Rect.fromLTWH(37, 55, 13, 10), line);
        canvas.drawRect(const Rect.fromLTWH(54, 55, 13, 10), line);
        canvas.drawLine(const Offset(50, 59), const Offset(54, 59), line);
        _smile(canvas);
      case 'gear': // short hair + headphones
        canvas.drawPath(
            Path()
              ..moveTo(31, 50)
              ..cubicTo(31, 30, 73, 30, 73, 50)
              ..cubicTo(64, 42, 40, 42, 31, 50),
            dark);
        canvas.drawArc(const Rect.fromLTWH(24, 24, 56, 50), 3.3, 2.82, false,
            Paint()
              ..color = const Color(0xFFC9FFD7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(22, 52, 10, 18), const Radius.circular(3)), light);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(72, 52, 10, 18), const Radius.circular(3)), light);
        canvas.drawRect(const Rect.fromLTWH(41, 59, 7, 4), Paint()..color = radioBg);
        canvas.drawRect(const Rect.fromLTWH(56, 59, 7, 4), Paint()..color = radioBg);
        _smile(canvas);
      case 'kagura': // hair tied up + headband (hachimaki)
        canvas.drawCircle(const Offset(52, 26), 8, dark);
        canvas.drawPath(
            Path()
              ..moveTo(30, 52)
              ..cubicTo(30, 28, 74, 28, 74, 52)
              ..cubicTo(64, 44, 40, 44, 30, 52),
            dark);
        canvas.drawRect(const Rect.fromLTWH(30, 42, 44, 5), light);
        canvas.drawPath(
            Path()
              ..moveTo(74, 44)
              ..lineTo(84, 38)
              ..lineTo(82, 48)
              ..close(),
            light);
        canvas.drawCircle(const Offset(44, 60), 3, Paint()..color = radioBg);
        canvas.drawCircle(const Offset(60, 60), 3, Paint()..color = radioBg);
        canvas.drawArc(const Rect.fromLTWH(43, 66, 18, 10), 0, 3.14, true, light);
      default:
        _smile(canvas);
    }
  }

  void _smile(Canvas canvas) => canvas.drawArc(
      const Rect.fromLTWH(46, 70, 12, 6),
      0.2,
      2.7,
      false,
      Paint()
        ..color = radioBg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);

  @override
  bool shouldRepaint(covariant _PortraitPainter old) => old.id != id;
}

/// Thin horizontal scan lines over the radio screen.
class ScanLines extends StatelessWidget {
  const ScanLines({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _ScanPainter(), size: Size.infinite));
}

class _ScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withValues(alpha: 0.22);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
