import json, glob, os, re, random, time, collections, importlib.util
spec = importlib.util.spec_from_file_location("probe", "jev_fanout_probe.py"); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
now = time.time(); ev = collections.defaultdict(list)
for path in glob.glob(os.path.join(p.BASE, "*.jsonl")):
    k = os.path.basename(path)[:-6]
    if k in p.EXCLUDED: continue
    last = {}
    for line in open(path):
        r = json.loads(line); last[r["candidate_id"]] = r
    for r in last.values():
        s = r["signal"]
        if s["kind"] != "comment_added" or now - r["recorded_at"] > 12*3600 or r["status"]["kind"] != "consumed": continue
        ev[(s["post_id"], s["comment_id"])].append((k, r))
# 10 events with >= 20 keepers, at most one comment per post, skipping the 3 already probed
probed = {"c-ca0599943d0447ef121e9bcd86209c43","c-56721eb03004ad63389c4d5739130eb3","c-4ab10bf4a79a84804c084bbee8f848ba"}
random.seed(20261001)
cands = [(key, lst) for key, lst in ev.items() if len(lst) >= 20 and key[1] not in probed]
random.shuffle(cands)
chosen, posts = [], set()
for key, lst in cands:
    if key[0] in posts: continue
    chosen.append((key, sorted(lst))); posts.add(key[0])
    if len(chosen) == 10: break
pairs, cases = [], []
for (post_id, comment_id), rows in chosen:
    signal = rows[0][1]["signal"]
    qs = {f"keeper_{i:02d}": {"type": "choice", "instructions": (
        f"Does the Board signal in state.signal itself require concrete attention, review, or action from keeper {json.dumps(k)} "
        f"for one of its board interests {json.dumps(r['keeper_context']['board_interests'], ensure_ascii=False)}? General topic or capability overlap is not sufficient. "
        "Choose uncertain when you cannot establish either decision from the supplied signal."),
        "criteria": p.criteria(p.RELEVANT.replace("keeper_role.board_interests", "its board interests"), p.NOT_RELEVANT)} for i, (k, r) in enumerate(rows)}
    st, pay, el, sent = p.post({"model": p.MODEL, "state": {"signal": signal}, "questions": qs})
    print(f"event {comment_id} keepers={len(rows)} http={st} {el:.2f}s usage={pay.get('usage')}")
    ans = pay.get("answers") or {}
    for i, (k, r) in enumerate(rows):
        jd = r["status"].get("judgment") or {}
        prod = (jd.get("verdict") or {}).get("decision"); src = (jd.get("source") or {}).get("kind")
        m = re.search(r"confidence=([\d.]+)", (jd.get("verdict") or {}).get("rationale", ""))
        fa = ans.get(f"keeper_{i:02d}", {})
        pair = {"case": f"{comment_id}:{k}", "keeper": k, "prod": prod, "prod_source": src,
                "prod_conf": float(m.group(1)) if m else None, "fan": fa.get("choice"), "fan_conf": fa.get("confidence")}
        pairs.append(pair)
        if pair["fan"] != prod:
            cases.append({"case": pair["case"], "keeper": k, "board_interests": r["keeper_context"]["board_interests"],
                          "signal": {"title": signal.get("title"), "author": signal.get("author"), "content": signal.get("content")}})
random.shuffle(cases)
json.dump(pairs, open("eval_pairs.json", "w"), ensure_ascii=False, indent=1)
json.dump(cases, open("eval_blind_cases.json", "w"), ensure_ascii=False, indent=1)
dis = [x for x in pairs if x["fan"] != x["prod"]]
print("pairs", len(pairs), "disagreements", len(dis), collections.Counter((x["prod"], x["fan"]) for x in dis))
