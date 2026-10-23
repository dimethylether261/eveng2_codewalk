// Data types for spots, dialogues and the call log: the JSON the on-device engine (lib/engine/)
// produces, and what the glasses app is sent (same shape the legacy server's API used).

import 'engine/characters.dart' show commander, specialists;
import 'l10n.dart';

class Spot {
  Spot({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.themes,
    required this.kind,
    this.nameEn,
  });

  /// Name in the app's language.
  String get displayName => t.lang == 'en' && (nameEn ?? '').isNotEmpty ? nameEn! : name;

  final String id;
  final String name;

  /// English name when the map data has one.
  final String? nameEn;
  final double lat;
  final double lon;
  final List<String> themes;
  final String kind;

  factory Spot.fromJson(Map<String, dynamic> j) => Spot(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        themes: (j['themes'] as List).cast<String>(),
        kind: (j['kind'] ?? '') as String,
        nameEn: j['name_en'] as String?,
      );
}

final _cast = {commander.id: commander, for (final c in specialists.values) c.id: c};

class Speaker {
  Speaker({required this.id, required this.name, required this.frequency});

  final String id;
  final String name;
  final String frequency;

  /// Name and frequency come from the current cast, so conversations saved before a rename or a
  /// frequency change (cached or in the log) show the current ones. English stays English.
  factory Speaker.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    final saved = j['name'] as String;
    final c = _cast[id];
    return Speaker(
      id: id,
      name: c == null ? saved : (saved == c.nameEn ? c.nameEn : c.name),
      frequency: c?.frequency ?? j['frequency'] as String,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'frequency': frequency};
}

class DialogueLine {
  DialogueLine({required this.speaker, required this.text, required this.sourceIds});

  final String speaker;
  final String text;
  final List<int> sourceIds;

