#!/usr/bin/env python3
"""Offline diagnostic of synthetic Record IDs; no layout assertion or live IO."""
import argparse
import bisect
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).with_name('analysis-deps')))
import pyte

p = argparse.ArgumentParser()
p.add_argument('root', type=Path)
a = p.parse_args()
observations = []
for item in json.loads((a.root / 'order.json').read_text()):
    path = Path(item['result'])
    r = json.loads(path.read_text())
    raw = path.with_name('capture.ansi').read_bytes()
    ends = []
    total = 0
    for chunk in r['chunks']:
        total += chunk['bytes']
        ends.append(total)
    if total != len(raw):
        raise ValueError('Timestamped chunk bytes do not cover ' + str(path))
    screen = pyte.Screen(150, 45)
    stream = pyte.ByteStream(screen)
    previous = 0
    frames = []
    for match in re.finditer(re.escape(b'\x1b[?7h'), raw):
        end = match.end()
        stream.feed(raw[previous:end])
        previous = end
        at = r['chunks'][bisect.bisect_left(ends, end)]['at']
        ids = sorted(set(int(value) for line in screen.display
                         for value in re.findall(r'\bRecord\s+(\d+)\b', line)))
        frames.append({'at': at, 'record_ids': ids})
    start, end = r['observation']['phase_start'], r['observation']['phase_end']
    earlier = [f for f in frames if f['at'] <= start and f['record_ids']]
    during = [f for f in frames if start <= f['at'] <= end and f['record_ids']]
    scrolls = [s for s in r['sends'] if s['name'] == item['condition']]
    last_scroll = scrolls[-1]['at'] if scrolls else None
    later = [f for f in frames if last_scroll is not None and f['at'] >= last_scroll]
    changes = sum(x['record_ids'] != y['record_ids'] for x,y in zip(during,during[1:]))
    observations.append({k:item[k] for k in ['pair','label','condition']} | {
        'result': str(path), 'capture_sha256': hashlib.sha256(raw).hexdigest(),
        'position_writes': sum(s['name'] == 'position' for s in r['sends']),
        'timed_scroll_writes': len(scrolls),
        'prephase_last': earlier[-1] if earlier else None,
        'during_first': during[0] if during else None,
        'during_last': during[-1] if during else None,
        'during_record_set_changes': changes,
        'during_min_record': min((i for f in during for i in f['record_ids']), default=None),
        'during_max_record': max((i for f in during for i in f['record_ids']), default=None),
        'completed_frames_after_last_scroll_write': len(later),
        'last_completed_with_records': next((f for f in reversed(frames) if f['record_ids']), None),
        'frames': frames})
out = {
    'scope': 'Offline VT replay of synthetic Record IDs. This observes emitted viewport content, not physical paint or confirmation that every late scroll write was consumed.',
    'pyte_version': importlib.metadata.version('pyte'),
    'wcwidth_version': importlib.metadata.version('wcwidth'),
    'pyte_documentation': 'https://github.com/selectel/pyte/blob/master/docs/tutorial.rst',
    'runs': observations}
with (a.root / 'viewport-observations.json').open('x') as f:
    json.dump(out, f, indent=2)
for c in ['typing','pageup','pagedown','wheelup','wheeldown']:
    rows = [r for r in observations if r['condition'] == c]
    print(json.dumps({'condition':c,'runs':len(rows),
        'all_have_prephase_records':all(r['prephase_last'] for r in rows),
        'all_show_record_set_changes':all(r['during_record_set_changes'] > 0 for r in rows),
        'observed_min_record':min((r['during_min_record'] for r in rows if r['during_min_record'] is not None),default=None),
        'observed_max_record':max((r['during_max_record'] for r in rows if r['during_max_record'] is not None),default=None),
        'runs_without_frame_after_last_scroll':sum(not r['completed_frames_after_last_scroll_write'] for r in rows)}))
