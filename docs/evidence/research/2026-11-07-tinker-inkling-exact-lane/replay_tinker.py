#!/usr/bin/env python3
"""Replay the 2026-09 MASC exact-lane datasets through Tinker's OpenAI-compatible
endpoint (PoC, 2026-11-07).

Read-only inputs: datasets/*.jsonl and the scorers in replay_exact.py under
~/me/.masc/benchmarks/local-llm-2026-09. The request mirrors MASC's openai_chat
structured-output path (backend_openai_request.ml: response_format json_schema,
strict true). Pass lines are fixed in PASS before any request is sent.
The API key comes from TINKER_API_KEY and is never written.
Output: <out>/preflight.json, <out>/rows.jsonl (append; resumable by
effort/lane/id) and <out>/summary.json.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import importlib.util
import json
import os
import time
from pathlib import Path

from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

BENCH = Path.home() / "me/.masc/benchmarks/local-llm-2026-09"
BASE = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
MODEL = "thinkingmachines/Inkling-2-Small"
WINDOW_TOKENS = 65_536  # measured: probe-20261107T064924Z item 6 (prompt + max_tokens)
WINDOW_MARGIN = 64
# USD per 1M tokens, Tinker pricing page "as of October 19, 2026" (read 2026-11-07).
PRICE = {"input": 0.30, "cached_input": 0.03, "output": 1.00}
# Reasoning is billed inside completion_tokens (probe item 1), so reasoning efforts get
# room on top of the lane's answer budget (LANE_MAX_TOKENS in replay_exact.py).
REASONING_HEADROOM = {"none": 0, "low": 4096, "medium": 12288}
BURST = 8  # largest observed board arrival group (LIVE-WIRING-ROLLBACK.md)
GROUP = {"board": BURST, "librarian": 4}
BURST_MIN_GROUP = 5  # the cloud baseline below is the p50 of 5-request bursts
PASS = {
    "librarian_valid_all": True,  # every record valid: each current id disposed exactly once
    "board_agree_min": 0.9,  # agreement with the recorded cloud decision; errors count as misses
    "board_burst_p50_max_s": 42.0,  # cloud glm-5.3-flash burst p50 (LIVE-WIRING-ROLLBACK.md)
}


def load_bench():
    spec = importlib.util.spec_from_file_location("replay_exact", BENCH / "replay_exact.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def response_format(schema: dict, kind: str) -> dict | None:
    if kind == "json_schema":
        return {"type": "json_schema", "json_schema": {"name": "exact_output", "schema": schema, "strict": True}}
    if kind == "json_object":
        return {"type": "json_object"}
    return None


def call(client: OpenAI, messages: list, *, effort: str, max_tokens: int, schema: dict, kind: str) -> dict:
    extra: dict = {"max_tokens": max_tokens, "temperature": 0.0, "reasoning_effort": effort}
    rf = response_format(schema, kind)
    if rf is not None:
        extra["response_format"] = rf
    t0 = time.time()
    try:
        r = client.chat.completions.with_raw_response.create(model=MODEL, messages=messages, extra_body=extra)
        status, text = r.http_response.status_code, r.http_response.text
    except APIStatusError as e:
        status, text = e.status_code, e.response.text[:1500]
    except (APIConnectionError, APITimeoutError) as e:
        status, text = 0, f"{type(e).__name__}: {e}"
    row: dict = {"status": status, "wall_s": round(time.time() - t0, 2), "format": kind, "max_tokens": max_tokens}
    if status != 200:
        row["error"] = text[:600]
        return row
    d = json.loads(text)
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    u = d.get("usage") or {}
    pt, ct = u.get("prompt_tokens") or 0, u.get("completion_tokens") or 0
    cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
    cost = ((pt - cached) * PRICE["input"] + cached * PRICE["cached_input"] + ct * PRICE["output"]) / 1e6
    row.update(finish_reason=ch.get("finish_reason"), prompt_tokens=pt, cached_tokens=cached,
               completion_tokens=ct, reasoning_chars=len(msg.get("reasoning_content") or ""),
               content=msg.get("content") or "", cost_usd=round(cost, 6))
    return row


def call_mirroring_masc(client: OpenAI, messages: list, **kw) -> dict:
    """MASC sends json_schema only. A 400 there is recorded, then json_object is tried once
    so the run shows whether a different dialect would have answered."""
    row = call(client, messages, kind="json_schema", **kw)
    if row["status"] == 400:
        retry = call(client, messages, kind="json_object", **kw)
        retry["json_schema_error"] = row["error"]
        return retry
    return row


def preflight(client: OpenAI, out: Path) -> dict:
    """Does json_schema strict constrain decoding, or is it accepted and ignored?"""
    schema = {"type": "object", "properties": {"answer": {"type": "string", "enum": ["yes", "no"]}},
              "required": ["answer"], "additionalProperties": False}
    msgs = [{"role": "user", "content": "Write two friendly sentences about the sea. Do not answer in JSON."}]
    res = {}
    for kind in ("json_schema", "json_object", "none"):
        r = call(client, msgs, effort="none", max_tokens=256, schema=schema, kind=kind)
        content = r.pop("content", "")
        try:
            obj = json.loads(content)
        except json.JSONDecodeError:
            obj = None
        r["content_head"] = content[:200]
        r["matches_schema"] = isinstance(obj, dict) and set(obj) == {"answer"} and obj["answer"] in ("yes", "no")
        res[kind] = r
    (out / "preflight.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    return res


def pct(xs: list, q: float):
    xs = sorted(x for x in xs if x is not None)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def summarize(rows: list, recs: dict) -> dict:
    gt_wall = {(lane, r["id"]): r.get("gt_elapsed_s") for lane, rs in recs.items() for r in rs}
    out: dict = {}
    for effort, lane in sorted({(r["effort"], r["lane"]) for r in rows}):
        rs = [r for r in rows if r["effort"] == effort and r["lane"] == lane]
        ok = [r for r in rs if r["status"] == 200]
        sc = [r["score"] for r in ok]
        n = len(recs[lane])
        valid = sum(1 for x in sc if x.get("valid"))
        s = {"n_dataset": n, "n_rows": len(rs), "http_errors": len(rs) - len(ok),
             "formats": collections.Counter(r["format"] for r in rs),
             "json_schema_rejected": sum(1 for r in rs if r.get("json_schema_error")),
             "finish": collections.Counter(str(r.get("finish_reason")) for r in ok),
             "json_forms": collections.Counter(r.get("json_form") for r in ok), "valid": valid,
             "errors": collections.Counter(e.split(":")[0] for x in sc for e in x.get("errors", [])),
             "wall_p50": pct([r["wall_s"] for r in ok], 0.5), "wall_p90": pct([r["wall_s"] for r in ok], 0.9),
             "wall_max": max((r["wall_s"] for r in ok), default=None),
             "cloud_wall_p50": pct([gt_wall.get((lane, r["id"])) for r in rs], 0.5),
             "prompt_tokens_p50": pct([r["prompt_tokens"] for r in ok], 0.5),
             "completion_tokens_p50": pct([r["completion_tokens"] for r in ok], 0.5),
             "reasoning_chars_p50": pct([r["reasoning_chars"] for r in ok], 0.5),
             "cost_usd": round(sum(r.get("cost_usd", 0) for r in ok), 4)}
        if lane == "librarian":
            v = [x for x in sc if x.get("valid")]
            s.update(retained_jaccard_mean=round(sum(x["retained_jaccard"] for x in v) / len(v), 3) if v else None,
                     dropped_exact=sum(1 for x in v if x["dropped_exact"]),
                     action_agree=sum(1 for x in v if x["action_agree"]),
                     pass_valid_all=len(rs) == n and valid == n)
        if lane == "board":
            agree = sum(1 for x in sc if x.get("valid") and x.get("agree"))
            per: dict = collections.defaultdict(lambda: [0, 0])
            for x in sc:
                per[x.get("gt_decision")][1] += 1
                per[x.get("gt_decision")][0] += int(bool(x.get("valid") and x.get("agree")))
            burst = pct([r["wall_s"] for r in ok if r["group_size"] >= BURST_MIN_GROUP], 0.5)
            s.update(agree=agree, agree_rate=round(agree / n, 3), per_class_recall={k: f"{a}/{b}" for k, (a, b) in per.items()},
                     burst_p50=burst, burst_group_wall_max=max((r["group_wall_s"] for r in rs), default=None),
                     pass_agree=len(rs) == n and agree / n >= PASS["board_agree_min"],
                     pass_burst=burst is not None and burst <= PASS["board_burst_p50_max_s"])
        out[f"{effort}/{lane}"] = s
    out["spent_usd"] = round(sum(r.get("cost_usd", 0) for r in rows), 4)
    out["pass_lines"] = PASS
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--efforts", default="none,low,medium")
    ap.add_argument("--lanes", default="librarian,board")
    ap.add_argument("--budget", type=float, default=2.0, help="stop before a new group once spent USD reaches this")
    ap.add_argument("--preflight-only", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    bench = load_bench()
    client = OpenAI(base_url=BASE, api_key=os.environ["TINKER_API_KEY"], max_retries=0, timeout=900.0)
    pf = preflight(client, out)
    print("PREFLIGHT", json.dumps({k: [v["status"], v.get("matches_schema")] for k, v in pf.items()}))
    if a.preflight_only:
        return
    lanes = a.lanes.split(",")
    recs = {lane: [json.loads(line) for line in open(BENCH / "datasets" / f"{lane}.jsonl")] for lane in lanes}
    rows_path = out / "rows.jsonl"
    rows = [json.loads(line) for line in open(rows_path)] if rows_path.exists() else []
    done = {(r["effort"], r["lane"], r["id"]) for r in rows}
    measured_prompt = {(r["lane"], r["id"]): r["prompt_tokens"] for r in rows if r.get("prompt_tokens")}
    with open(rows_path, "a", encoding="utf-8") as f:
        for effort in a.efforts.split(","):
            for lane in lanes:
                todo = [r for r in recs[lane] if (effort, lane, r["id"]) not in done]
                size = GROUP[lane]
                for gi in range(0, len(todo), size):
                    spent = sum(r.get("cost_usd", 0) for r in rows)
                    if spent >= a.budget:
                        print(f"BUDGET_STOP spent={spent:.4f}")
                        print("SUMMARY", json.dumps(summarize(rows, recs), ensure_ascii=False))
                        return
                    group = todo[gi:gi + size]

                    def one(rec: dict) -> dict:
                        want = bench.LANE_MAX_TOKENS[lane] + REASONING_HEADROOM[effort]
                        known = measured_prompt.get((lane, rec["id"]))
                        cap = WINDOW_TOKENS - known - WINDOW_MARGIN if known else want
                        return call_mirroring_masc(client, rec["messages"], effort=effort,
                                                   max_tokens=min(want, cap), schema=rec["schema"])

                    t0 = time.time()
                    with cf.ThreadPoolExecutor(max_workers=len(group)) as ex:
                        results = list(ex.map(one, group))
                    gwall = round(time.time() - t0, 2)
                    for rec, r in zip(group, results):
                        row = {"effort": effort, "lane": lane, "id": rec["id"], "ts": time.time(),
                               "group_index": gi // size, "group_size": len(group), "group_wall_s": gwall, **r}
                        if r["status"] == 200:
                            content = row.pop("content")
                            obj, form = bench.parse_json(content)
                            row["json_form"] = form
                            row["score"] = bench.SCORERS[lane](obj, rec)
                            row["content_head"] = content[:400]
                            measured_prompt[(lane, rec["id"])] = r["prompt_tokens"]
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                        f.flush()
                        rows.append(row)
                        sc = row.get("score", {})
                        print(json.dumps({"e": effort, "lane": lane, "id": rec["id"][-8:], "st": r["status"],
                                          "wall": r["wall_s"], "fmt": r["format"], "fin": r.get("finish_reason"),
                                          "valid": sc.get("valid"), "agree": sc.get("agree", sc.get("action_agree")),
                                          "err": (r.get("error") or "")[:80] or sc.get("errors")}, ensure_ascii=False))
    summary = summarize(rows, recs)
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print("SUMMARY", json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
