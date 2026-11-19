"""Read-only extraction for the seat replay. Numbers and labels only; no message text.

Usage: seats_extract.py BASE_PATH (the directory that holds keepers/ and agent-core-events/).

Inputs (all under BASE_PATH, read only):
  1. keepers/<k>/turn-boundaries.jsonl : Turn_ended recorded_at per Keeper (the arrival trace).
  2. agent-core-events/2026-11/DD.jsonl : Streaming_summary (provider kind, model, total_ms, terminal)
     and masc.provider_admission.waited (provider_id, model, admission_class, waited_ms, outcome).
     Exact calls are one synchronous POST (the Exact worker posts once and reads the whole body), so every Streaming_summary is a
     streaming call, i.e. a Keeper turn call, not a Librarian call.
  3. keepers/<k>/metrics/2026-11/DD.jsonl : per-turn runtime_profile and latency_ms (provider mix of
     Keeper turns).
Output: seats_events.json beside this file.
"""
import json, os, glob, re, subprocess, sys, collections, datetime

M = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
END = datetime.datetime(2026, 11, 17, 23, 0).timestamp()
START = END - 7 * 86400
EV_START = datetime.datetime(2026, 11, 10, 0, 0).timestamp()

def arrivals():
    out = collections.defaultdict(list)
    for p in glob.glob(M + '/keepers/*/turn-boundaries.jsonl'):
        k = os.path.basename(os.path.dirname(p))
        with open(p, 'rb') as f:
            for line in f:
                if b'"turn_ended"' not in line[:200] and b'turn_ended' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get('kind') != 'turn_ended':
                    continue
                t = d.get('recorded_at')
                pos = (d.get('position') or {}).get('kind')
                if isinstance(t, (int, float)):
                    out[k].append((t, pos))
    return out

def events():
    ss, adm, fc = [], [], []
    files = sorted(glob.glob(M + '/agent-core-events/2026-11/*.jsonl'))
    files = [f for f in files if int(os.path.basename(f)[:2]) >= 10]
    for f in files:
        p = subprocess.run(['rg', '-N', 'Streaming_summary|Streaming_first_chunk|provider_admission:waited', f],
                           capture_output=True)
        for line in p.stdout.splitlines():
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get('ts_unix')
            pl = d.get('payload')
            if isinstance(pl, list) and len(pl) > 1 and pl[0] == 'Streaming_summary':
                q = pl[1]
                term = q.get('terminal')
                term = term[0] if isinstance(term, list) and term else str(term)
                ss.append((t, q.get('provider'), q.get('model'), q.get('total_ms'), term,
                           d.get('keeper_turn_id') is not None, d.get('correlation_id') or d.get('run_id')))
            elif isinstance(pl, list) and len(pl) > 1 and pl[0] == 'Streaming_first_chunk':
                q = pl[1]
                fc.append((t, q.get('provider'), q.get('model'), q.get('requested_at'), q.get('ttfrc_ms'),
                           d.get('correlation_id') or d.get('run_id')))
            elif isinstance(pl, dict) and 'admission_class' in pl:
                adm.append((t, pl.get('provider_id'), pl.get('model'), pl.get('admission_class'),
                            pl.get('waited_ms'), pl.get('outcome')))
    return ss, adm, fc

PROF = re.compile(rb'"runtime_profile":"([^"]*)"')
LAT = re.compile(rb'"latency_ms":([0-9.]+)')
TS = re.compile(rb'"ts_unix":([0-9.]+)')

def keeper_profiles():
    rows = []
    for p in glob.glob(M + '/keepers/*/metrics/2026-11/*.jsonl'):
        day = int(os.path.basename(p)[:2])
        if day < 10:
            continue
        k = p.split('/keepers/')[1].split('/')[0]
        with open(p, 'rb') as f:
            for line in f:
                a = PROF.search(line); b = LAT.search(line); c = TS.search(line)
                if a and c:
                    rows.append((float(c.group(1)), k, a.group(1).decode(), float(b.group(1)) if b else None))
    return rows

if __name__ == '__main__':
    arr = arrivals()
    ss, adm, fc = events()
    prof = keeper_profiles()
    json.dump(dict(arrivals={k: v for k, v in arr.items()}, ss=ss, adm=adm, fc=fc, prof=prof,
                   window=[START, END]), open(os.path.join(HERE, 'seats_events.json'), 'w'))
    n7 = sum(1 for v in arr.values() for t, _ in v if START <= t < END)
    print('turn_ended in 7 d window', n7, 'keepers with >=1', sum(1 for v in arr.values() if any(START <= t < END for t, _ in v)))
    print('streaming summaries', len(ss), 'first chunks', len(fc), 'admission waits', len(adm), 'metrics rows', len(prof))