  factory DialogueLine.fromJson(Map<String, dynamic> j) => DialogueLine(
        speaker: j['speaker'] as String,
        text: j['text'] as String,
        sourceIds: (j['source_ids'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
      );

  Map<String, dynamic> toJson() => {'speaker': speaker, 'text': text, 'source_ids': sourceIds};
}

class Source {
  Source({required this.id, required this.title, required this.url, required this.quote});

  final int id;
  final String title;
  final String url;
  final String quote;

  factory Source.fromJson(Map<String, dynamic> j) => Source(
        id: (j['id'] as num).toInt(),
        title: j['title'] as String,
        url: j['url'] as String,
        quote: (j['quote'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'url': url, 'quote': quote};
}

class SpotImage {
  SpotImage({required this.url, required this.license, required this.author, this.sourceUrl});

  final String url;
  final String license;
  final String author;
  final String? sourceUrl;

  static SpotImage? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : SpotImage(
          url: j['url'] as String,
          license: j['license'] as String,
          author: j['author'] as String,
          sourceUrl: j['source_url'] as String?,
        );

  Map<String, dynamic> toJson() => {'url': url, 'license': license, 'author': author, 'source_url': sourceUrl};
}

class Dialogue {
  Dialogue({
    required this.spotId,
    required this.spotName,
    this.spotKind = 'spot',
    required this.lat,
    required this.lon,
    required this.theme,
    required this.specialist,
    required this.commander,
    required this.lines,
    required this.sources,
    this.image,
    this.generatedAt,
    this.usd,
  });

  final String spotId;
  final String spotName;
  final String spotKind;

  /// A town-level radio call (町の雑学) rather than a specific spot.
  bool get isArea => spotKind == 'area';
  final double lat;
  final double lon;
  final String theme;
  final Speaker specialist;
  final Speaker commander;
  final List<DialogueLine> lines;
  final List<Source> sources;
  final SpotImage? image;

  /// When the engine wrote it (UTC ISO 8601), and its estimated API cost: the walk log ties calls to generations.
  final String? generatedAt;
  final double? usd;

  Speaker speaker(String id) => id == commander.id ? commander : specialist;

  factory Dialogue.fromJson(Map<String, dynamic> j) {
    final spot = j['spot'] as Map<String, dynamic>;
    return Dialogue(
      spotId: spot['id'] as String,
      spotName: spot['name'] as String,
      spotKind: (spot['kind'] ?? 'spot') as String,
      lat: (spot['lat'] as num?)?.toDouble() ?? double.nan,
      lon: (spot['lon'] as num?)?.toDouble() ?? double.nan,
      theme: j['theme'] as String,
      specialist: Speaker.fromJson(j['specialist'] as Map<String, dynamic>),
      commander: Speaker.fromJson(j['commander'] as Map<String, dynamic>),
      lines: (j['lines'] as List).map((e) => DialogueLine.fromJson(e as Map<String, dynamic>)).toList(),
      sources: (j['sources'] as List).map((e) => Source.fromJson(e as Map<String, dynamic>)).toList(),
      image: SpotImage.fromJson(j['image'] as Map<String, dynamic>?),
      generatedAt: j['generated_at'] as String?,
      usd: ((j['usage'] as Map?)?['usd'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'spot': {'id': spotId, 'name': spotName, 'kind': spotKind, 'lat': lat, 'lon': lon},
        'theme': theme,
        'specialist': specialist.toJson(),
        'commander': commander.toJson(),
        'lines': lines.map((e) => e.toJson()).toList(),
        'sources': sources.map((e) => e.toJson()).toList(),
        'image': image?.toJson(),
        if (generatedAt != null) 'generated_at': generatedAt,
        if (usd != null) 'usage': {'usd': usd},
      };
}

/// One received radio call, kept in the local log (on this device only).
class LogEntry {
  LogEntry({
    required this.id,
    required this.receivedAt,
    required this.played,
    required this.dialogue,
    this.heardLat,
    this.heardLon,
  });

  final String id;
  final DateTime receivedAt;
  bool played;
  final Dialogue dialogue;

  /// Where the user was when the radio rang (their own position, not the spot's).
  final double? heardLat;
  final double? heardLon;

  /// Map pin: the spot itself; where it was heard when the spot has no usable position, or when
  /// it is a town (a town is not a point; its stored position is just where we first entered it).
  bool get _spotKnown =>
      !dialogue.isArea &&
      dialogue.lat.isFinite &&
      dialogue.lon.isFinite &&
      !(dialogue.lat == 0 && dialogue.lon == 0);
  double get pinLat => _spotKnown || heardLat == null ? dialogue.lat : heardLat!;
  double get pinLon => _spotKnown || heardLon == null ? dialogue.lon : heardLon!;

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'] as String,
        receivedAt: DateTime.parse(j['received_at'] as String),
        played: j['played'] as bool,
        dialogue: Dialogue.fromJson(j['dialogue'] as Map<String, dynamic>),
        heardLat: (j['heard_lat'] as num?)?.toDouble(),
        heardLon: (j['heard_lon'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'received_at': receivedAt.toIso8601String(),
        'played': played,
        'dialogue': dialogue.toJson(),
        if (heardLat != null) 'heard_lat': heardLat,
        if (heardLon != null) 'heard_lon': heardLon,
      };
}

/// Theme labels in the current language (keys: the themes).
Map<String, String> get themeLabels => t.themeLabels;

/// Themes tuned in on first launch; the others are opt-in.
const defaultThemes = ['history', 'architecture', 'nature'];

/// Themes that need an age confirmation (20+) before they can be turned on.
const adultThemes = {'food'};


const themePortraits = {
  'history': 'shiori',
  'architecture': 'tetsu',
  'nature': 'midori',
  'placename': 'kotoha',
  'film': 'rei',
  'tech': 'gear',
  'food': 'kagura',
};

final _strayPercent = RegExp(r'%(?![0-9A-Fa-f]{2})');

/// Readable form of a source URL ("%E5%93%81…" -> "品…"); falls back to the raw text when it
/// contains broken percent-encoding instead of throwing.
String displayUrl(String url) {
  try {
    return Uri.decodeFull(url);
  } catch (_) {
    return url;
  }
}

/// A launchable Uri even when the source URL has a stray "%" (encoded as %25).
Uri? sourceUri(String url) => Uri.tryParse(url) ?? Uri.tryParse(url.replaceAll(_strayPercent, '%25'));
