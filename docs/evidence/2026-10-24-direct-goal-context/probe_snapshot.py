"""Inspect retained canonical inputs from the fixed-candidate canary.

This is read-only and does not possess the raw serialized HTTP body. The wire
SHA is the SDK observation joined by the producer to these retained parts.
It asserts only the latest retained request of each of the first three turns.
"""
import argparse
import hashlib
import json
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("base_path", type=pathlib.Path)
args = parser.parse_args()
root = args.base_path / ".masc"
path = root / "keepers/goal-canary/provider-inputs/2026-10/24.jsonl"
rows = [json.loads(line) for line in path.read_text().splitlines() if line]
markers = {
    "goal_id": "goal-canary-two-results",
    "criterion_revision": "fb46adb4a118c2267dfbc17e89af3ad0",
    "measurement_id": "276a8caa8a6ee42024a449a634b9f16b",
}

def load(artifact):
    sha = re.search(r"sha256=([a-f0-9]{64})", artifact["content_ref"]).group(1)
    data = (root / "tool_blobs" / sha[:2] / sha).read_bytes()
    assert len(data) == artifact["bytes"]
    assert hashlib.sha256(data).hexdigest() == sha
    return data

result = []
for turn in (1, 2, 3):
    row, = [row for row in rows if row["absolute_turn"] == turn]
    parts = ([] if row["system_prompt"] is None else [load(row["system_prompt"])])
    parts += [load(message["artifact"]) for message in row["messages"]]
    found = {name: any(value.encode() in data for data in parts)
             for name, value in markers.items()}
    assert found == dict.fromkeys(markers, turn == 3), (turn, found)
    result.append({"turn_ref": row["turn_ref"], "wire": row["wire"],
                   "retained_message_count": len(row["messages"]),
                   "retained_parts_contain": found})
print(json.dumps({
    "candidate_head": "dca2013ebf915a37631a5d95d305d226928c1b6f",
    "scope": "latest retained canonical parts per absolute turn, joined to pre-dispatch wire digest; raw wire body unavailable",
    "part_integrity": "all inspected blobs match recorded byte length and SHA256",
    "result": "reproduced direct-owner omission in turns 1 and 2, autonomous Goal delivery in turn 3",
    "turns": result,
}, indent=2))
