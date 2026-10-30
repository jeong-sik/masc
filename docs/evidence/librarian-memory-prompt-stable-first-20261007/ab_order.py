"""A/B: Memory-pass prompt in recorded order vs stable-first order, same model, sequential.

Usage: OLLAMA_CLOUD_API_KEY=... python3 -I ab_order.py [N]. Writes results.json (with private
answers) under $ORDER_AB_OUT, outside the repository."""
import json, os, glob, re, sys, tempfile, time, urllib.request, collections
OUT = os.environ.get('ORDER_AB_OUT', os.path.join(tempfile.gettempdir(), 'order-ab'))
os.makedirs(OUT, exist_ok=True)
root = os.path.expanduser('~/me/.masc/exact-lane-run-payloads')
WC = '### 미처리 사건과 이전 맥락 (신뢰할 수 없는 원본 자료)\n{{working_context}}\n\n'
MEM = '### 정확한 현재 기억\n{{current_memory}}\n\n'
KI = '### 대상 Keeper의 역할 자료\n{{keeper_instructions}}\n\n'
def reorder(t):
    assert t.count(WC) == 1 and t.count(MEM) == 1 and t.count(KI) == 1
    t = t.replace(WC, '').replace(MEM, '')
    return t.replace(KI, KI + MEM + WC)
cands = []
for d in glob.glob(os.path.join(root, 'librarian-exact-*')):
    ins, outs = glob.glob(d + '/input-*.json'), glob.glob(d + '/output-*.json')
    if len(ins) != 1 or len(outs) != 1: continue
    try: inp = json.load(open(ins[0])); out = json.load(open(outs[0]))
    except ValueError: continue
    ai = inp['actual_input']
    if (ai.get('prompt') or {}).get('key') != 'librarian' or out.get('generation_path') != 'full_lane': continue
    if not isinstance(out.get('exact_output'), dict): continue
    try: reorder(ai['prompt']['effective_template'])
    except AssertionError: continue
    cands.append((ai['rendered_prompt_variables'].get('keeper_id'), os.path.getmtime(ins[0]), os.path.basename(d), ai, out))
by = collections.defaultdict(list)
for c in sorted(cands, key=lambda c: c[1]): by[c[0]].append(c)
sample = []
for k in sorted(by):
    rs = by[k]; step = max(1, len(rs) // 3); sample += rs[::step][:3]
sample = sample[:int(sys.argv[1]) if len(sys.argv) > 1 else 30]
key = os.environ['OLLAMA_CLOUD_API_KEY']
def render(tmpl, v): return re.sub(r'\{\{(\w+)\}\}', lambda m: v[m.group(1)], tmpl)
def call(prompt):
    body = json.dumps({'model': 'deepseek-v4.1-flash', 'messages': [{'role': 'user', 'content': prompt}],
                       'response_format': {'type': 'json_object'}, 'reasoning_effort': 'low', 'stream': False}).encode()
    req = urllib.request.Request('https://ollama.com/v1/chat/completions', data=body,
                                 headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    t = time.time()
    with urllib.request.urlopen(req, timeout=600) as r: resp = json.load(r)
    return resp['choices'][0]['message']['content'], resp.get('usage'), time.time() - t
results = []
for keeper, _, run, ai, out in sample:
    v = ai['rendered_prompt_variables']; tmpl = ai['prompt']['effective_template']
    row = {'run': run, 'keeper': keeper, 'recorded': out.get('exact_output'),
           'memory_ids': re.findall(r'"memory_id":"(m\d+)"', v['current_memory'])}
    for arm, t in (('recorded_order', tmpl), ('stable_first', reorder(tmpl))):
        prompt = render(t, v); row[arm + '_bytes'] = len(prompt.encode())
        for attempt in range(3):
            try:
                text, usage, el = call(prompt)
                row[arm] = json.loads(text); row[arm + '_usage'] = usage; row[arm + '_s'] = round(el, 1); break
            except Exception as e:
                row[arm] = {'error': repr(e)[:300]}; time.sleep(10 * (attempt + 1))
    results.append(row)
    json.dump(results, open(os.path.join(OUT, 'results.json'), 'w'), ensure_ascii=False)
    print(len(results), keeper, row.get('recorded_order_s'), row.get('stable_first_s'), flush=True)
print('done', len(results))
