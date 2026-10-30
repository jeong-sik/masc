"""Byte composition of a Keeper checkpoint's atoms [start, end): tool results,
assistant text, reasoning, tool-call arguments, user input. Atoms follow
Runtime_model_input_tail_window.annotate: User and Assistant open an atom,
Tool joins the assistant atom that called it.

usage: python3 -I turn_composition.py <trace.json> <start_atom> <end_atom>
"""
import collections
import json
import sys


def blocks(message):
    content = message.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content or []


def size(value):
    return len(json.dumps(value, ensure_ascii=False).encode())


def main(path, start, end):
    messages = json.load(open(path))["messages"]
    totals = collections.Counter()
    results = []
    atom = -1
    for message in messages:
        role = message.get("role")
        if role in ("user", "assistant"):
            atom += 1
        elif role == "tool" and atom < 0:
            atom = 0
        if not (start <= atom < end):
            continue
        for block in blocks(message):
            kind = block.get("type")
            if role == "tool" or kind == "tool_result":
                key = "tool_result"
                results.append(size(block))
            elif kind == "tool_use":
                key = "tool_call_arguments"
            elif kind in ("thinking", "reasoning", "redacted_thinking"):
                key = "reasoning"
            elif role == "user":
                key = "user_input"
            else:
                key = "assistant_text"
            totals[key] += size(block)
    whole = sum(totals.values())
    results.sort()
    print(json.dumps({
        "atoms": [start, end],
        "bytes": whole,
        "share": {key: round(value / whole, 3) for key, value in totals.most_common()},
        "bytes_by_kind": dict(totals.most_common()),
        "tool_results": len(results),
        "tool_result_bytes_p50": results[len(results) // 2] if results else 0,
        "tool_result_bytes_p90": results[int(len(results) * 0.9)] if results else 0,
        "tool_result_bytes_max": results[-1] if results else 0,
    }, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
