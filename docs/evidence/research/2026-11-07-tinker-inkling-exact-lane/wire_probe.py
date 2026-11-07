#!/usr/bin/env python3
"""Tinker OpenAI-compatible wire probe for MASC exact lanes (PoC, 2026-11-07).

Records raw HTTP status, error bodies and response shapes for the items an
exact-lane slot depends on. The API key comes from TINKER_API_KEY and is never
written. Output: <out>/probe.jsonl (one object per probe) and <out>/sse-*.txt.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import time

from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

BASE = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
MODEL_64K = "thinkingmachines/Inkling-2-Small"
MODEL_256K = "thinkingmachines/Inkling-2-Small:peft:262144"
EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh"]
FILLER_WORD = "masc "  # one short token-ish unit for window probes
TOOLS = [
    {"type": "function", "function": {"name": "get_weather", "description": "Weather for a city",
     "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}},
    {"type": "function", "function": {"name": "get_time", "description": "Local time for a city",
     "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}},
]


_CLIENT: OpenAI | None = None


def client() -> OpenAI:
    # The official OpenAI SDK is the client Tinker documents for this endpoint.
    global _CLIENT
    if _CLIENT is None:
        _CLIENT = OpenAI(base_url=BASE, api_key=os.environ["TINKER_API_KEY"], max_retries=0, timeout=600.0)
    return _CLIENT


def rate(headers) -> dict:
    return {k.lower(): v for k, v in headers.items() if k.lower().startswith(("x-ratelimit", "retry-after"))}


def post(body: dict, *, stream: bool = False, timeout: float = 600.0):
    """Returns (status, raw response text, wall seconds, rate-limit headers). No retries."""
    extra = {k: v for k, v in body.items() if k not in ("model", "messages", "stream")}
    t0 = time.time()
    try:
        if stream:
            with client().chat.completions.with_streaming_response.create(
                    model=body["model"], messages=body["messages"], stream=True,
                    extra_body=extra, timeout=timeout) as r:
                raw = "\n".join(r.iter_lines())
                return r.status_code, raw, round(time.time() - t0, 2), rate(r.headers)
        r = client().chat.completions.with_raw_response.create(
            model=body["model"], messages=body["messages"], extra_body=extra, timeout=timeout)
        return r.http_response.status_code, r.http_response.text, round(time.time() - t0, 2), rate(r.http_response.headers)
    except APIStatusError as e:
        return e.status_code, e.response.text[:2000], round(time.time() - t0, 2), rate(e.response.headers)
    except (APIConnectionError, APITimeoutError) as e:
        return 0, f"{type(e).__name__}: {e}", round(time.time() - t0, 2), {}


def summary(raw: str) -> dict:
    if not raw:
        return {}
    try:
        d = json.loads(raw)
    except json.JSONDecodeError:
        return {"unparsed": raw[:300]}
    if "choices" not in d:
        return {"error_body": d}
    ch = (d.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    return {
        "finish_reason": ch.get("finish_reason"),
        "message_keys": sorted(msg.keys()),
        "content_type": type(msg.get("content")).__name__,
        "content_head": (msg.get("content") or "")[:120] if isinstance(msg.get("content"), str) else None,
        "reasoning_chars": len(msg.get("reasoning_content") or ""),
        "tool_calls": [(t.get("function") or {}).get("name") for t in (msg.get("tool_calls") or [])],
        "usage": d.get("usage"),
    }


def chat(model: str, messages: list, **extra) -> dict:
    body = {"model": model, "messages": messages, "max_tokens": extra.pop("max_tokens", 512)}
    body.update(extra)
    return body


def run(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    out = open(os.path.join(out_dir, "probe.jsonl"), "a", encoding="utf-8")

    def rec(item: str, case: str, status: int, raw: str, wall: float, hdr: dict, **more) -> None:
        row = {"item": item, "case": case, "status": status, "wall_s": wall, "rate_headers": hdr, **more,
               **(summary(raw) if status == 200 else {"error_raw": raw[:1500]})}
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
        out.flush()
        print(item, case, status, wall)

    hello = [{"role": "user", "content": "Reply with the single word OK."}]
    # 1. effort ladder (+ a float and an out-of-ladder word)
    for eff in EFFORTS + [0.5, "max"]:
        s, raw, w, h = post(chat(MODEL_64K, hello, reasoning_effort=eff, max_tokens=2048))
        rec("1_effort", str(eff), s, raw, w, h)
    # 2. streaming shape at low effort: record delta key order and final usage chunk
    s, raw, w, h = post(chat(MODEL_64K, hello, reasoning_effort="low",
                             stream_options={"include_usage": True}, max_tokens=2048), stream=True)
    open(os.path.join(out_dir, "sse-low.txt"), "w", encoding="utf-8").write(raw)
    order, usage_chunk = [], False
    for line in raw.splitlines():
        if not line.startswith("data: ") or line.strip() == "data: [DONE]":
            continue
        try:
            d = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        usage_chunk = usage_chunk or bool(d.get("usage"))
        for c in d.get("choices") or []:
            for k in (c.get("delta") or {}):
                if not order or order[-1] != k:
                    order.append(k)
    rec("2_stream", "low", s, raw if s != 200 else "", w, h, delta_key_runs=order, usage_chunk=usage_chunk)
    # 3. reasoning replay: assistant turn resent with reasoning_content, plain and with tool_calls
    replay_plain = [{"role": "user", "content": "Pick a colour."},
                    {"role": "assistant", "content": "Blue.", "reasoning_content": "The user wants one colour."},
                    {"role": "user", "content": "Reply with the single word OK."}]
    s, raw, w, h = post(chat(MODEL_64K, replay_plain, reasoning_effort="low", max_tokens=1024))
    rec("3_replay", "assistant+reasoning_content", s, raw, w, h)
    replay_tool = [{"role": "user", "content": "Weather in Seoul?"},
                   {"role": "assistant", "content": None, "reasoning_content": "Call the tool.",
                    "tool_calls": [{"id": "call_1", "type": "function",
                                    "function": {"name": "get_weather", "arguments": "{\"city\":\"Seoul\"}"}}]},
                   {"role": "tool", "tool_call_id": "call_1", "content": "{\"temp_c\": 11}"},
                   {"role": "user", "content": "Summarise in five words."}]
    s, raw, w, h = post(chat(MODEL_64K, replay_tool, tools=TOOLS, reasoning_effort="low", max_tokens=1024))
    rec("3_replay", "tool_calls+reasoning_content", s, raw, w, h)
    # 4. parallel tool calls
    both = [{"role": "user", "content": "Get the weather and the local time for Busan. Call both tools now."}]
    for ptc in (None, True):
        extra = {"tools": TOOLS, "tool_choice": "required", "reasoning_effort": "low", "max_tokens": 1024}
        if ptc is not None:
            extra["parallel_tool_calls"] = ptc
        s, raw, w, h = post(chat(MODEL_64K, both, **extra))
        rec("4_parallel_tools", f"parallel_tool_calls={ptc}", s, raw, w, h)
    # 5. prefix cache reporting: same ~6k-token prefix twice
    prefix = "MASC cache probe. " + ("The keeper reads the board and replies. " * 700)
    cache_msgs = [{"role": "system", "content": prefix}, {"role": "user", "content": "Reply with the single word OK."}]
    for i in (1, 2):
        s, raw, w, h = post(chat(MODEL_64K, cache_msgs, reasoning_effort="none", max_tokens=64))
        rec("5_cache", f"call{i}", s, raw, w, h)
    # 6/7. real window per model id and the overflow error shape
    for model, words, case in ((MODEL_64K, 70_000, "64k-id ~70k"), (MODEL_256K, 70_000, "256k-id ~70k"),
                               (MODEL_256K, 270_000, "256k-id ~270k")):
        msgs = [{"role": "user", "content": FILLER_WORD * words + "\nReply with the single word OK."}]
        s, raw, w, h = post(chat(model, msgs, reasoning_effort="none", max_tokens=16))
        rec("6_window", case, s, raw, w, h)
    # 8. burst of 8 concurrent small requests (exact-lane arrival shape); 429s are recorded, not retried
    def one(_i: int):
        return post(chat(MODEL_64K, hello, reasoning_effort="none", max_tokens=64))
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(one, range(8)))
    for i, (s, raw, w, h) in enumerate(results):
        rec("8_burst", f"req{i}", s, raw, w, h, burst_wall_s=round(time.time() - t0, 2))
    # 9. tinker:// sampler path as the model name
    path = "tinker://89d55c89-5591-5f19-9f22-5e3451af980d:train:0/sampler_weights/000001"
    s, raw, w, h = post(chat(path, hello, reasoning_effort="none", max_tokens=64))
    rec("9_tinker_path", "junk-checkpoint", s, raw, w, h)
    out.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    run(ap.parse_args().out)
