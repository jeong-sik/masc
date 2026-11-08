#!/usr/bin/env python3
"""Replay retained keeper-librarian exact requests through Tinker Inkling-2-Small
in the request shape a MASC exact lane sends this catalog row (PoC, 2026-11-07).

Input, read only: ~/me/.masc/lane-addons/exact-requests/<scope>/<digest>.json.
A record is used when declaration_id is "keeper-librarian" and its final status
is "answered" with an object output. That output is the reference: what the
live slot answered and the exact lane accepted. It is not ground truth.

Request shape, for a row that declares neither JSON mode nor native schema:
- the retained messages as given, then the schema instruction as the last user
  message (domain_schema_instruction_text, exact_output_ready_admission.ml:241);
- no response_format and no temperature (exact_config, same file, line 277);
- reasoning_effort "low" and max_tokens 8192, the live binding
  [tinker.tinker-inkling-2-small].

PASS is fixed before any request is sent:
- A reply is valid when it is HTTP 200 with finish_reason "stop", the whole
  content is one JSON value, it validates against the request's own schema and,
  for admission, it answers every candidate of the prompt's
  "Candidate data (JSON)" block exactly once.
- admission: valid / window-accepted >= 0.95. durable: every window-accepted
  reply is valid.
- An HTTP 400 for the context window is counted apart. MASC's pre-dispatch
  window check refuses those requests before they reach this slot.
Reported but not gated: memory-id rules taken from the schema descriptions,
outcome agreement with the reference, latency, tokens, cost.

--calibrate scores the reference answers with the same scorer and sends nothing.
--dry-run counts the dataset and sends nothing.
The API key comes from TINKER_API_KEY and is never written. Rows hold no prompt
or answer text.
Output: <out>/rows.jsonl (append, resumable by key) and <out>/summary.json.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import time
from pathlib import Path

from jsonschema import Draft202012Validator
from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

BASE = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
MODEL = "thinkingmachines/Inkling-2-Small"
# USD per million tokens, https://thinkingmachines.ai/tinker/pricing/ "as of October 19, 2026".
PRICE = {"input": 0.30, "cached_input": 0.03, "output": 1.00}
STORE = Path.home() / "me/.masc/lane-addons/exact-requests"
DECLARATION = "keeper-librarian"
MAX_TOKENS = 8192
EFFORT = "low"
GROUP = 4
PASS = {"admission_valid_rate_min": 0.95, "durable_valid_all": True}
# Verbatim from domain_schema_instruction_text.
INSTRUCTION = (
    "Return exactly one JSON value matching this JSON Schema. Do not use Markdown "
    "code fences or include any explanation. JSON Schema: %s"
)
WINDOW_DETAIL = re.compile(r"(\d+) prompt tokens \+ (\d+) max_tokens > (\d+)")
CANDIDATES_MARK = "Candidate data (JSON):\n"
MEMORY_MARK = "### 정확한 현재 기억\n"
# "A lowercase snake_case category ... Start with a letter, use letters/digits and
# single underscores between nonempty words." (schema description)
CATEGORY = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*\Z")
FENCE = re.compile(r"^```(?:json)?\s*\n(.*)\n```$", re.S)


def load_records() -> list[dict]:
    records = []
    for scope in sorted(STORE.iterdir()):
        for path in sorted(scope.glob("*.json")):
            rec = json.loads(path.read_text(encoding="utf-8"))
            final = rec.get("final") or {}
            if rec.get("declaration_id") != DECLARATION or final.get("status") != "answered":
                continue
            if not isinstance(final.get("output"), dict):
                continue
            request = rec["request"]
            # Every retained request so far is one user message without a system
            # field. Stop instead of guessing how another shape reaches the wire.
            assert "system" not in request and [m["role"] for m in request["messages"]] == ["user"], path
            usage = final.get("usage") or {}
            records.append({
                "key": rec["digest"][:16], "mtime": path.stat().st_mtime, "output": request["output"],
                "request": request, "reference": final["output"], "ref_slot": final.get("slot"),
                "ref_input_tokens": usage.get("input_tokens"), "ref_output_tokens": usage.get("output_tokens"),
            })
    records.sort(key=lambda r: r["mtime"], reverse=True)
    return records


def instruction_message(schema: dict) -> dict:
    # Yojson.Safe.sort then to_string: keys sorted at every level, compact, raw UTF-8.
    text = json.dumps(schema, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {"role": "user", "content": INSTRUCTION % text}


def wire_messages(request: dict) -> list[dict]:
    return [{"role": m["role"], "content": m["text"]} for m in request["messages"]] + [
        instruction_message(request["schema"])]


def json_block(text: str, mark: str):
    assert text.count(mark) == 1, mark
    value, _ = json.JSONDecoder().raw_decode(text, text.index(mark) + len(mark))
    return value


def parse_json(content: str):
    stripped = content.strip()
    try:
        return json.loads(stripped), "bare"
    except json.JSONDecodeError:
        pass
    match = FENCE.match(stripped)
    if match:
        try:
            return json.loads(match.group(1)), "fenced"
        except json.JSONDecodeError:
            pass
    return None, "unparseable"


def score(rec: dict, answer) -> dict:
    request = rec["request"]
    prompt = request["messages"][0]["text"]
    errors = sorted({e.validator for e in Draft202012Validator(request["schema"]).iter_errors(answer)})
    result: dict = {"schema_valid": not errors, "schema_errors": errors}
    if errors:
        return result
    memory = answer["memory"] if rec["output"] == "admission" else answer
    if rec["output"] == "admission":
        want = sorted(c["request_id"] for c in json_block(prompt, CANDIDATES_MARK))
        got = [c["request_id"] for c in answer["candidates"]]
        result["candidates_covered"] = sorted(got) == want and len(set(got)) == len(got)
        ref = {c["request_id"]: c["outcome"] for c in rec["reference"]["candidates"]}
        mine = {c["request_id"]: c["outcome"] for c in answer["candidates"]}
        result["outcome_agree"] = sum(1 for k, v in ref.items() if mine.get(k) == v)
        result["outcome_total"] = len(ref)
    known = {f["memory_id"] for f in json_block(prompt, MEMORY_MARK)["facts"]}
    dropped = [d["memory_id"] for d in memory["dropped"]]
    absorbs = [a for c in memory["new_claims"] for a in c["absorbs"]]
    supersedes = [c["supersedes"] for c in memory["new_claims"] if c["supersedes"] is not None]
    result["rules"] = {
        "ids_known": set(dropped) | set(absorbs) | set(supersedes) <= known,
        "absorbs_not_dropped": not (set(absorbs) & (set(dropped) | set(supersedes))),
        "absorbs_once": len(absorbs) == len(set(absorbs)),
        "supersedes_dropped": set(supersedes) <= set(dropped),
        "category_form": all(CATEGORY.match(c["category"]) for c in memory["new_claims"]),
    }
    ref_memory = rec["reference"]["memory"] if rec["output"] == "admission" else rec["reference"]
    result["counts"] = {"new_claims": len(memory["new_claims"]), "dropped": len(dropped),
                        "ref_new_claims": len(ref_memory["new_claims"]), "ref_dropped": len(ref_memory["dropped"])}
    return result


def is_valid(row: dict) -> bool:
    sc = row.get("score") or {}
    return (row.get("status") == 200 and row.get("finish_reason") == "stop" and row.get("json_form") == "bare"
            and sc.get("schema_valid") is True and sc.get("candidates_covered", True) is True)


def call(client: OpenAI, messages: list) -> dict:
    t0 = time.time()
    try:
        raw = client.chat.completions.with_raw_response.create(
            model=MODEL, messages=messages, extra_body={"max_tokens": MAX_TOKENS, "reasoning_effort": EFFORT})
        status, body = raw.http_response.status_code, raw.http_response.text
    except APIStatusError as e:
        status, body = e.status_code, e.response.text
    except (APIConnectionError, APITimeoutError) as e:
        status, body = 0, type(e).__name__
    row: dict = {"status": status, "wall_s": round(time.time() - t0, 2)}
    if status != 200:
        window = WINDOW_DETAIL.search(body)
        row["window_refused"] = status == 400 and window is not None
        if window:
            row["window_prompt_tokens"], row["window_max_tokens"], row["window_limit"] = map(int, window.groups())
        else:
            row["error_head"] = body[:200]
        return row
    data = json.loads(body)
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    usage = data.get("usage") or {}
    prompt_tokens, completion_tokens = usage.get("prompt_tokens") or 0, usage.get("completion_tokens") or 0
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
    cost = ((prompt_tokens - cached) * PRICE["input"] + cached * PRICE["cached_input"]
            + completion_tokens * PRICE["output"]) / 1e6
    row.update(window_refused=False, finish_reason=choice.get("finish_reason"), prompt_tokens=prompt_tokens,
               cached_tokens=cached, completion_tokens=completion_tokens,
               reasoning_chars=len(message.get("reasoning_content") or ""), cost_usd=round(cost, 6),
               content=message.get("content") or "")
    return row


def pct(values: list, q: float):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def summarize(rows: list) -> dict:
    summary: dict = {"pass_lines": PASS, "spent_usd": round(sum(r.get("cost_usd", 0) for r in rows), 4)}
    for output in ("admission", "durable"):
        sel = [r for r in rows if r["output"] == output]
        accepted = [r for r in sel if not r.get("window_refused")]
        valid = [r for r in accepted if is_valid(r)]
        ok = [r for r in accepted if r.get("status") == 200]
        scored = [r for r in ok if (r.get("score") or {}).get("schema_valid")]
        rules: dict = {}
        for r in scored:
            for k, v in r["score"]["rules"].items():
                rules.setdefault(k, [0, 0])
                rules[k][0] += bool(v)
                rules[k][1] += 1
        part = {
            "n": len(sel), "window_refused": len(sel) - len(accepted),
            "http_errors": sum(1 for r in accepted if r.get("status") != 200),
            "finish": {f: sum(1 for r in ok if r.get("finish_reason") == f) for f in sorted({r.get("finish_reason") for r in ok}, key=str)},
            "json_forms": {f: sum(1 for r in ok if r.get("json_form") == f) for f in sorted({r.get("json_form") for r in ok}, key=str)},
            "schema_valid": len(scored), "valid": len(valid),
            "valid_rate": round(len(valid) / len(accepted), 3) if accepted else None,
            "rules_pass": {k: f"{a}/{b}" for k, (a, b) in sorted(rules.items())},
            "wall_p50": pct([r["wall_s"] for r in ok], 0.5), "wall_p90": pct([r["wall_s"] for r in ok], 0.9),
            "prompt_tokens_p50": pct([r["prompt_tokens"] for r in ok], 0.5),
            "completion_tokens_p50": pct([r["completion_tokens"] for r in ok], 0.5),
            "completion_tokens_max": max((r["completion_tokens"] for r in ok), default=None),
            "cost_usd": round(sum(r.get("cost_usd", 0) for r in sel), 4),
        }
        if output == "admission":
            agree = sum(r["score"].get("outcome_agree", 0) for r in scored)
            total = sum(r["score"].get("outcome_total", 0) for r in scored)
            part["outcome_agree"] = f"{agree}/{total}"
            part["pass"] = part["valid_rate"] is not None and part["valid_rate"] >= PASS["admission_valid_rate_min"]
        else:
            part["pass"] = bool(accepted) and len(valid) == len(accepted)
        summary[output] = part
    return summary


def calibrate(records: list) -> None:
    rows = []
    for rec in records:
        rows.append({"output": rec["output"], "status": 200, "finish_reason": "stop", "json_form": "bare",
                     "wall_s": 0.0, "prompt_tokens": 0, "completion_tokens": 0, "score": score(rec, rec["reference"])})
    print(json.dumps(summarize(rows), ensure_ascii=False))
    for r in rows:
        bad = [k for k, v in (r["score"].get("rules") or {}).items() if not v]
        if not is_valid(r) or bad:
            print("reference fails:", r["output"], r["score"].get("schema_errors"), r["score"].get("candidates_covered"), bad)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--budget", type=float, default=1.0, help="stop before a new group once spent USD reaches this")
    ap.add_argument("--calibrate", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    records = load_records()
    if a.calibrate:
        calibrate(records)
        return
    if a.dry_run:
        for output in ("admission", "durable"):
            sel = [r for r in records if r["output"] == output]
            chars = sorted(sum(len(m["content"]) for m in wire_messages(r["request"])) for r in sel)
            print(output, "n", len(sel), "wire chars p50", pct(chars, 0.5), "max", chars[-1] if chars else None,
                  "ref input tokens > 57344:", sum(1 for r in sel if (r["ref_input_tokens"] or 0) > 65536 - MAX_TOKENS))
        return
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    client = OpenAI(base_url=BASE, api_key=os.environ["TINKER_API_KEY"], max_retries=0, timeout=900.0)
    rows_path = out / "rows.jsonl"
    rows = [json.loads(line) for line in open(rows_path, encoding="utf-8")] if rows_path.exists() else []
    done = {r["key"] for r in rows}
    todo = [r for r in records if r["key"] not in done]
    with open(rows_path, "a", encoding="utf-8") as f:
        for gi in range(0, len(todo), GROUP):
            spent = sum(r.get("cost_usd", 0) for r in rows)
            if spent >= a.budget:
                print(f"BUDGET_STOP spent={spent:.4f}")
                break
            group = todo[gi:gi + GROUP]
            t0 = time.time()
            with cf.ThreadPoolExecutor(max_workers=len(group)) as ex:
                results = list(ex.map(lambda rec: call(client, wire_messages(rec["request"])), group))
            group_wall = round(time.time() - t0, 2)
            for rec, res in zip(group, results):
                row = {"key": rec["key"], "output": rec["output"], "ref_slot": rec["ref_slot"],
                       "ref_input_tokens": rec["ref_input_tokens"], "ref_output_tokens": rec["ref_output_tokens"],
                       "ts": time.time(), "group_index": gi // GROUP, "group_wall_s": group_wall,
                       "effort": EFFORT, "max_tokens": MAX_TOKENS, **res}
                if res["status"] == 200:
                    answer, row["json_form"] = parse_json(row.pop("content"))
                    row["content_chars"] = len(res["content"])
                    row["score"] = score(rec, answer) if answer is not None else {"schema_valid": False, "schema_errors": ["unparseable"]}
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
                f.flush()
                rows.append(row)
                print(json.dumps({"o": row["output"][:3], "k": row["key"][:8], "st": row["status"], "wall": row["wall_s"],
                                  "win": row.get("window_refused"), "fin": row.get("finish_reason"),
                                  "valid": is_valid(row), "ct": row.get("completion_tokens")}))
    summary = summarize(rows)
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print("SUMMARY", json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
