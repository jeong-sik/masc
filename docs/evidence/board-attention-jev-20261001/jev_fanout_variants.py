import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("probe", "jev_fanout_probe.py"); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
post_id, comment_id = sys.argv[1].split(":")
rows = p.load_event(post_id, comment_id); signal = rows[0][1]["signal"]
def fan_phrase(keeper, interests):
    return {"type": "choice", "instructions": (
        f"Does the Board signal in state.signal itself require concrete attention, review, or action from keeper {json.dumps(keeper)} "
        f"for one of its board interests {json.dumps(interests, ensure_ascii=False)}? General topic or capability overlap is not sufficient. "
        "Choose uncertain when you cannot establish either decision from the supplied signal."),
        "criteria": p.criteria(p.RELEVANT.replace("keeper_role.board_interests", "its board interests"), p.NOT_RELEVANT)}
# Variant C: fan-out phrasing, one question per request
c = {}
for keeper, row in rows:
    st, pay, el, _ = p.post({"model": p.MODEL, "state": {"signal": signal}, "questions": {"q": fan_phrase(keeper, row["keeper_context"]["board_interests"])}})
    c[keeper] = (pay.get("answers") or {}).get("q", {})
# Variant B: many questions, single-shaped state and wording per keeper
state = {"items": [{"candidate_id": "event", "signal": signal}],
         "keepers": {f"keeper_{i:02d}": {"name": k, "board_interests": r["keeper_context"]["board_interests"]} for i, (k, r) in enumerate(rows)}}
qs = {}
for i, (k, r) in enumerate(rows):
    qid = f"keeper_{i:02d}"
    qs[qid] = {"type": "choice", "instructions": (
        f"Does the current Board signal in items[0] itself require concrete attention, review, or action from keeper {json.dumps(k)} "
        f"for one of keepers.{qid}.board_interests? General topic or capability overlap is not sufficient. "
        "Choose uncertain when you cannot establish either decision from the supplied signal."),
        "criteria": p.criteria(p.RELEVANT.replace("keeper_role.board_interests", f"keepers.{qid}.board_interests"), p.NOT_RELEVANT)}
st, pay, el, sent = p.post({"model": p.MODEL, "state": state, "questions": qs})
print(f"variant B http={st} {el:.2f}s bytes={sent} usage={pay.get('usage')}")
b = pay.get("answers") or {}
prev = {}
for line in open("jev_fanout_probe.out"):
    parts = line.split()
    if len(parts) >= 4 and parts[1].startswith("fan=") and parts[0] in dict(rows) and parts[0] not in prev:
        prev[parts[0]] = (parts[1][4:], parts[2][7:])
agree_c = agree_b = 0
for i, (k, r) in enumerate(rows):
    fan, single = prev[k]
    cc = f"{c[k].get('choice')}:{str(c[k].get('confidence'))[:4]}"; bb = f"{b.get(f'keeper_{i:02d}',{}).get('choice')}:{str(b.get(f'keeper_{i:02d}',{}).get('confidence'))[:4]}"
    sd = single.split(":")[0]; agree_c += cc.split(":")[0] == sd; agree_b += bb.split(":")[0] == sd
    print(f"  {k:22s} single={single:20s} fan={fan:20s} C(one q, fan wording)={cc:20s} B(many q, single wording)={bb}")
print(f"agreement with single: C {agree_c}/{len(rows)}  B {agree_b}/{len(rows)}")
