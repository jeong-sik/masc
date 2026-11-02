#!/usr/bin/env python3
"""Read-only prefix-cache audit of the Agent Core lanes.

Reads, for the given UTC dates, the per-request costs ledger, every keeper's
turn records, provider-input snapshots and execution receipts, and emits
aggregates with source hashes. Prompt bodies never enter the report. With
--read-system-prefix, system blobs are read and verified to measure their raw
byte prefix; otherwise snapshots are compared only by retained hashes.

What it answers, per provider family:
  - how much of each request's input the provider read from its cache;
  - the first round of a turn against the later rounds of the same turn;
  - the first round's miss against the idle gap before it;
  - whether consecutive turns' request snapshots share a byte-identical
    message prefix, before and after a deploy instant;
  - how the tool list differs between consecutive turns after the deploy;
  - requests above one megabyte, and why turns ended per selected model.
"""
import argparse
import collections
import dataclasses
import datetime
import hashlib
import json
import re
import statistics
from pathlib import Path


@dataclasses.dataclass
class RoundStats:
    """Accumulator for one (family, era): first rounds against later rounds."""
    first_ratio: list[float] = dataclasses.field(default_factory=list)
    first_miss: list[int] = dataclasses.field(default_factory=list)
    first_input: list[int] = dataclasses.field(default_factory=list)
    later_ratio: list[float] = dataclasses.field(default_factory=list)
    later_miss: list[int] = dataclasses.field(default_factory=list)
    first_missed_sum: int = 0
    later_missed_sum: int = 0


@dataclasses.dataclass
class UsageStats:
    """Accumulator for one family over settled turn records."""
    rows: int = 0
    completed: int = 0
    cache_read_positive: int = 0
    input_sum: int = 0
    cache_read_sum: int = 0
    ttfrc: dict[str, list[float]] = dataclasses.field(default_factory=lambda: collections.defaultdict(list))


@dataclasses.dataclass
class PrefixStats:
    """Accumulator for one (keeper, lane, era) over consecutive snapshots."""
    pairs: int = 0
    prev_is_prefix: int = 0
    lcp: list[float | None] = dataclasses.field(default_factory=list)
    first_diff: list[int] = dataclasses.field(default_factory=list)
    body: list[int | None] = dataclasses.field(default_factory=list)

SHA_RE = re.compile(r'sha256=([0-9a-f]{64})')
GAP_BUCKETS = [(0, 60), (60, 300), (300, 900), (900, 3600), (3600, None)]
UNCACHED_BUCKETS = [(0, 2000), (2000, 8000), (8000, 20000), (20000, 50000), (50000, None)]
OVERSIZED_BYTES = 1_000_000
FULL_MISS_RATIO = 0.9

parser = argparse.ArgumentParser()
parser.add_argument('--masc-root', type=Path, required=True)
parser.add_argument('--date', action='append', required=True,
                    help='UTC date, YYYY-MM-DD; repeat for several days')
parser.add_argument('--keeper', action='append',
                    help='Restrict keeper directories and cost-ledger agents; repeat to select several')
parser.add_argument('--read-system-prefix', action='store_true',
                    help='Verify system blobs and compare raw byte prefixes; never report prompt text')
parser.add_argument('--deploy-at',
                    help='Optional ISO-8601 UTC deployment instant for a before/after comparison')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()

deploy_at = (datetime.datetime.fromisoformat(args.deploy_at.replace('Z', '+00:00')).timestamp()
             if args.deploy_at else None)
comparison_era = 'after_deploy' if deploy_at is not None else 'sample'
sources, malformed = [], []


