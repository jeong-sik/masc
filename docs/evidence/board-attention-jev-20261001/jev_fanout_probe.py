#!/usr/bin/env python3
"""Probe: one Jev request per Board event (one question per keeper) vs one request per keeper.

Reads real candidates from ~/me/.masc/board_attention_candidates, sends both shapes to
the TypeSafe System One endpoint, and prints latency, usage and answer agreement.
The API key is read from TYPESAFEAI_API_KEY and never printed.
"""

import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
EXCLUDED = {"kidsnote-slack-context-collector"}
BASE = os.path.expanduser("~/me/.masc/board_attention_candidates")

RELEVANT = ("The current signal itself requires this keeper's concrete attention, review, or action for "
            "one of keeper_role.board_interests; general topic or capability overlap alone is insufficient.")
NOT_RELEVANT = ("The current signal is aimed elsewhere, is general discussion or noise, only overlaps with a "
                "board interest, or does not require this keeper to act.")
UNCERTAIN = "The current signal does not provide enough evidence to decide; request a full judgment by the review lane."


def criteria(relevant, not_relevant):
    return {"relevant": relevant, "not_relevant": not_relevant, "uncertain": UNCERTAIN}


def post(body):
    data = json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(ENDPOINT, data=data, method="POST", headers={
        "authorization": "Bearer " + os.environ["TYPESAFEAI_API_KEY"],
        "content-type": "application/json", "accept": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read())
            return resp.status, payload, time.time() - started, len(data)
    except urllib.error.HTTPError as err:
        return err.code, {"error": err.read().decode(errors="replace")[:400]}, time.time() - started, len(data)


def confidence_of(answer):
    return answer.get("confidence")


def load_event(post_id, comment_id):
    rows = []
    for path in glob.glob(os.path.join(BASE, "*.jsonl")):
        keeper = os.path.basename(path)[:-len(".jsonl")]
        if keeper in EXCLUDED:
            continue
        last = None
        with open(path) as handle:
            for line in handle:
                if comment_id not in line:
                    continue
                row = json.loads(line)
                if row["signal"].get("post_id") == post_id and row["signal"].get("comment_id") == comment_id:
                    last = row
        if last is not None:
            rows.append((keeper, last))
    return sorted(rows)


def production(row):
    status = row["status"]
    judgment = status.get("judgment") or {}
    decision = (judgment.get("verdict") or {}).get("decision")
    source = (judgment.get("source") or {}).get("kind")
    return decision, source


def main():
    events = [tuple(arg.split(":")) for arg in sys.argv[1:]]
    totals = {"fan_s": 0.0, "single_s": 0.0, "fan_in": 0, "single_in": 0, "agree": 0, "pairs": 0,
              "fan_calls": 0, "single_calls": 0}
    for post_id, comment_id in events:
        rows = load_event(post_id, comment_id)
        signal = rows[0][1]["signal"]
        print(f"\n== event {post_id}/{comment_id} keepers={len(rows)} signal_bytes={len(json.dumps(signal, ensure_ascii=False).encode())}")
        questions = {}
        for index, (keeper, row) in enumerate(rows):
            interests = row["keeper_context"]["board_interests"]
            questions[f"keeper_{index:02d}"] = {
                "type": "choice",
                "instructions": (
                    f"Does the Board signal in state.signal itself require concrete attention, review, or action "
                    f"from keeper {json.dumps(keeper)} for one of its board interests {json.dumps(interests, ensure_ascii=False)}? "
                    "General topic or capability overlap is not sufficient. Choose uncertain when you cannot "
                    "establish either decision from the supplied signal."),
                "criteria": criteria(RELEVANT.replace("keeper_role.board_interests", "its board interests"), NOT_RELEVANT),
            }
        status, payload, elapsed, sent = post({"model": MODEL, "state": {"signal": signal}, "questions": questions})
        totals["fan_calls"] += 1
        totals["fan_s"] += elapsed
        usage = payload.get("usage") or {}
        totals["fan_in"] += usage.get("input_tokens", 0)
        print(f"fan-out: http={status} {elapsed:.2f}s request_bytes={sent} usage={usage} answers={len(payload.get('answers', {}))}")
        if status != 200:
            print("fan-out refused:", payload)
            continue
        fan = payload["answers"]
        for index, (keeper, row) in enumerate(rows):
            single_state = {
                "keeper_role": {"name": keeper, "board_interests": row["keeper_context"]["board_interests"]},
                "items": [{"candidate_id": row["candidate_id"], "signal": signal}],
            }
            single_q = {"relevance": {
                "type": "choice",
                "instructions": (
                    f"Does the current Board signal in items[0] itself require concrete attention, review, or action "
                    f"from keeper {json.dumps(keeper)} for one of keeper_role.board_interests? General topic or capability "
                    "overlap is not sufficient. Choose uncertain when you cannot establish either decision from the supplied signal."),
                "criteria": criteria(RELEVANT, NOT_RELEVANT),
            }}
            s_status, s_payload, s_elapsed, _ = post({"model": MODEL, "state": single_state, "questions": single_q})
            totals["single_calls"] += 1
            totals["single_s"] += s_elapsed
            totals["single_in"] += (s_payload.get("usage") or {}).get("input_tokens", 0)
            fan_answer = fan.get(f"keeper_{index:02d}", {})
            single_answer = (s_payload.get("answers") or {}).get("relevance", {})
            prod_decision, prod_source = production(row)
            same = fan_answer.get("choice") == single_answer.get("choice")
            totals["pairs"] += 1
            totals["agree"] += same
            print(f"  {keeper:24s} fan={fan_answer.get('choice')}:{confidence_of(fan_answer)!s:.4} "
                  f"single={single_answer.get('choice')}:{confidence_of(single_answer)!s:.4} "
                  f"prod={prod_decision}/{prod_source} {'' if same else 'DIFF'}")
    print("\nTOTAL", json.dumps(totals))


if __name__ == "__main__":
    main()
