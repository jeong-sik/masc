#!/usr/bin/env python3
"""KV-cache reuse harness for llama-server (llama.cpp) OpenAI-compat endpoint.

Measures per-turn timings.cache_n / prompt_n across four history policies:
  preserve      — stable system prompt, assistant reasoning_content replayed
  strip         — stable system prompt, reasoning_content dropped from history
  volatile      — per-turn timestamp line appended to system prompt
  volatile_tail — same timestamp carried in the new user message instead

Server used for the 2026-08-16 evidence run (RFC-0382):
  llama-server -m <gguf> --alias qwen3.8-27b -c 16384 -np 1 \
    --port 9010 --host 127.0.0.1 --jinja --reasoning-format deepseek

Output: one JSON line per turn on stdout and appended to --out.
Evidence SSOT: docs/evidence/kv-cache-harness-2026-08-16.jsonl
"""

import argparse
import json
import sys
import time
import urllib.request

SYSTEM_BASE = (
    "You are keeper 'harness', a long-running autonomous agent in a multi-agent "
    "coordination server. Be terse, evidence-driven, skeptical. "
    "You collaborate with sibling keepers on a shared board. Rules: "
    "(1) never repeat a point you already made in a previous turn; "
    "(2) reference your own earlier reasoning when extending it; "
    "(3) answers stay under 80 words. "
    "Project context: the team is auditing a distributed job scheduler written in OCaml. "
    "Components: dispatcher (lease-based claim), worker pool (Eio fibers), ledger "
    "(append-only JSONL), and a dashboard. Known symptoms: duplicate job execution "
    "after lease expiry, a starving low-priority lane, and a slow drain queue. "
    "Your job across turns: reason about root causes, propose one hypothesis per turn, "
    "and refine earlier hypotheses instead of restating them. "
) * 3  # ~600 tokens of stable system context

USER_TURNS = [
    "Turn 1: duplicate execution appears only when lease TTL < job runtime. First hypothesis?",
    "Turn 2: extend your hypothesis — does the ledger see both executions or one?",
    "Turn 3: the starving lane shares a mutex with the drain queue. Connect this to turn 1.",
    "Turn 4: propose the single smallest fix that addresses both symptoms.",
    "Turn 5: what measurement would falsify your turn-4 fix?",
    "Turn 6: summarize all hypotheses so far WITHOUT repeating full sentences.",
]


def erase_slots(base, slots=4):
    """Best-effort slot-cache erase between scenarios so a scenario's turn 1
    cannot silently reuse the previous scenario's residue (observed in the
    2026-08-16 evidence run: volatile turn 1 matched strip's leftover system
    prefix, cache_n=559). Requires the endpoint to be enabled server-side;
    a refusal downgrades to a warning because relative turn-2..4 comparisons
    do not depend on it."""
    for slot in range(slots):
        req = urllib.request.Request(
            f"{base}/slots/{slot}?action=erase", data=b"", method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=10):
                pass
        except Exception as exn:  # noqa: BLE001 - diagnostic path only
            print(f"warn: slot {slot} erase unavailable: {exn}", file=sys.stderr)
            return


def call(base, body, timeout):
    req = urllib.request.Request(
        base + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)
    resp["_wall_s"] = round(time.time() - t0, 2)
    return resp


def run_scenario(base, scenario, turns, max_tokens, model, timeout, out):
    history = []
    rows = []
    for i in range(turns):
        if scenario == "volatile":
            system = SYSTEM_BASE + f"\nCurrent time: 2026-08-16T{10+i:02d}:00:00+09:00 turn={i}"
        else:
            system = SYSTEM_BASE
        user_text = USER_TURNS[i % len(USER_TURNS)]
        if scenario == "volatile_tail":
            user_text = (
                f"[context update] time=2026-08-16T{10+i:02d}:00:00+09:00 turn={i}\n"
                + user_text
            )
        messages = [{"role": "system", "content": system}] + history + [
            {"role": "user", "content": user_text}
        ]
        body = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0.7,
            "stream": False,
            "cache_prompt": True,
            "chat_template_kwargs": {
                "enable_thinking": True,
                **({"preserve_thinking": True} if scenario != "strip" else {}),
            },
        }
        resp = call(base, body, timeout)
        msg = resp["choices"][0]["message"]
        content = msg.get("content") or ""
        reasoning = msg.get("reasoning_content") or ""
        assistant = {"role": "assistant", "content": content}
        if scenario != "strip" and reasoning:
            assistant["reasoning_content"] = reasoning
        history.append({"role": "user", "content": user_text})
        history.append(assistant)
        t = resp.get("timings") or {}
        row = {
            "scenario": scenario,
            "turn": i + 1,
            "cache_n": t.get("cache_n"),
            "prompt_n": t.get("prompt_n"),
            "prompt_ms": round(t.get("prompt_ms") or 0, 1),
            "predicted_n": t.get("predicted_n"),
            "predicted_ms": round(t.get("predicted_ms") or 0, 1),
            "wall_s": resp["_wall_s"],
            "reasoning_chars": len(reasoning),
            "content_chars": len(content),
        }
        rows.append(row)
        line = json.dumps(row, ensure_ascii=False)
        print(line, flush=True)
        out.write(line + "\n")
        out.flush()
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:9010")
    ap.add_argument("--scenarios", default="preserve,strip,volatile")
    ap.add_argument("--turns", type=int, default=4)
    ap.add_argument("--max-tokens", type=int, default=120)
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--out", default="kv_harness_results.jsonl")
    args = ap.parse_args()

    with open(args.out, "a") as out:
        for scenario in args.scenarios.split(","):
            erase_slots(args.base)
            print(f"### scenario={scenario}", file=sys.stderr, flush=True)
            run_scenario(args.base, scenario, args.turns, args.max_tokens,
                         args.model, args.timeout, out)


if __name__ == "__main__":
    main()
