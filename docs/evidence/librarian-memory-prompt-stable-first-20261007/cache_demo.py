import json, os, glob, re, hashlib, uuid, urllib.request, collections
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ab_order.py')).read().split("cands = []")[0])
groups = collections.defaultdict(list)
for d in glob.glob(os.path.join(root, 'librarian-exact-*')):
    ins = glob.glob(d + '/input-*.json')
    if len(ins) != 1: continue
    try: ai = json.load(open(ins[0]))['actual_input']
    except ValueError: continue
    if (ai.get('prompt') or {}).get('key') != 'librarian': continue
    v = ai['rendered_prompt_variables']
    if len(v.get('current_memory', '')) < 60000: continue
    groups[(v['keeper_id'], hashlib.sha256(v['current_memory'].encode()).hexdigest())].append(ai)
pair = next(((k, g[:2]) for k, g in groups.items() if len(g) >= 2 and g[0]['rendered_prompt_variables']['conversation_history'] != g[1]['rendered_prompt_variables']['conversation_history']), None)
assert pair, 'no pair with the same Memory and different conversation'
(keeper, _), (p1, p2) = pair
key = os.environ['OLLAMA_CLOUD_API_KEY']
def call(prompt):
    body = json.dumps({'model': 'deepseek-v4.1-flash', 'messages': [{'role': 'user', 'content': prompt}],
                       'max_tokens': 16, 'reasoning_effort': 'low', 'stream': False}).encode()
    req = urllib.request.Request('https://ollama.com/v1/chat/completions', data=body,
                                 headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=600) as r: u = json.load(r)['usage']
    return u['prompt_tokens'], (u.get('prompt_tokens_details') or {}).get('cached_tokens', 0)
def rend(ai, t): return re.sub(r'\{\{(\w+)\}\}', lambda m: ai['rendered_prompt_variables'][m.group(1)], t)
print('keeper', keeper, 'memory bytes', len(p1['rendered_prompt_variables']['current_memory'].encode()))
for arm, f in (('recorded order', lambda t: t), ('stable first', reorder)):
    nonce = f'run {uuid.uuid4()}\n'
    first = call(nonce + rend(p1, f(p1['prompt']['effective_template'])))
    second = call(nonce + rend(p2, f(p2['prompt']['effective_template'])))
    print(f'{arm}: first pass {first}, second pass (prompt_tokens, cached_tokens) {second}', flush=True)
