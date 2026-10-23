/// Which country a point is in, and which Wikipedia editions to search there besides Japanese.
///
/// Abroad, Japanese Wikipedia only knows the famous landmarks; the local edition (English in the
/// US and UK, French in France...) knows the small ones too. The country comes from Nominatim's
/// reverse geocoding (1 request/second), cached per 1-degree cell by the engine.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'util.dart';

const nominatimReverseUrl = 'https://nominatim.openstreetmap.org/reverse';

/// Every Nominatim call of the app shares this (its usage policy: 1 request/second).
final nominatimThrottle = Throttle();

/// Local Wikipedia editions by country (ISO 3166-1 alpha-2, lower case). Japan needs none.
/// Countries not listed get English Wikipedia, which covers most well-known places.
const localWikis = <String, List<String>>{
  'jp': [],
  'us': ['en'], 'gb': ['en'], 'ie': ['en'], 'au': ['en'], 'nz': ['en'], 'za': ['en'], 'ph': ['en'], 'in': ['en'],
  'ca': ['en', 'fr'], 'sg': ['en', 'zh'], 'my': ['ms', 'en'], 'hk': ['zh', 'en'],
  'fr': ['fr'], 'be': ['fr', 'nl'], 'lu': ['fr', 'de'], 'ch': ['de', 'fr', 'it'],
  'de': ['de'], 'at': ['de'], 'it': ['it'], 'es': ['es'], 'pt': ['pt'], 'nl': ['nl'],
  'se': ['sv'], 'no': ['no'], 'dk': ['da'], 'fi': ['fi'], 'is': ['is'],
  'pl': ['pl'], 'cz': ['cs'], 'sk': ['sk'], 'hu': ['hu'], 'ro': ['ro'], 'gr': ['el'], 'tr': ['tr'],
  'ru': ['ru'], 'ua': ['uk'], 'hr': ['hr'], 'si': ['sl'], 'rs': ['sr'], 'bg': ['bg'],
  'mx': ['es'], 'ar': ['es'], 'cl': ['es'], 'co': ['es'], 'pe': ['es'], 'br': ['pt'],
  'cn': ['zh'], 'tw': ['zh'], 'kr': ['ko'], 'th': ['th'], 'vn': ['vi'], 'id': ['id'],
  'eg': ['ar'], 'ae': ['ar', 'en'], 'sa': ['ar'], 'ma': ['fr', 'ar'], 'il': ['he'], 'ir': ['fa'],
};

/// Wikipedia editions to search besides Japanese for [country]. Unknown (lookup failed): none this
/// time (the lookup is retried next time), so a hiccup in Japan never adds a useless search.
List<String> wikisFor(String? country) => country == null ? const [] : localWikis[country] ?? const ['en'];

/// Every edition [localWikis] can ask for (the glasses app lists them in its network whitelist).
Set<String> get allLocalWikis => {for (final ls in localWikis.values) ...ls};

/// Cache cell for [countryCode]: countries don't change within a degree or so (border towns may
/// get the neighbour's edition too, which only adds articles).
String countryCell(double lat, double lon) => '${lat.floor()},${lon.floor()}';

/// The country code at the point ('jp', 'us', ...), or null when Nominatim can't tell (sea, error).
Future<String?> countryCode(http.Client client, String userAgent, double lat, double lon) =>
    nominatimThrottle.run(() async {
      try {
        final r = await client.get(
            Uri.parse(nominatimReverseUrl).replace(queryParameters: {
              'lat': '$lat',
              'lon': '$lon',
              'zoom': '3', // country level: the cheapest answer
              'format': 'jsonv2',
              'accept-language': 'en',
              ...nominatimEmail(userAgent),
            }),
            headers: uaHeaders(userAgent)).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return null;
        final code = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['address'] as Map?)?['country_code'];
        return code is String && code.length == 2 ? code.toLowerCase() : null;
      } catch (_) {
        return null;
      }
    });
