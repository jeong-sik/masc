#!/usr/bin/env python3
"""Replay the 2026-09 exact-lane datasets through Tinker the way MASC exact lanes
send them to a row that declares neither JSON mode nor native schema (PoC,
2026-11-07).

MASC exact lanes request Json_syntax. For such a row the plan is Types.Off:
no response_format, and the schema instruction appended as the last user
message (exact_output_ready_admission.ml, domain_schema_instruction_text and
messages_for_response_format). This script sends exactly that. Everything else
-- datasets, scorers, max_tokens, temperature, pass lines -- is reused from the
Stage 1 replay_tinker.py, imported by path, so the only changed variable is the
message shape. --no-temperature and --max-tokens change two more, to what a MASC
exact request carries: exact_config sends no temperature, and max_tokens is the
binding's max-tokens.

Pass lines are the Stage 1 PASS dict, fixed before any request is sent.
The API key comes from TINKER_API_KEY and is never written.
Output: <out>/rows.jsonl (append; resumable by effort/lane/id) and <out>/summary.json.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import importlib.util
import json
import os
import time
from pathlib import Path

from openai import OpenAI

STAGE1 = Path(__file__).with_name("replay_tinker.py")

# Verbatim from domain_schema_instruction_text (exact_output_ready_admission.ml).
INSTRUCTION = (
    "Return exactly one JSON value matching this JSON Schema. Do not use Markdown "
    "code fences or include any explanation. JSON Schema: %s"
)


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def instruction_message(schema: dict) -> dict:
    # Yojson.Safe.sort then to_string: keys sorted at every level, compact, raw UTF-8.
    text = json.dumps(schema, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {"role": "user", "content": INSTRUCTION % text}


def call_without_temperature(s1, client: OpenAI, messages: list, *, effort: str, max_tokens: int) -> dict:
    """s1.call minus temperature: exact_config sets temperature = None, so a MASC
    exact request carries no temperature field and the provider default applies."""
    extra: dict = {"max_tokens": max_tokens, "reasoning_effort": effort}
    t0 = time.time()
    try:
        r = client.chat.completions.with_raw_response.create(model=s1.MODEL, messages=messages, extra_body=extra)
        status, text = r.http_response.status_code, r.http_response.text
    except s1.APIStatusError as e:
        status, text = e.status_code, e.response.text[:1500]
    except (s1.APIConnectionError, s1.APITimeoutError) as e:
        status, text = 0, f"{type(e).__name__}: {e}"
    row: dict = {"status": status, "wall_s": round(time.time() - t0, 2), "format": "none",
                 "max_tokens": max_tokens, "temperature": None}
    if status != 200:
        row["error"] = text[:600]
        return row
    d = json.loads(text)
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    u = d.get("usage") or {}
    pt, ct = u.get("prompt_tokens") or 0, u.get("completion_tokens") or 0
    cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
    price = s1.PRICE
    cost = ((pt - cached) * price["input"] + cached * price["cached_input"] + ct * price["output"]) / 1e6
    row.update(finish_reason=ch.get("finish_reason"), prompt_tokens=pt, cached_tokens=cached,
               completion_tokens=ct, reasoning_chars=len(msg.get("reasoning_content") or ""),
               content=msg.get("content") or "", cost_usd=round(cost, 6))
    return row


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--efforts", default="low")
    ap.add_argument("--lanes", default="librarian,board")
    ap.add_argument("--budget", type=float, default=0.5, help="stop before a new group once spent USD reaches this")
    ap.add_argument("--max-tokens", type=int, default=None,
                    help="fixed output budget, as a binding's max-tokens sends it; default is the Stage 1 budget")
    ap.add_argument("--no-temperature", action="store_true",
                    help="omit temperature, as a MASC exact request does (exact_config)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    s1 = load(STAGE1, "replay_tinker")
    bench = s1.load_bench()
    client = OpenAI(base_url=s1.BASE, api_key=os.environ["TINKER_API_KEY"], max_retries=0, timeout=900.0)
    lanes = a.lanes.split(",")
    recs = {lane: [json.loads(line) for line in open(s1.BENCH / "datasets" / f"{lane}.jsonl")] for lane in lanes}
    rows_path = out / "rows.jsonl"
    rows = [json.loads(line) for line in open(rows_path)] if rows_path.exists() else []
    done = {(r["effort"], r["lane"], r["id"]) for r in rows}
    with open(rows_path, "a", encoding="utf-8") as f:
        for effort in a.efforts.split(","):
            for lane in lanes:
                todo = [r for r in recs[lane] if (effort, lane, r["id"]) not in done]
                size = s1.GROUP[lane]
                for gi in range(0, len(todo), size):
                    spent = sum(r.get("cost_usd", 0) for r in rows)
                    if spent >= a.budget:
                        print(f"BUDGET_STOP spent={spent:.4f}")
                        summary = s1.summarize(rows, recs)
                        (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
                        return
                    group = todo[gi:gi + size]

                    def one(rec: dict) -> dict:
                        want = a.max_tokens or (bench.LANE_MAX_TOKENS[lane] + s1.REASONING_HEADROOM[effort])
                        msgs = rec["messages"] + [instruction_message(rec["schema"])]
                        if a.no_temperature:
                            return call_without_temperature(s1, client, msgs, effort=effort, max_tokens=want)
                        return s1.call(client, msgs, effort=effort, max_tokens=want, schema=rec["schema"], kind="none")

                    t0 = time.time()
                    with cf.ThreadPoolExecutor(max_workers=len(group)) as ex:
                        results = list(ex.map(one, group))
                    gwall = round(time.time() - t0, 2)
                    for rec, r in zip(group, results):
                        row = {"effort": effort, "lane": lane, "id": rec["id"], "ts": time.time(),
                               "group_index": gi // size, "group_size": len(group), "group_wall_s": gwall,
                               "shape": "masc_off_instruction", **r}
                        if r["status"] == 200:
                            content = row.pop("content")
                            obj, form = bench.parse_json(content)
                            row["json_form"] = form
                            row["score"] = bench.SCORERS[lane](obj, rec)
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                        f.flush()
                        rows.append(row)
                        sc = row.get("score", {})
                        print(json.dumps({"e": effort, "lane": lane, "id": rec["id"][-8:], "st": r["status"],
                                          "wall": r["wall_s"], "fin": r.get("finish_reason"),
                                          "valid": sc.get("valid"), "agree": sc.get("agree", sc.get("action_agree")),
                                          "err": (r.get("error") or "")[:80] or sc.get("errors")}, ensure_ascii=False))
    summary = s1.summarize(rows, recs)
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print("SUMMARY", json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
