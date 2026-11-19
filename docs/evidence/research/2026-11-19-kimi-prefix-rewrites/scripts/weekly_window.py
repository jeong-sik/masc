# Usage: python3 -I weekly_window.py <base-path>/.masc   (reads the runtime records read-only)
import sys
import json, glob, os, datetime, collections
H=sys.argv[1]; UTC=datetime.timezone.utc
rows=[]
for f in sorted(glob.glob(H+'/provider_usage_history/2026-11/*.jsonl')):
    for line in open(f):
        if 'kimi_coding' not in line: continue
        try: arr=json.loads(line)
        except Exception: continue
        if isinstance(arr,dict): arr=[arr]
        for r in arr:
            if r.get('source')=='kimi_coding.usages' and r.get('kind')=='provider:usage (provider resetTime)':
                rows.append((r['observed_at'],r['value'],r.get('resets_at')))
rows.sort()
# print one row per 6 hours + every reset change
last_ra=None; last_print=0
for t,v,ra in rows:
    if ra!=last_ra or t-last_print>=6*3600:
        print(datetime.datetime.fromtimestamp(t,UTC).strftime('%m-%d %H:%M'), f"{100*v:5.1f}%", 'resets', datetime.datetime.fromtimestamp(ra,UTC).strftime('%m-%d %H:%M') if ra else None, '<- reset changed' if ra!=last_ra else '')
        last_print=t; last_ra=ra
print('last', datetime.datetime.fromtimestamp(rows[-1][0],UTC).strftime('%m-%d %H:%M'), rows[-1][1])
