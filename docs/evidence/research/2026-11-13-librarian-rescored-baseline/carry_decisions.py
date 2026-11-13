"""Carry a blind judge's decisions to the cases of a run scored again, and join them with a new
judge's decisions on the cases that changed.

    python3 carry_decisions.py split --kind drops|merges --old <judge folder> --new <judge folder> \
        --out <carry folder>
    # a new blind judge gets only <carry folder>/judge/ and writes decisions.jsonl there
    python3 carry_decisions.py join --new <judge folder> --carry <carry folder>

A judge folder is what `e_synth_audit.py drops` or `merge_cases.py` writes: judge-files.json and
judge/ with judge.md, the rules copy and cases.jsonl; the old one also holds judge/decisions.jsonl.

`split` stops unless both folders gave the judge the same judge.md and rules copy. A new case whose
content, every field but its ID, equals an old case's takes the old decision under the new ID: the
judge saw the same text. Every other new case goes, in the new order, into <carry folder>/judge/
with the same judge.md and rules copy, and for the drop judge (`--kind drops`) a groups.json of
the cases that share a memory (`key.jsonl` item, without its last `-<index>`). carry.json records which old case each
carried case came from and the sha256 of the files read.

`join` writes <new>/judge/decisions.jsonl: the carried decisions and the new judge's, one per new
case in the new order. It stops when that file exists, when a case has no decision or two, or when
a decision names a case the new folder does not hold.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

type JsonObject = dict[str, object]

JUDGE, CASES, DECISIONS, JUDGE_MD = "judge", "cases.jsonl", "decisions.jsonl", "judge.md"
RULES = Path("config") / "prompts" / "librarian.md"
CARRIED, CARRY = "carried.jsonl", "carry.json"


def read_jsonl(path: Path) -> list[JsonObject]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def content(case: JsonObject) -> str:
    return json.dumps({k: v for k, v in case.items() if k != "case"}, sort_keys=True, ensure_ascii=False)


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def one_each(cases: list[JsonObject], decisions: list[JsonObject], where: Path) -> dict[str, JsonObject]:
    """The decisions by case ID. SystemExit unless each case has exactly one and no other is named."""
    ids = [str(c["case"]) for c in cases]
    named = [str(d["case"]) for d in decisions]
    if sorted(named) != sorted(ids) or len(set(ids)) != len(ids):
        missing, extra = sorted(set(ids) - set(named)), sorted(set(named) - set(ids))
        twice = sorted({n for n in named if named.count(n) > 1})
        raise SystemExit(f"{where}: missing {missing}, not a case {extra}, decided twice {twice}")
    return {str(d["case"]): d for d in decisions}


def groups_of(new: Path, ids: list[str]) -> dict[str, list[str]]:
    """The cases in `ids` that share a memory, from the key `e_synth_audit.py drops` writes."""
    memory = {str(k["case"]): str(k["item"]).rsplit("-", 1)[0] for k in read_jsonl(new / "key.jsonl")}
    groups: dict[str, list[str]] = {}
    for case in ids:
        groups.setdefault(memory[case], []).append(case)
    return {f"g{n}": cases for n, cases in enumerate(groups.values(), start=1)}


def split(kind: str, old: Path, new: Path, out: Path) -> int:
    if out.exists():
        raise SystemExit(f"{out} exists")
    for name in (JUDGE_MD, RULES.as_posix()):
        if sha256(old / JUDGE / name) != sha256(new / JUDGE / name):
            raise SystemExit(f"{old} and {new} gave the judge another {name}")
    old_cases = read_jsonl(old / JUDGE / CASES)
    decided = one_each(old_cases, read_jsonl(old / JUDGE / DECISIONS), old / JUDGE / DECISIONS)
    by_content: dict[str, str] = {}
    for case in old_cases:
        if content(case) in by_content:
            raise SystemExit(f"{old}: two cases hold the same content")
        by_content[content(case)] = str(case["case"])
    new_cases = read_jsonl(new / JUDGE / CASES)
    carried = [(str(c["case"]), by_content[content(c)]) for c in new_cases if content(c) in by_content]
    todo = [c for c in new_cases if content(c) not in by_content]
    (out / JUDGE / RULES.parent).mkdir(parents=True)
    shutil.copyfile(new / JUDGE / JUDGE_MD, out / JUDGE / JUDGE_MD)
    shutil.copyfile(new / JUDGE / RULES, out / JUDGE / RULES)
    write_jsonl(out / JUDGE / CASES, todo)
    if kind == "drops":
        groups = groups_of(new, [str(c["case"]) for c in todo])
        (out / JUDGE / "groups.json").write_text(json.dumps(groups, indent=1) + "\n", encoding="utf-8")
    write_jsonl(out / CARRIED, [{**decided[old_id], "case": new_id} for new_id, old_id in carried])
    record = {"old": str(old), "new": str(new),
              "old_cases_sha256": sha256(old / JUDGE / CASES), "old_decisions_sha256": sha256(old / JUDGE / DECISIONS),
              "new_cases_sha256": sha256(new / JUDGE / CASES), "judge_md_sha256": sha256(new / JUDGE / JUDGE_MD),
              "rules_sha256": sha256(new / JUDGE / RULES), "carried": carried, "to_judge": [c["case"] for c in todo]}
    (out / CARRY).write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({"new_cases": len(new_cases), "carried": len(carried), "to_judge": len(todo)}))
    return 0


def join(new: Path, carry: Path) -> int:
    target = new / JUDGE / DECISIONS
    if target.exists():
        raise SystemExit(f"{target} exists")
    record = json.loads((carry / CARRY).read_text(encoding="utf-8"))
    if record["new_cases_sha256"] != sha256(new / JUDGE / CASES):
        raise SystemExit(f"{new} holds other cases than {carry} was split from")
    judged = read_jsonl(carry / JUDGE / DECISIONS) if record["to_judge"] else []
    one_each(read_jsonl(carry / JUDGE / CASES), judged, carry / JUDGE / DECISIONS)
    new_cases = read_jsonl(new / JUDGE / CASES)
    by_case = one_each(new_cases, read_jsonl(carry / CARRIED) + judged, target)
    write_jsonl(target, [by_case[str(c["case"])] for c in new_cases])
    print(json.dumps({"decisions": len(new_cases), "carried": len(record["carried"]), "judged": len(judged)}))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("split")
    s.add_argument("--kind", choices=["drops", "merges"], required=True)
    s.add_argument("--old", required=True)
    s.add_argument("--new", required=True)
    s.add_argument("--out", required=True)
    j = sub.add_parser("join")
    j.add_argument("--new", required=True)
    j.add_argument("--carry", required=True)
    args = ap.parse_args()
    if args.command == "split":
        return split(args.kind, Path(args.old), Path(args.new), Path(args.out))
    return join(Path(args.new), Path(args.carry))


if __name__ == "__main__":
    sys.exit(main())