def read_rows(path):
    # Capture the current bytes once; appends after this read are outside this sample.
    if not path.exists():
        return []
    raw = path.read_bytes()
    sources.append({'path': str(path.relative_to(args.masc_root)),
                    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
    rows = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError('expected JSON object')
            rows.append(row)
        except (ValueError, UnicodeDecodeError):
            malformed.append({'path': str(path.relative_to(args.masc_root)), 'line': number})
    return rows


def day_paths(kind):
    for date in args.date:
        day = datetime.date.fromisoformat(date)
        month, stem = day.strftime('%Y-%m'), day.strftime('%d')
        if kind == 'costs':
            yield args.masc_root / 'costs' / month / (stem + '.jsonl')
        else:
            for keeper in sorted((args.masc_root / 'keepers').glob('*')):
                if args.keeper and keeper.name not in args.keeper:
                    continue
                yield keeper / kind / month / (stem + '.jsonl')


def seconds(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if isinstance(value, str):
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    return None


def family(runtime_id):
    runtime_id = runtime_id or ''
    return 'ollama_cloud' if runtime_id.startswith('ollama_cloud') else runtime_id.split('.')[0]


def era(ts):
    if deploy_at is None:
        return 'sample'
    return 'after_deploy' if ts >= deploy_at else 'before_deploy'


def count(value):
    # Token and byte counts are nonnegative integers; bool is not a count.
    return value if type(value) is int and value >= 0 else None


def duration(value):
    # Latencies are recorded in milliseconds and may carry a fraction.
    return float(value) if type(value) in (int, float) and value >= 0 else None


def summary(values):
    known = [v for v in values if v is not None]
    return {'n': len(known),
            'median': statistics.median(known) if known else None,
            'mean': statistics.mean(known) if known else None,
            'p90': sorted(known)[int(len(known) * 0.9)] if known else None}


def bucket_label(lo, hi):
    return f'{lo}-{hi if hi is not None else "inf"}'


# ── per-request ledger ────────────────────────────────────────────────
ledger = []
for path in day_paths('costs'):
    ledger.extend(read_rows(path))
requests = []
# A raw row without usage_scope was written before rows stated one; whether it
# was one request is unknown, so it is counted apart, not read as a request.
raw_rows_without_scope = 0
for row in ledger:
    if args.keeper and row.get('agent') not in args.keeper:
        continue
    if row.get('usage_projection') == 'raw_observation' and 'usage_scope' not in row:
        raw_rows_without_scope += 1
    ts = seconds(row.get('timestamp'))
    tokens = count(row.get('input_tokens'))
    read = count(row.get('cache_read_tokens'))
    # Only a per-request raw row is one request; official-client rows count a
    # client turn or a whole conversation (usage_scope).
    if (row.get('usage_projection') != 'raw_observation'
            or row.get('usage_scope') != 'per_request'
            or ts is None or not tokens or read is None or read > tokens):
        continue
    requests.append({'agent': row.get('agent'), 'runtime_id': row.get('runtime_id'),
                     'turn': row.get('keeper_turn_id'), 'ordinal': row.get('agent_core_turn_ordinal'),
                     'ts': ts, 'input': tokens, 'miss': tokens - read})
requests.sort(key=lambda r: (r['ts'], r['ordinal'] if isinstance(r['ordinal'], int) else 0))

turns = collections.defaultdict(list)
for r in requests:
    turns[(r['agent'], r['runtime_id'], r['turn'])].append(r)
for rows in turns.values():
    rows.sort(key=lambda r: r['ordinal'] if isinstance(r['ordinal'], int) else 0)
    rows[0]['first'] = True
    for r in rows[1:]:
        r['first'] = False

rounds: dict[tuple[str, str], RoundStats] = collections.defaultdict(RoundStats)
gaps: dict[str, dict[str, list[float]]] = collections.defaultdict(lambda: collections.defaultdict(list))
last_seen, previous_first = {}, {}
growth: dict[tuple[str, str], list[int]] = collections.defaultdict(list)
for r in requests:
    key = (family(r['runtime_id']), era(r['ts']))
    ratio = r['miss'] / r['input']
    pair = (r['agent'], r['runtime_id'])
    if r['first']:
        rounds[key].first_ratio.append(ratio)
        rounds[key].first_miss.append(r['miss'])
        rounds[key].first_input.append(r['input'])
        rounds[key].first_missed_sum += r['miss']
        if pair in last_seen:
            gap = r['ts'] - last_seen[pair]
            for lo, hi in GAP_BUCKETS:
                if lo <= gap and (hi is None or gap < hi):
                    gaps[family(r['runtime_id'])][bucket_label(lo, hi)].append(ratio)
                    break
        before = previous_first.get(pair)
        if before is not None and r['turn'] == before['turn'] + 1 and r['input'] > before['input']:
            growth[key].append(r['input'] - before['input'])
        previous_first[pair] = r
    else:
        rounds[key].later_ratio.append(ratio)
        rounds[key].later_miss.append(r['miss'])
        rounds[key].later_missed_sum += r['miss']
    last_seen[pair] = r['ts']

rounds_report = []
for (fam, when), s in sorted(rounds.items()):
    missed = s.first_missed_sum + s.later_missed_sum
    rounds_report.append({
        'family': fam, 'era': when,
        'first_rounds': {'n': len(s.first_ratio),
                         'miss_ratio': summary(s.first_ratio),
                         'miss_tokens': summary(s.first_miss),
                         'input_tokens': summary(s.first_input),
                         'full_miss_share': (sum(1 for x in s.first_ratio if x > FULL_MISS_RATIO)
                                             / len(s.first_ratio)) if s.first_ratio else None},
        'later_rounds': {'n': len(s.later_ratio),
                         'miss_ratio': summary(s.later_ratio),
                         'miss_tokens': summary(s.later_miss)},
        'share_of_missed_tokens_in_first_rounds': s.first_missed_sum / missed if missed else None,
        'input_growth_per_turn_tokens': summary(growth[(fam, when)])})
gap_report = [{'family': fam, 'gap_seconds': label, 'first_round_miss_ratio': summary(v),
               'full_miss_share': sum(1 for x in v if x > FULL_MISS_RATIO) / len(v)}
              for fam in sorted(gaps) for label, v in gaps[fam].items()]

# ── turn records: settled usage, latency, oversized bodies ──────────────
records = []
for path in day_paths('turn-records'):
    records.extend(read_rows(path))
usage: dict[str, UsageStats] = collections.defaultdict(UsageStats)
oversized: dict[str, dict[str, int]] = collections.defaultdict(lambda: {'rows': 0, 'completed': 0, 'max_bytes': 0})
for row in records:
    u = usage[family(row.get('runtime_profile'))]
    u.rows += 1
    completed = row.get('finish_reason') is not None
    body = count(row.get('request_body_bytes')) or 0
    if body > OVERSIZED_BYTES:
        o = oversized[str(row.get('runtime_profile'))]
        o['rows'] += 1
        o['completed'] += int(completed)
        o['max_bytes'] = max(o['max_bytes'], body)
    if not completed:
        continue
    u.completed += 1
    tokens, read = count(row.get('input_tokens')), count(row.get('cache_read_input_tokens'))
    if (row.get('usage_scope') != 'per_request'
            or tokens is None or read is None or read > tokens):
        continue
    u.input_sum += tokens
    u.cache_read_sum += read
    u.cache_read_positive += int(read > 0)
    ttfrc = duration(row.get('ttfrc_ms'))
    if ttfrc:
        uncached = tokens - read
        for lo, hi in UNCACHED_BUCKETS:
            if lo <= uncached and (hi is None or uncached < hi):
                u.ttfrc[bucket_label(lo, hi)].append(ttfrc)
                break
# The first round after the deploy, split by the idle gap before it and by
# whether the turn's tool surface (its record's tool_surface_ref) is the
# previous turn's: what remains once the front no longer moves.
surface_ref = {(row.get('keeper'), row.get('runtime_profile'), row.get('absolute_turn')): row.get('tool_surface_ref')
               for row in records}
cross: dict[str, dict[tuple[str, str], list[float]]] = collections.defaultdict(lambda: collections.defaultdict(list))
last_seen_ts, previous_turn = {}, {}
for r in requests:
    pair = (r['agent'], r['runtime_id'])
    if r['first'] and era(r['ts']) == comparison_era and pair in last_seen_ts:
        gap = 'gap<15m' if r['ts'] - last_seen_ts[pair] < 900 else 'gap>=15m'
        before = surface_ref.get((r['agent'], r['runtime_id'], previous_turn.get(pair)))
        now = surface_ref.get((r['agent'], r['runtime_id'], r['turn']))
        tools = 'unknown' if before is None or now is None else ('same' if before == now else 'changed')
        cross[family(r['runtime_id'])][(gap, tools)].append(r['miss'] / r['input'])
    if r['first']:
        previous_turn[pair] = r['turn']
    last_seen_ts[pair] = r['ts']
cross_report = [{'family': fam, 'gap': gap, 'tools': tools, 'first_round_miss_ratio': summary(v),
                 'full_miss': sum(1 for x in v if x > FULL_MISS_RATIO)}
                for fam in sorted(cross) for (gap, tools), v in sorted(cross[fam].items())]

usage_report = [{'family': fam, 'rows': u.rows, 'completed': u.completed,
                 'cache_read_positive': u.cache_read_positive,
                 'cache_read_over_input': u.cache_read_sum / u.input_sum if u.input_sum else None,
                 'ttfrc_ms_by_uncached_tokens': {label: summary(v) for label, v in sorted(u.ttfrc.items())}}
                for fam, u in sorted(usage.items())]
oversized_report = [{'runtime': rid, **o} for rid, o in sorted(oversized.items())]

# ── provider-input snapshots: prefix identity between consecutive turns ──
snapshots = []
for path in day_paths('provider-inputs'):
    snapshots.extend(read_rows(path))


def sha_of(artifact):
    match = SHA_RE.search((artifact or {}).get('content_ref') or '')
    return match.group(1) if match else None


by_lane = collections.defaultdict(list)
for snap in snapshots:
    ts = seconds(snap.get('captured_at'))
    if ts is None or not isinstance(snap.get('absolute_turn'), int):
        continue
    by_lane[(snap.get('keeper'), snap.get('runtime_profile'))].append(snap)


system_blobs = {}


def verified_system_blob(artifact):
    sha = sha_of(artifact)
    expected = count((artifact or {}).get('bytes'))
    if sha is None or expected is None:
        return None
    key = (sha, expected)
    if key in system_blobs:
        return system_blobs[key]
    path = args.masc_root / 'tool_blobs' / sha[:2] / sha
    try:
        raw = path.read_bytes()
    except OSError:
        malformed.append({'path': str(path.relative_to(args.masc_root)),
                          'error': 'system_blob_unavailable'})
        system_blobs[key] = None
        return None
    sources.append({'path': str(path.relative_to(args.masc_root)),
                    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
    if len(raw) != expected or hashlib.sha256(raw).hexdigest() != sha:
        malformed.append({'path': str(path.relative_to(args.masc_root)),
                          'error': 'system_blob_digest_or_length_mismatch'})
        system_blobs[key] = None
        return None
    system_blobs[key] = raw
    return raw


def common_prefix_bytes(left, right):
    return next((i for i, (a, b) in enumerate(zip(left, right)) if a != b),
                min(len(left), len(right)))


def tools_identity(snap):
    if not isinstance(snap.get('tool_schemas'), list):
        return None
    tools = [(t.get('name'), sha_of(t.get('artifact')))
             for t in snap.get('tool_schemas') or []]
    return tools if all(name is not None and sha is not None for name, sha in tools) else None


record_index = collections.defaultdict(list)
for row in records:
    record_index[(row.get('keeper'), row.get('trace_id'), row.get('absolute_turn'))].append(row)
system_samples = []
system_sample_by_snapshot = {}
prefix_report = []
tool_changes = collections.Counter()
tool_added, tool_removed, tool_schema_changed = collections.Counter(), collections.Counter(), collections.Counter()
for (keeper, lane), snaps in sorted(by_lane.items()):
    snaps.sort(key=lambda s: s['absolute_turn'])
    per_era: dict[str, PrefixStats] = collections.defaultdict(PrefixStats)
    for snap in snaps:
        per_era[era(seconds(snap['captured_at']))].body.append(count((snap.get('wire') or {}).get('body_bytes')))
        if args.read_system_prefix:
            system = verified_system_blob(snap.get('system_prompt'))
            settled = record_index[(keeper, snap.get('trace_id'), snap['absolute_turn'])]
            reported = settled[0] if len(settled) == 1 else None
            tokens = count(reported.get('input_tokens')) if reported else None
            read = count(reported.get('cache_read_input_tokens')) if reported else None
            scope = reported.get('usage_scope') if reported else None
            system_samples.append({
                'keeper': keeper, 'lane': lane, 'turn_ref': snap.get('turn_ref'),
                'captured_at': snap['captured_at'], 'wire': snap.get('wire'),
                'system_bytes': len(system) if system is not None else None,
                'system_sha256': sha_of(snap.get('system_prompt')),
                'last_reported_turn_usage': {
                    'scope': scope,
                    'runtime_profile': reported.get('runtime_profile') if reported else None,
                    'selected_model': reported.get('selected_model') if reported else None,
                    'input_tokens': tokens, 'cache_read_input_tokens': read,
                    'cache_read_share': read / tokens if (scope == 'per_request' and tokens
                                                          and read is not None and read <= tokens) else None,
                    'binding': 'same_turn_not_proof_of_same_serialized_request'},
                'previous_system': None})
            system_sample_by_snapshot[id(snap)] = system_samples[-1]
    for a, b in zip(snaps, snaps[1:]):
        # A pair belongs to an era only when both snapshots do; a pair that
        # straddles the deploy would credit one era with the other's cut.
        if (b['absolute_turn'] != a['absolute_turn'] + 1
                or a.get('trace_id') != b.get('trace_id')
                or era(seconds(a['captured_at'])) != era(seconds(b['captured_at']))):
            continue
        when = era(seconds(b['captured_at']))
        e = per_era[when]
        e.pairs += 1
        ma = [sha_of(m.get('artifact')) for m in a.get('messages') or []]
        mb = [sha_of(m.get('artifact')) for m in b.get('messages') or []]
        i = 0
        while i < len(ma) and i < len(mb) and ma[i] is not None and ma[i] == mb[i]:
            i += 1
        e.lcp.append(i / len(ma) if ma else None)
        e.first_diff.append(i)
        e.prev_is_prefix += int(i >= len(ma))
        if args.read_system_prefix:
            sa, sb = verified_system_blob(a.get('system_prompt')), verified_system_blob(b.get('system_prompt'))
            ta, tb = tools_identity(a), tools_identity(b)
            # Identify this exact capture, not a later row with the same turn.
            sample = system_sample_by_snapshot[id(b)]
            sample['previous_system'] = {
                'turn_ref': a.get('turn_ref'),
                'bytes': len(sa) if sa is not None else None,
                'common_prefix_bytes': common_prefix_bytes(sa, sb) if sa is not None and sb is not None else None,
                'identical': sa == sb if sa is not None and sb is not None else None,
                'same_provider_model_codec': all(isinstance((a.get('wire') or {}).get(k), str)
                                               and (a.get('wire') or {}).get(k) == (b.get('wire') or {}).get(k)
                                               for k in ['provider', 'model', 'http_codec']),
                'same_tool_schemas': ta == tb if ta is not None and tb is not None else None}
        if when != comparison_era:
            continue
        ta, tb = tools_identity(a), tools_identity(b)
        if ta is None or tb is None:
            tool_changes['unknown'] += 1
            continue
        if ta == tb:
            tool_changes['identical'] += 1
            continue
        na, nb = [n for n, _ in ta], [n for n, _ in tb]
        added = [n for n in nb if n not in na]
        removed = [n for n in na if n not in nb]
        reordered = [n for n in na if n in nb] != [n for n in nb if n in na]
        schema_changed = [n for n, s in ta if n in dict(tb) and dict(tb)[n] != s]
        kind = ''.join(['+' if added else '', '-' if removed else '',
                        '~order' if reordered else '', '~schema' if schema_changed else ''])
        tool_changes[kind] += 1
        if not removed and not reordered and not schema_changed and tb[:len(ta)] == ta:
            tool_changes['pure_append_at_end'] += 1
        tool_added.update(added)
        tool_removed.update(removed)
        tool_schema_changed.update(schema_changed)
    for when, e in sorted(per_era.items()):
        prefix_report.append({'keeper': keeper, 'lane': lane, 'era': when, 'snapshots': len(e.body),
                              'pairs': e.pairs, 'prev_is_prefix_of_next': e.prev_is_prefix,
                              'lcp_share': summary(e.lcp), 'first_diff_index': summary(e.first_diff),
                              'body_bytes': summary(e.body)})
tool_report = {'era': comparison_era,
               'pairs': sum(v for k, v in tool_changes.items() if k != 'pure_append_at_end'),
               'kinds': dict(tool_changes), 'added': tool_added.most_common(10),
               'removed': tool_removed.most_common(10), 'schema_changed': tool_schema_changed.most_common(10)}

# ── execution receipts: why turns ended, per selected model ─────────────
receipts = []
for path in day_paths('execution-receipts'):
    receipts.extend(read_rows(path))
ends = collections.defaultdict(collections.Counter)
for row in receipts:
    runtime = row.get('runtime') if isinstance(row.get('runtime'), dict) else {}
    model = runtime.get('selected_model') or 'unknown'
    ends[model][str(row.get('terminal_reason_code'))] += 1
receipt_report = [{'selected_model': model, 'receipts': sum(c.values()), 'terminal_reason_codes': c.most_common(10)}
                  for model, c in sorted(ends.items(), key=lambda kv: -sum(kv[1].values()))]

report = {'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
          'dates': args.date, 'deploy_at': args.deploy_at, 'keepers': args.keeper,
          'evidence_limits': [
              'Raw common-prefix bytes are not a provider tokenizer or measured KV-cache reuse.',
              'First round means first observed ledger row in the sample; ordinal zero may be absent.',
              'Missed input means input minus cache reads, including any new cache writes.',
              'Turn usage has no response-to-capture digest; it cannot certify a serialized snapshot cache hit.'],
          'sources': sources, 'malformed': malformed,
          'raw_rows_without_scope': raw_rows_without_scope,
          'requests_read': len(requests), 'turn_records_read': len(records),
          'snapshots_read': len(snapshots), 'receipts_read': len(receipts),
          'settled_usage_by_family': usage_report,
          'rounds_by_family_and_era': rounds_report,
          'first_round_miss_by_gap': gap_report,
          'first_round_by_gap_and_tools': cross_report,
          'consecutive_snapshot_prefix': prefix_report,
          'system_prompt_cache_samples': system_samples,
          'tool_list_changes': tool_report,
          'oversized_requests': oversized_report,
          'turn_ends_by_selected_model': receipt_report}
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
