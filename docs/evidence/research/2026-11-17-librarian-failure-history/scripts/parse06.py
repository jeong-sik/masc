import re, json, sys, fnmatch, datetime
RAW = sys.argv[1]; OUT = sys.argv[2]
BASE = ['lib/keeper/keeper_librarian_*', 'lib/lane_addon/*', 'addons/keeper-librarian/*', 'addons/exact_worker.py']
MEM = 'lib/keeper/keeper_memory_*'
TYPES = ['feat','fix','refactor','perf','test','docs','revert']
def ctype(s):
    if s.startswith('Revert "') or s.lower().startswith('revert'): 
        m = re.match(r'^(\w+)', s)
        if m and m.group(1).lower()=='revert': return 'revert'
    m = re.match(r'^([a-zA-Z]+)(\([^)]*\))?!?:', s)
    if not m: return 'other'
    t = m.group(1).lower()
    return t if t in TYPES else 'other'
commits = []
cur = None
for line in open(RAW, encoding='utf-8'):
    line = line.rstrip('\n')
    if line.startswith('@@@'):
        h, d, s = line[3:].split('\t', 2)
        cur = {'hash': h, 'date': d, 'subject': s, 'files': []}
        commits.append(cur)
    elif line.strip():
        cur['files'].append(line.strip())
out = []
for c in commits:
    base = [f for f in c['files'] if any(fnmatch.fnmatch(f, p) for p in BASE)]
    mem = [f for f in c['files'] if fnmatch.fnmatch(f, MEM)]
    lib_subj = bool(re.search(r'librarian|사서', c['subject'], re.I))
    if base or (mem and lib_subj):
        files = base + (mem if lib_subj else [])
        dt = datetime.datetime.fromisoformat(c['date'])
        iy, iw, _ = dt.isocalendar()
        pr = re.findall(r'\(#(\d+)\)', c['subject'])
        out.append({'hash': c['hash'][:12], 'date': c['date'], 'week': f'{iy}-W{iw:02d}', 'type': ctype(c['subject']),
                    'subject': c['subject'], 'pr': pr[-1] if pr else None, 'files': files,
                    'via': 'base' if base else 'memory+subject'})
json.dump(out, open(OUT, 'w'), ensure_ascii=False, indent=0)
print('raw commits', len(commits), 'selected', len(out), 'via base', sum(o['via']=='base' for o in out), 'via memory+subject', sum(o['via']!='base' for o in out))
