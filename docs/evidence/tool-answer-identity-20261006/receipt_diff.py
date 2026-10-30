"""Calls of one tool with byte-identical input in a checkpoint trace's atoms
[start, end): how many distinct outputs each input got, and which top-level
JSON keys differ between the last two outputs (the first may be the
insert itself). Counts and key names only.

usage: python3 -I receipt_diff.py <trace.json> <start-atom> <end-atom> <tool>
"""
import collections
import json
import sys


def main(path, start, end, tool):
    with open(path) as handle:
        messages = json.load(handle)["messages"]
    atom = -1
    inputs = {}
    outputs = collections.defaultdict(list)
    for message in messages:
        if message.get("role") in ("user", "assistant"):
            atom += 1
        if not (start <= atom < end) or not isinstance(message.get("content"), list):
            continue
        for block in message["content"]:
            if block.get("type") == "tool_use" and block.get("name") == tool:
                inputs[block.get("id")] = json.dumps(block.get("input"), sort_keys=True, ensure_ascii=False)
            elif block.get("type") == "tool_result" and block.get("tool_use_id") in inputs:
                body = block.get("content")
                outputs[inputs[block["tool_use_id"]]].append(body if isinstance(body, str) else json.dumps(body))
    repeated = {key: values for key, values in outputs.items() if len(values) > 1}
    changed = collections.Counter()
    for values in repeated.values():
        try:
            first, second = json.loads(values[-2]), json.loads(values[-1])
        except json.JSONDecodeError:
            changed["<non-json>"] += 1
            continue
        for key in sorted(set(first) | set(second)):
            if first.get(key) != second.get(key):
                changed[key] += 1
    print(json.dumps({
        "atoms": [start, end], "tool": tool, "calls": sum(len(v) for v in outputs.values()),
        "distinct_inputs": len(outputs), "inputs_called_more_than_once": len(repeated),
        "repeated_inputs_whose_outputs_all_differ": sum(1 for v in repeated.values() if len(set(v)) == len(v)),
        "max_calls_one_input": max((len(v) for v in outputs.values()), default=0),
        "keys_that_differ": changed.most_common(),
    }, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
