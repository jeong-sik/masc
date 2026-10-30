"""Repeated identical inputs whose outputs never repeat, from tool_calls ledgers.
usage: python3 -I evasion.py <ledger.jsonl>..."""
import collections, json, sys

groups = collections.defaultdict(list)
rows_total = rows_fp = 0
for path in sys.argv[1:]:
    with open(path, errors="replace") as handle:
        for line in handle:
            rows_total += 1
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("record_kind") != "tool_call" or not r.get("output_fingerprint") or not r.get("input_fingerprint"):
                continue
            rows_fp += 1
            key = (r.get("keeper"), r.get("keeper_turn_id"), r.get("trace_id"), r.get("tool"), r["input_fingerprint"])
            groups[key].append((r["output_fingerprint"], r.get("output")))

def changed_keys(a, b):
    try:
        x, y = json.loads(a), json.loads(b)
    except (TypeError, json.JSONDecodeError):
        return ["<non-json>"]
    if not (isinstance(x, dict) and isinstance(y, dict)):
        return ["<non-object>"]
    return sorted(k for k in set(x) | set(y) if x.get(k) != y.get(k))

by_tool = collections.defaultdict(lambda: {"groups": 0, "calls": 0, "keepers": set(), "keys": collections.Counter(), "max": 0})
caught = collections.Counter()
for (keeper, turn, trace, tool, _), calls in groups.items():
    if len(calls) < 3:
        continue
    outs = [c[0] for c in calls]
    if max(collections.Counter(outs).values()) >= 3:
        caught[tool] += 1
        continue
    if len(set(outs)) == len(outs):
        e = by_tool[tool]
        e["groups"] += 1; e["calls"] += len(calls); e["keepers"].add(keeper); e["max"] = max(e["max"], len(calls))
        for k in changed_keys(calls[0][1], calls[1][1]):
            e["keys"][k] += 1
print(json.dumps({"rows": rows_total, "rows_with_fingerprints": rows_fp,
    "groups_caught_by_exact_axis": dict(caught.most_common(10)),
    "groups_every_output_different": {t: {"groups": e["groups"], "calls": e["calls"], "max_in_one_turn": e["max"],
        "keepers": len(e["keepers"]), "changed_keys": e["keys"].most_common(6)}
        for t, e in sorted(by_tool.items(), key=lambda kv: -kv[1]["calls"])}}, ensure_ascii=False, indent=1))
