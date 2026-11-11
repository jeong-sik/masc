"""Rewrite a worktree's scripts/tinker/librarian/pass_lines.json for a re-pin on a pooled E-synth set.

Usage: repin2.py <worktree> <pinned template file> <pooled requests.jsonl> <audit_seed> <fixed_on> <batches.json>

<batches.json> is a list, one object per generated batch, in the order the batches were pooled:
  {"seed": <generator seed>, "first_memory": <--first-memory>, "generated": <requests.jsonl the generator wrote>,
   "audits": [{"dir": <audit folder>, "cases_seed": <cases --seed>}, ...], "final": <requests.jsonl of the last apply>}
A batch whose generated file and audit folders are gone names instead of "generated" and audit folders
the counts an earlier run of this script read from them:
  {"seed": ..., "first_memory": ..., "recorded_audits": [<the audits list that run wrote>], "final": ...}
For such a batch the first two checks below cover only what its final file and the recorded counts show.

Checked before anything is written (AssertionError otherwise):
- every memory number of a batch lies in [first_memory, first_memory + PER_KEEPER);
- the first audit of a batch read as many requests as the generator wrote, each later audit as many as
  the one before kept, and the last kept as many as the batch's final file holds;
- the last audit of every batch was judged under the pinned template (judge-files.json);
- the pooled file holds exactly the lines of the batch finals, in item ID order.

Written:
- files_sha256: every listed file from the worktree's bytes, except the prompt template, whose sha256
  is that of <pinned template file> (the bytes main is to hold);
- e_real: the sha256 and the item count of the worktree's manifest, and the name and sha256 of its
  e_real_template.md;
- e_synth: generator_split, batches (seed, first_memory, audits with their rules and counts),
  audit_seed, requests_sha256, items;
- fixed_on.
The request, the comparison, the gates, the choice and instruction_sha256 stay as they are.
The file is written as it was read: indent 1, no ASCII escapes, one trailing newline.

Then the two files that name the pass lines by sha256 follow them:
- train_sft.py: PASS_LINES_SHA256 and the date in the comment above it;
- prompt_lines.json: pass_lines_sha256, baseline_template_sha256 (the pinned template) and, for every
  model, empty baseline run lists. The runs the old lists named were measured under other pass lines;
  prompt_compare.py answers "pins no baseline runs yet" until new ones are pinned.
"""

from __future__ import annotations

import hashlib
import itertools
import json
import re
import sys
from pathlib import Path

LIB = Path("scripts/tinker/librarian")
TEMPLATE = "../../../config/prompts/librarian.md"
RULES = "config/prompts/librarian.md"
E_REAL_TEMPLATE = "e_real_template.md"
PER_KEEPER = 10
COUNTS = ("requests_in", "requests_out", "cases", "sample_cases", "sample_misfit_rate")
TRAIN_PIN = re.compile(r'# sha256 of pass_lines\.json as fixed on \d{4}-\d{2}-\d{2}, before any training run\.\n'
                       r'PASS_LINES_SHA256 = "[0-9a-f]{64}"\n')


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lines_of(path: Path) -> list[str]:
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def item_id(line: str) -> str:
    return json.loads(line)["request"]["item_id"]


def batch_block(batch: dict[str, object], pinned_sha: str) -> tuple[dict[str, object], list[str]]:
    """The pass_lines entry of one batch and the lines of its final file."""
    seed, first = batch["seed"], batch["first_memory"]
    assert isinstance(seed, int) and isinstance(first, int)
    if "recorded_audits" in batch:
        return recorded_block(batch, seed, first, pinned_sha)
    generated = lines_of(Path(str(batch["generated"])))
    numbers = {int(item_id(line).rsplit("-", 2)[1]) for line in generated}
    assert numbers and min(numbers) >= first and max(numbers) < first + PER_KEEPER, (seed, sorted(numbers), first)
    expected, audits, rules = len(generated), [], ""
    for audit in batch["audits"]:  # type: ignore[union-attr]
        folder = Path(str(audit["dir"]))
        done = json.loads((folder / "audit.json").read_text(encoding="utf-8"))
        rules = json.loads((folder / "judge-files.json").read_text(encoding="utf-8"))[RULES]
        assert done["requests_in"] == expected, (str(folder), done["requests_in"], expected)
        audits.append({"cases_seed": audit["cases_seed"], "rules_sha256": rules, **{k: done[k] for k in COUNTS}})
        expected = done["requests_out"]
    assert rules == pinned_sha, f"batch {seed}: its last audit read rules {rules[:12]}, the pin is {pinned_sha[:12]}"
    final = lines_of(Path(str(batch["final"])))
    assert len(final) == expected, (seed, len(final), expected)
    assert set(final) <= set(generated), f"batch {seed}: its final file holds a line the generator did not write"
    return {"seed": seed, "first_memory": first, "audits": audits}, final


