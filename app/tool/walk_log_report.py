"""Reads the phone app's walk logs (Settings > Developer > Keep a walk log; JSON Lines, one file per walk).

Usage (Python 3, no packages needed):
  python3 app/tool/walk_log_report.py summary <dir>   cost by step and model, outcomes, failures
  python3 app/tool/walk_log_report.py passes <dir>    for each conversation: did the walk come near the place, and when
  python3 app/tool/walk_log_report.py drafts <dir> [name]
                                                      the conversations before and after escalation (facts, lines, review)

The logs hold your route: keep them out of the repository (private/ is ignored).
"""
import collections
import glob
import json
import math
import os
import sys
from datetime import datetime

TRIGGER_RADIUS_M = 60  # triggerRadiusM in lib/radar.dart
NAMES = {'ootori': 'シレイ', 'shiori': 'フクロウ', 'tetsu': 'スフィンクス', 'midori': 'キョウリュウ',
         'kotoha': 'キツネ', 'rei': 'サル', 'gear': 'アザラシ', 'kagura': 'ネコ'}


def load(path):
    files = sorted(glob.glob(os.path.join(path, '*.jsonl'))) if os.path.isdir(path) else [path]
    return {os.path.basename(f): [json.loads(l) for l in open(f, encoding='utf-8') if l.strip()] for f in files}


def ts(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))


def dist(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def generations(walks):
    return [(w, e) for w, evs in walks.items() for e in evs if e['type'] in ('generation', 'discover')]


def usd(e):
    return e.get('usage', {}).get('usd') or 0


def summary(walks):
    print('# Walks')
    for w, evs in walks.items():
        pos = [e for e in evs if e['type'] == 'pos']
        d = sum(x for a, b in zip(pos, pos[1:]) if (x := dist(a['lat'], a['lon'], b['lat'], b['lon'])) < 500)
        c = collections.Counter(e['type'] for e in evs)
        mins = (ts(evs[-1]['t']) - ts(evs[0]['t'])).total_seconds() / 60
        print(f"{w}: {mins:.0f} min, {d:.0f} m, {len(pos)} fixes{'' if c['walk_end'] else ', no walk_end'}; "
              f"ring {c['ring']}, answer {c['answer']}, later {c['later']}")
    gens = generations(walks)
    total = sum(usd(e) for _, e in gens)
    print(f'\n# Outcomes (total ${total:.3f})')
    for k, n in collections.Counter((e['type'], e.get('outcome'), e.get('reason')) for _, e in gens).most_common():
        same = [e for _, e in gens if (e['type'], e.get('outcome'), e.get('reason')) == k]
        print(f"{k}: {n}, ${sum(usd(e) for e in same):.3f}, median {sorted(e['ms'] for e in same)[n // 2] / 1000:.0f}s")
    print('\n# Cost by step and model')
    by = collections.defaultdict(lambda: collections.Counter())
    for _, e in gens:
        for s in e.get('usage', {}).get('steps', []):
            b = by[(s['step'], s['model'])]
            b['n'] += 1
            b['usd'] += s.get('usd') or 0
            b['in'] += s['input']
            b['out'] += s['output']
            b['searches'] += s.get('searches', 0)
            b['cache_read'] += s.get('cache_read', 0)
    for (step, model), b in sorted(by.items(), key=lambda x: -x[1]['usd']):
        n = b['n']
        print(f"{step:9} {model:18} n={n:3} ${b['usd']:.3f} ({b['usd'] / total * 100 if total else 0:4.1f}%) "
              f"in {b['in'] / n:6.0f}/call out {b['out'] / n:5.0f}/call searches {b['searches']} cache_read {b['cache_read']}")
    esc = collections.defaultdict(list)
    for _, e in gens:
        if e.get('review'):
            esc[bool(e['review'].get('escalated'))].append(e)
    print('\n# Escalation')
    for k, xs in esc.items():
        ok = sum((x['review'].get('score') or 0) >= 3.5 for x in xs)
        print(f"escalated={k}: {len(xs)} runs, avg ${sum(usd(x) for x in xs) / len(xs):.3f}, score >= 3.5: {ok}/{len(xs)}")


def passes(walks):
    """For each conversation: the closest the walk came to the place, and whether that was before it was ready."""
    pos = sorted(((ts(e['t']), e['lat'], e['lon']) for evs in walks.values() for e in evs if e['type'] == 'pos'))
    rang = {e.get('generated_at') for evs in walks.values() for e in evs if e['type'] == 'ring'}
    counts = collections.Counter()
    for _, e in generations(walks):
        if e['type'] != 'generation' or e.get('outcome') != 'ready':
            continue
        sp = e['spot']
        name = f"{sp['name']}/{e.get('theme')}"
        if sp.get('lat') is None or not pos:
            print(f'  ?      {name}: no coordinates')
            continue
        ready_at = ts(e['t'])
        inside = [t for t, la, lo in pos if dist(la, lo, sp['lat'], sp['lon']) <= TRIGGER_RADIUS_M]
        closest = min(pos, key=lambda p: dist(p[1], p[2], sp['lat'], sp['lon']))
        near = dist(closest[1], closest[2], sp['lat'], sp['lon'])
        if e.get('generated_at') in rang:
            verdict = 'rang'
        elif sp.get('kind') == 'area' or sp['id'].startswith('chat:'):
            verdict = 'town/chat (no radius)'
        elif not inside:
            verdict = f'never within {TRIGGER_RADIUS_M} m'
        elif max(inside) < ready_at:
            verdict = f'too late: left {(ready_at - max(inside)).total_seconds():.0f}s before it was ready'
        else:
            verdict = 'within range after ready, did not ring'
        counts[verdict.split(':')[0]] += 1
        print(f"  {name:40} prefetch={str(e.get('prefetch')):5} {e['ms'] / 1000:4.0f}s ${usd(e):.3f} "
              f"closest {near:5.0f} m at {closest[0].strftime('%H:%M:%S')}  -> {verdict}")
    print('\n', dict(counts))


def drafts(walks, name=None):
    for _, e in generations(walks):
        ds = e.get('drafts')
        if not ds or (name and name not in e['spot']['name']):
            continue
        if name is None and len(ds) < 2:
            continue  # without a name: only the escalated ones
        print('=' * 80)
        print(f"{e['spot']['name']} / {e.get('theme')}  {e['t']}  {e.get('outcome')} {e.get('reason') or ''} ${usd(e):.3f}")
        for d in ds:
            r = d.get('review') or {}
            print(f"\n--- {d['stage']}{'  [chosen]' if d.get('chosen') else ''}  research={d['research_model']}  "
                  f"facts={len(d['facts'])}  score={r.get('score', '-')}  attempt={r.get('attempt', '-')}")
            for i, f in enumerate(d['facts'], 1):
                print(f'  fact {i}: {f}')
            for l in d.get('lines', []):
                print(f"  {NAMES.get(l['speaker'], l['speaker'])}: {l['text']}")
            if r.get('issues'):
                print('  review issues:', ' / '.join(r['issues']))
        print()


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('summary', 'passes', 'drafts'):
        sys.exit(__doc__)
    w = load(sys.argv[2])
    {'summary': summary, 'passes': passes}.get(sys.argv[1], lambda w: drafts(w, sys.argv[3] if len(sys.argv) > 3 else None))(w)
