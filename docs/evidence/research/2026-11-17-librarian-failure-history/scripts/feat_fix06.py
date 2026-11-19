import json, sys, datetime, statistics, collections
c = json.load(open(sys.argv[1]))
for x in c: x['dt'] = datetime.datetime.fromisoformat(x['date'])
feats = sorted([x for x in c if x['type']=='feat'], key=lambda x: x['dt'])
fixes = [x for x in c if x['type']=='fix']
W = datetime.timedelta(days=7)
rows = []
for f in feats:
    fs = set(f['files'])
    after = [x for x in fixes if f['dt'] < x['dt'] <= f['dt']+W and fs & set(x['files'])]
    before = [x for x in fixes if f['dt']-W <= x['dt'] < f['dt'] and fs & set(x['files'])]
    rows.append((f, after, before))
na = [len(a) for _,a,_ in rows]; nb = [len(b) for _,_,b in rows]
def dist(v):
    return f"mean {statistics.mean(v):.2f}, median {statistics.median(v)}, p90 {sorted(v)[int(0.9*(len(v)-1))]}, max {max(v)}, share>=1 {sum(1 for x in v if x)/len(v):.0%} ({sum(1 for x in v if x)}/{len(v)})"
print('feat commits', len(feats))
print('fixes on same files within 7d AFTER feat:', dist(na))
print('control: fixes on same files within 7d BEFORE feat:', dist(nb))
# by month
print()
print('| feat month | feats | mean fixes after (7d) | share >=1 | mean fixes before (7d, control) |')
print('|---|---:|---:|---:|---:|')
bym = collections.defaultdict(list)
for f,a,b in rows: bym[f['date'][:7]].append((len(a),len(b)))
for m in sorted(bym):
    v=bym[m]; print(f"| {m} | {len(v)} | {statistics.mean(x for x,_ in v):.2f} | {sum(1 for x,_ in v if x)/len(v):.0%} | {statistics.mean(y for _,y in v):.2f} |")
# excluding hub files
HUB = {'lib/lane_addon/lane_addon_runtime.ml','lib/lane_addon/lane_addon_runtime.mli','lib/keeper/keeper_librarian_runtime.ml','lib/keeper/keeper_librarian_runtime.mli'}
na2=[]
for f,_,_ in rows:
    fs=set(f['files'])-HUB
    na2.append(len([x for x in fixes if f['dt'] < x['dt'] <= f['dt']+W and fs & (set(x['files'])-HUB)]))
print()
print('sensitivity, hub files lane_addon_runtime.ml(i) and keeper_librarian_runtime.ml(i) excluded from the overlap:', dist(na2))
print()
print('Top 12 feats by fixes-after (7d):')
print('| date | feat | files | fixes after 7d | example fixes |')
print('|---|---|---:|---:|---|')
for f,a,b in sorted(rows, key=lambda r:-len(r[1]))[:12]:
    ex = '; '.join((x['subject'][:70]) for x in a[:2])
    print(f"| {f['date'][:10]} | {f['subject'][:95]} | {len(f['files'])} | {len(a)} | {ex} |")
nb2=[]
for f,_,_ in rows:
    fs=set(f['files'])-HUB
    nb2.append(len([x for x in fixes if f['dt']-W <= x['dt'] < f['dt'] and fs & (set(x['files'])-HUB)]))
print()
print('sensitivity control (BEFORE, hubs excluded):', dist(nb2))
# exact-file pairing: fixes whose file set is a subset-overlap >=50% with feat