def recorded_block(batch: dict[str, object], seed: int, first: int,
                   pinned_sha: str) -> tuple[dict[str, object], list[str]]:
    """The entry of a batch whose generated file and audit folders are gone, from recorded audit counts."""
    audits = batch["recorded_audits"]
    assert isinstance(audits, list) and audits
    for audit in audits:
        assert set(audit) == {"cases_seed", "rules_sha256", *COUNTS}, sorted(audit)
    for before, after in itertools.pairwise(audits):
        assert after["requests_in"] == before["requests_out"], (seed, before["requests_out"], after["requests_in"])
    assert audits[-1]["rules_sha256"] == pinned_sha, f"batch {seed}: its last audit read other rules than the pin"
    final = lines_of(Path(str(batch["final"])))
    assert len(final) == audits[-1]["requests_out"], (seed, len(final), audits[-1]["requests_out"])
    numbers = {int(item_id(line).rsplit("-", 2)[1]) for line in final}
    assert numbers and min(numbers) >= first and max(numbers) < first + PER_KEEPER, (seed, sorted(numbers), first)
    return {"seed": seed, "first_memory": first, "audits": audits}, final


def main() -> int:
    worktree, pinned, requests = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    audit_seed, fixed_on, batches_path = int(sys.argv[4]), sys.argv[5], Path(sys.argv[6])
    here = worktree / LIB
    path = here / "pass_lines.json"
    before = path.read_text(encoding="utf-8")
    lines = json.loads(before)
    assert json.dumps(lines, indent=1, ensure_ascii=False) + "\n" == before, "pass_lines.json is not in its own format"
    pinned_sha = sha256(pinned)
    blocks, finals = [], []
    for batch in json.loads(batches_path.read_text(encoding="utf-8")):
        block, final = batch_block(batch, pinned_sha)
        blocks.append(block)
        finals.extend(final)
    pooled = lines_of(requests)
    assert pooled == sorted(finals, key=item_id), "the pooled file is not the batch finals in item ID order"
    assert len({item_id(line) for line in pooled}) == len(pooled), "an item ID is written twice"
    for name, old in sorted(lines["files_sha256"].items()):
        new = pinned_sha if name == TEMPLATE else sha256(here / name)
        if new != old:
            print(f"files_sha256 {name}: {old[:12]} -> {new[:12]}")
        lines["files_sha256"][name] = new
    real = lines["e_real"]
    manifest = here / real["manifest"]
    items = len(json.loads(manifest.read_text(encoding="utf-8"))["items"])
    if (sha256(manifest), items) != (real["manifest_sha256"], real["items"]):
        print(f"e_real manifest: {real['manifest_sha256'][:12]} ({real['items']}) -> {sha256(manifest)[:12]} ({items})")
    lines["e_real"] = {"manifest": real["manifest"], "manifest_sha256": sha256(manifest),
                       "template": E_REAL_TEMPLATE, "template_sha256": sha256(here / E_REAL_TEMPLATE),
                       "items": items}
    lines["e_synth"] = {"generator_split": lines["e_synth"]["generator_split"], "batches": blocks,
                        "audit_seed": audit_seed, "requests_sha256": sha256(requests), "items": len(pooled)}
    print(f"e_synth: {json.dumps(lines['e_synth'])}")
    print(f"e_real: template {lines['e_real']['template_sha256'][:12]}")
    if lines["fixed_on"] != fixed_on:
        print(f"fixed_on: {lines['fixed_on']} -> {fixed_on}")
        lines["fixed_on"] = fixed_on
    path.write_text(json.dumps(lines, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    pin = sha256(path)
    print(f"pass_lines.json sha256 {pin}")
    train = here / "train_sft.py"
    source = train.read_text(encoding="utf-8")
    assert len(TRAIN_PIN.findall(source)) == 1, "train_sft.py does not hold the pin as expected"
    train.write_text(TRAIN_PIN.sub(
        f'# sha256 of pass_lines.json as fixed on {fixed_on}, before any training run.\n'
        f'PASS_LINES_SHA256 = "{pin}"\n', source), encoding="utf-8")
    compare_path = here / "prompt_lines.json"
    compare_before = compare_path.read_text(encoding="utf-8")
    compare = json.loads(compare_before)
    assert json.dumps(compare, indent=1, ensure_ascii=False) + "\n" == compare_before, "prompt_lines.json is not in its own format"
    compare["pass_lines_sha256"] = pin
    compare["baseline_template_sha256"] = pinned_sha
    for name, model in sorted(compare["models"].items()):
        dropped = len(model["base_synth_rows_sha256"]) + len(model["base_real_rows_sha256"])
        model["base_synth_rows_sha256"], model["base_real_rows_sha256"] = [], []
        print(f"prompt_lines.json {name}: {dropped} baseline rows files unpinned")
    compare_path.write_text(json.dumps(compare, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
