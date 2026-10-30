"""A/B: working-context pass with and without current_memory, same model, sequential.

Usage: OLLAMA_CLOUD_API_KEY=... python3 -I ab.py [N]. Writes results.json (with private
Memory and source text) under $WC_AB_OUT, outside the repository."""
import json, os, glob, re, sys, tempfile, time, urllib.request, collections
OUT = os.environ.get('WC_AB_OUT', os.path.join(tempfile.gettempdir(), 'wc-ab'))
os.makedirs(OUT, exist_ok=True)
root = os.path.expanduser('~/me/.masc/exact-lane-run-payloads')
OMITTED = '(이 정리 요청에는 현재 기억을 싣지 않았습니다.)'
cands = []
for d in glob.glob(os.path.join(root, 'librarian-exact-*')):
    ins, outs = glob.glob(d + '/input-*.json'), glob.glob(d + '/output-*.json')
    if len(ins) != 1 or len(outs) != 1: continue
    try: inp = json.load(open(ins[0])); out = json.load(open(outs[0]))
    except ValueError: continue
    ai = inp['actual_input']
    if (ai.get('prompt') or {}).get('key') != 'librarian.working_context': continue
    if (out.get('context_write') or {}).get('status') != 'committed': continue
    v = ai['rendered_prompt_variables']
    nsrc = len(json.loads(v['working_context']).get('sources', []))
    if nsrc < 2: continue
    cands.append((v['keeper_id'], os.path.getmtime(ins[0]), os.path.basename(d), ai, out))
by = collections.defaultdict(list)
for c in sorted(cands, key=lambda c: c[1]): by[c[0]].append(c)
sample = []
for k in sorted(by):  # spread over keepers: up to 3 each, evenly spaced in time
    rs = by[k]; step = max(1, len(rs) // 3)
    sample += rs[::step][:3]
sample = sample[:int(sys.argv[1]) if len(sys.argv) > 1 else 30]
key = os.environ['OLLAMA_CLOUD_API_KEY']
def render(tmpl, variables):
    return re.sub(r'\{\{(\w+)\}\}', lambda m: variables[m.group(1)], tmpl)
def call(prompt):
    body = json.dumps({'model': 'deepseek-v4.1-flash', 'messages': [{'role': 'user', 'content': prompt}],
                       'response_format': {'type': 'json_object'}, 'reasoning_effort': 'low', 'stream': False}).encode()
    req = urllib.request.Request('https://ollama.com/v1/chat/completions', data=body,
                                 headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    t = time.time()
    with urllib.request.urlopen(req, timeout=300) as r: resp = json.load(r)
    return resp['choices'][0]['message']['content'], resp.get('usage'), time.time() - t
results = []
for keeper, _, run, ai, out in sample:
    v = dict(ai['rendered_prompt_variables']); tmpl = ai['prompt']['effective_template']
    row = {'run': run, 'keeper': keeper, 'recorded': out.get('exact_output'), 'memory_bytes': len(v['current_memory'].encode()),
           'sources': json.loads(v['working_context']).get('sources', []), 'keeper_instructions': v.get('keeper_instructions', ''), 'memory': v['current_memory']}
    for arm, variables in (('with_memory', v), ('without_memory', {**v, 'current_memory': OMITTED})):
        prompt = render(tmpl, variables); row[arm + '_prompt_bytes'] = len(prompt.encode())
        for attempt in range(3):
            try:
                text, usage, el = call(prompt)
                row[arm] = json.loads(text); row[arm + '_usage'] = usage; row[arm + '_s'] = round(el, 1); break
            except Exception as e:
                row[arm] = {'error': repr(e)[:300]}; time.sleep(10 * (attempt + 1))
    results.append(row)
    json.dump(results, open(os.path.join(OUT, 'results.json'), 'w'), ensure_ascii=False)
    print(len(results), keeper, row.get('with_memory_s'), row.get('without_memory_s'), flush=True)
print('done', len(results))
