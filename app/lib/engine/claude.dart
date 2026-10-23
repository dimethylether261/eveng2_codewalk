/// Claude Messages API over HTTP (there is no official Dart SDK), plus per-generation usage.
///
/// Prices: https://platform.claude.com/docs/en/about-claude/pricing (checked 2026-10-13).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'util.dart';

const apiUrl = 'https://api.anthropic.com/v1/messages';

/// Models that accept the server-side refusal fallback (`fallbacks: "default"`); Haiku 5.5 has none.
const fallbackModels = {'claude-opus-5-5', 'claude-opus-5', 'claude-fable-5-1', 'claude-sonnet-5-5'};

/// Generation settings (what the Python server read from .env).
class EngineConfig {
  const EngineConfig({
    // Claude model per step. Measured on 北品川 (2026-10-13): all Opus 5.5 $0.455/dialogue; this mix $0.019.
    this.researchModel = 'claude-haiku-5-5',
    this.model = 'claude-sonnet-5-5',
    this.checkModel = 'claude-haiku-5-5',
    // Redo research with a stronger model when the cheap one finds few facts or the dialogue
    // still scores below the threshold. Empty string disables it.
    this.escalateResearchModel = 'claude-sonnet-5-5',
    this.escalateMinFacts = 4,
    this.fallbacks = true,
    this.effortResearch = 'medium',
    this.effortDialogue = 'medium',
    this.effortCheck = 'low',
    this.effortReview = 'medium',
    this.maxTokens = 16000,
    // Basic tool versions on purpose: the *_20260209 variants filter results inside code
    // execution and the final answer then carries no API citations, which this app requires.
    this.webSearchTool = 'web_search_20250305',
    this.webFetchTool = 'web_fetch_20250910',
    this.webMaxUses = 3,
    // Empty = any site.
    this.allowedDomains = const [],
    this.minFacts = 2,
    this.reviewEnabled = true,
    this.reviewThreshold = 3.5,
    this.reviewRewrites = 1,
    this.discoverEnabled = true,
    this.wikipediaSpots = true,
  });

  final String researchModel, model, checkModel, escalateResearchModel;
  final int escalateMinFacts;
  final bool fallbacks;
  final String effortResearch, effortDialogue, effortCheck, effortReview;
  final int maxTokens;
  final String webSearchTool, webFetchTool;
  final int webMaxUses;
  final List<String> allowedDomains;
  final int minFacts;
  final bool reviewEnabled;
  final double reviewThreshold;
  final int reviewRewrites;
  final bool discoverEnabled, wikipediaSpots;
}

/// Hostnames research may use when the restriction is on (subdomains are covered).
const restrictedDomains = ['ja.wikipedia.org', 'en.wikipedia.org', 'www.bunka.go.jp', 'kunishitei.bunka.go.jp'];

class ClaudeRefused implements Exception {
  ClaudeRefused(this.category);
  final String? category;
  @override
  String toString() => 'ClaudeRefused($category)';
}

class ClaudeError implements Exception {
  ClaudeError(this.status, this.message);
  final int status;
  final String message;
  bool get badKey => status == 401 || status == 403;
  @override
  String toString() => 'ClaudeError($status: $message)';
}

// --- usage ---------------------------------------------------------------------

// USD per million tokens: (input, output, cache_write_5m, cache_read)
const claudePrices = <String, (double, double, double, double)>{
  'claude-opus-5-5': (4.0, 20.0, 5.0, 0.20),
  'claude-sonnet-5-5': (2.0, 10.0, 2.5, 0.10),
  'claude-haiku-5-5': (0.10, 0.50, 0.125, 0.01),
};
const haikuLong = (0.50, 2.50, 0.625, 0.05); // Haiku 5.5 prompts over 100K tokens
const webSearchUsd = 10.0 / 1000;

double? claudeCost(String model, int inp, int out, int cacheWrite, int cacheRead, int searches) {
  var price = claudePrices[model];
  if (price == null) return null;
  if (model == 'claude-haiku-5-5' && inp + cacheWrite + cacheRead > 100000) price = haikuLong;
  final (pi, po, pw, pr) = price;
  return (inp * pi + out * po + cacheWrite * pw + cacheRead * pr) / 1e6 + searches * webSearchUsd;
}

/// Usage of one generation (all its API calls).
class Usage {
  final steps = <Json>[];

  void record(String step, String model, Json? u) {
    if (u == null) return;
    int n(String k) => (u[k] as num?)?.toInt() ?? 0;
    final stu = u['server_tool_use'] as Map?;
    final searches = (stu?['web_search_requests'] as num?)?.toInt() ?? 0;
    final fetches = (stu?['web_fetch_requests'] as num?)?.toInt() ?? 0;
    final inp = n('input_tokens'), out = n('output_tokens');
    final cw = n('cache_creation_input_tokens'), cr = n('cache_read_input_tokens');
    steps.add({
      'step': step,
      'model': model,
      'input': inp + cw + cr,
      'output': out,
      'searches': searches,
      'fetches': fetches,
      'usd': claudeCost(model, inp, out, cw, cr, searches),
    });
  }

  double? get usd {
    if (steps.isEmpty || steps.any((s) => s['usd'] == null)) return steps.isEmpty ? 0 : null;
    return steps.fold<double>(0, (a, s) => a + (s['usd'] as double));
  }

  Json summary() => {
        'calls': steps.length,
        'input_tokens': steps.fold<int>(0, (a, s) => a + (s['input'] as int)),
        'output_tokens': steps.fold<int>(0, (a, s) => a + (s['output'] as int)),
        'web_searches': steps.fold<int>(0, (a, s) => a + (s['searches'] as int)),
        'usd': usd == null ? null : (usd! * 1e4).round() / 1e4,
        'steps': steps,
      };

  String describe() {
    final parts = steps.map((s) =>
        '${s['step']}=${s['model']}:${s['input']}in/${s['output']}out'
        '${(s['searches'] as int) > 0 ? '/${s['searches']}search' : ''}'
        '${s['usd'] != null ? ' \$${(s['usd'] as double).toStringAsFixed(4)}' : ''}');
    return 'total ${usd == null ? 'n/a' : '\$${usd!.toStringAsFixed(4)}'} | ${parts.join(' | ')}';
  }
}

// --- client --------------------------------------------------------------------

class Claude {
  Claude(this.apiKey, {this.config = const EngineConfig(), http.Client? client, this.usage})
      : _http = client ?? http.Client();

  final String apiKey;
  final EngineConfig config;
  final http.Client _http;

  /// Where calls are recorded; the engine swaps in a fresh one per generation.
  Usage? usage;

  /// A copy recording into [u] (generations run concurrently, each with its own meter).
  Claude withUsage(Usage u) => Claude(apiKey, config: config, client: _http, usage: u);

  Future<Json> _create(String step, Json params) async {
    final model = params['model'] as String;
    final headers = {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      // The glasses app calls the API straight from its WebView with the user's own key.
      if (isWeb) 'anthropic-dangerous-direct-browser-access': 'true',
    };
    final body = {...params};
    if (config.fallbacks && fallbackModels.contains(model)) {
      headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
      body['fallbacks'] = 'default';
    }
    final encoded = jsonEncode(body);
    // Retry like the official SDKs: 408/409/429/5xx and network errors, with backoff.
    for (var attempt = 0;; attempt++) {
      http.Response r;
      try {
        r = await _http
            .post(Uri.parse(apiUrl), headers: headers, body: encoded)
            .timeout(const Duration(minutes: 5));
      } on TimeoutException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      } on http.ClientException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      final retryable = r.statusCode == 408 || r.statusCode == 409 || r.statusCode == 429 || r.statusCode >= 500;
      if (retryable && attempt < 3) {
        final after = int.tryParse(r.headers['retry-after'] ?? '');
        await Future<void>.delayed(Duration(seconds: math.min(after ?? (2 << attempt), 30)));
        continue;
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Json;
      if (r.statusCode != 200) {
        throw ClaudeError(r.statusCode, ((j['error'] as Map?)?['message'] ?? r.body) as String);
      }
      usage?.record(step, (j['model'] as String?) ?? model, j['usage'] as Json?);
      return j;
    }
  }

  /// Blocks to send back when resuming a paused turn. After a mid-output fallback, blocks
  /// before the last `fallback` marker other than text and paired server-tool blocks are dropped.
  static List<Json> _echo(List<Json> content) {
    final last = content.lastIndexWhere((b) => b['type'] == 'fallback');
    if (last < 0) return content;
    final resultIds = {
      for (final b in content)
        if ((b['type'] as String).endsWith('_tool_result')) b['tool_use_id'],
    };
    return [
      for (var i = 0; i < content.length; i++)
        if (i >= last ||
            content[i]['type'] == 'text' ||
            (content[i]['type'] as String).endsWith('_tool_result') ||
            (content[i]['type'] == 'server_tool_use' && resultIds.contains(content[i]['id'])))
          content[i],
    ];
  }

  /// A server-tool turn (web search / fetch), resuming pause_turn. Returns all content blocks.
  Future<List<Json>> research(String system, String user, List<Json> tools,
      {String step = 'research', String? model}) async {
    final messages = <Json>[
      {'role': 'user', 'content': user},
    ];
    final blocks = <Json>[];
    for (var i = 0; i < 4; i++) {
      final resp = await _create(step, {
        'model': model ?? config.researchModel,
        'max_tokens': config.maxTokens,
        'system': system,
        'tools': tools,
        'output_config': {'effort': config.effortResearch},
        'messages': messages,
      });
      if (resp['stop_reason'] == 'refusal') {
        throw ClaudeRefused((resp['stop_details'] as Map?)?['category'] as String?);
      }
      final content = (resp['content'] as List).cast<Json>();
      blocks.addAll(content);
      if (resp['stop_reason'] != 'pause_turn') break;
      messages.add({'role': 'assistant', 'content': _echo(content)});
    }
    return blocks;
  }

  /// One call that must return JSON matching [schema] (dialogue, check, review).
  Future<Json> json(String system, String user, Json schema, String effort,
      {bool check = false, String? step}) async {
    final resp = await _create(step ?? (check ? 'check' : 'dialogue'), {
      'model': check ? config.checkModel : config.model,
      'max_tokens': config.maxTokens,
      'system': system,
      'output_config': {
        'effort': effort,
        'format': {'type': 'json_schema', 'schema': schema},
      },
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    if (resp['stop_reason'] == 'refusal') {
      throw ClaudeRefused((resp['stop_details'] as Map?)?['category'] as String?);
    }
    if (resp['stop_reason'] == 'max_tokens') throw StateError('output truncated (max_tokens)');
    final text = (resp['content'] as List).cast<Json>().firstWhere((b) => b['type'] == 'text')['text'] as String;
    return jsonDecode(text) as Json;
  }

  /// Cheapest possible call to check the key works.
  Future<void> ping() => _create('ping', {
        'model': config.checkModel,
        'max_tokens': 1,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
      });
}
