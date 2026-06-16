#!/usr/bin/env python3
"""memory_os_judge_eval.py — RFC-0247 §-1 P-1 step 0b: LLM-as-judge value eval.

Auto-labels memory-os facts durable | ephemeral | uncertain and reports the
noise_rate that the OCaml harness (test/eval_memory_os_value.ml) defines:

    noise_rate = ephemeral / (ephemeral + durable)   # uncertain excluded

ANTI-RIG (mirrors judge_accuracy in the OCaml harness; user directive 2026-06-16
"가짜 성공 테스트 금지"): the judge is validated against the hand-labelled GOLD set
FIRST. If it cannot reproduce the gold (accuracy < --min-accuracy), the run ABORTS
— a judge that can't distinguish the known cases must not be trusted on live data,
so it cannot silently flatter the score.

Modes:
  calibrate  — only run the gold check (cheap; proves the judge before any spend)
  measure    — sample N facts from the store, report noise_rate (+ the _shared tier)
  relabel    — judge ALL facts, write relabelled JSONL (retroactive cleanup of the
               pre-#21257 legacy backlog the producer can no longer fix)

Backend is pluggable (--judge-cmd, default "sb glm-text"); store dir is
--store-dir. Makes live LLM calls — run on demand. Deterministic given fixed model
output, reproducible via the recorded label output.
"""
from __future__ import annotations
import argparse, glob, json, os, subprocess, sys, re

# GOLD: the single irreducible HUMAN-anchored calibration set — the one manual
# artifact left after moving all measurement to the LLM judge. It exists to keep the
# judge honest (anti-rig): a judge that cannot reproduce these labels is not trusted.
# Replacing it with LLM labels too would make the judge validate itself (circular);
# the only non-manual alternative is a SEPARATE stronger reference model labelling it
# (cross-model), which is a deliberate future option, not the default.
GOLD: list[tuple[str, str]] = [
    ("The rondo sandbox blocks Write/Read tools on the masc repo", "durable"),
    ("The Write tool has a destructive guard that blocks ${} expansion", "durable"),
    ("sed -i does not persist across Docker turn containers", "durable"),
    ("DUNE_CACHE=disabled is required to rebuild after cross-lib .mli changes", "durable"),
    ("A continuation checkpoint was saved and the keeper remains scheduled", "ephemeral"),
    ("No claimable or unclaimed tasks remain", "ephemeral"),
    ("Board curation was submitted", "ephemeral"),
    ("desire, intention, blocker, and need are all none", "ephemeral"),
    ("A continuation checkpoint was saved at turn 22", "ephemeral"),
]

JUDGE_SYSTEM = (
    "You classify each memory claim written by an autonomous agent as exactly one of:\n"
    "- durable: knowledge that would still be TRUE and USEFUL to a DIFFERENT agent on a "
    "later day, independent of the run that wrote it (a constraint, invariant, "
    "externally-verifiable fact, decision-with-rationale, or concrete code/config change).\n"
    "- ephemeral: lifecycle/coordination boilerplate that is true only right now (a "
    "checkpoint was saved, the keeper is scheduled/woken, the current task-queue/backlog "
    "state whether full or empty, a curation was submitted, heartbeat/status ticks, the "
    "agent's present desire/intention/blocker/need).\n"
    "- uncertain: genuinely cannot tell.\n"
    "Judge the claim's content, not its phrasing. Reply with ONLY a JSON array, one object "
    'per input line, in order: [{"i":1,"label":"durable"}, ...]. No prose, no markdown.'
)

VALID = {"durable", "ephemeral", "uncertain"}


def run_judge(claims: list[str], judge_cmd: str) -> list[str]:
    """Label a batch of claims. Unparseable items default to 'uncertain' (never a
    silent durable/ephemeral guess)."""
    numbered = "\n".join(f"{i + 1}. {c}" for i, c in enumerate(claims))
    prompt = f"Classify these {len(claims)} claims:\n{numbered}"
    argv = judge_cmd.split() + ["--no-thinking", "--system", JUDGE_SYSTEM, prompt]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=180).stdout
    except Exception as e:
        print(f"  judge call failed: {e}", file=sys.stderr)
        return ["uncertain"] * len(claims)
    labels = ["uncertain"] * len(claims)
    m = re.search(r"\[.*\]", out, re.S)
    if not m:
        return labels
    try:
        arr = json.loads(m.group(0))
    except Exception:
        return labels
    for obj in arr:
        if isinstance(obj, dict) and "i" in obj:
            idx = obj["i"] - 1
            lab = str(obj.get("label", "")).strip().lower()
            if 0 <= idx < len(labels) and lab in VALID:
                labels[idx] = lab
    return labels


def judge_all(claims: list[str], judge_cmd: str, batch: int) -> list[str]:
    out: list[str] = []
    for i in range(0, len(claims), batch):
        chunk = claims[i : i + batch]
        out.extend(run_judge(chunk, judge_cmd))
        print(f"  judged {min(i + batch, len(claims))}/{len(claims)}", file=sys.stderr)
    return out


def noise_rate(labels: list[str]) -> float:
    eph = labels.count("ephemeral")
    dur = labels.count("durable")
    return eph / (eph + dur) if (eph + dur) else 0.0


def calibrate(judge_cmd: str, min_acc: float) -> float:
    claims = [c for c, _ in GOLD]
    got = run_judge(claims, judge_cmd)
    correct = sum(1 for (got_l, (_, exp)) in zip(got, GOLD) if got_l == exp)
    acc = correct / len(GOLD)
    print(f"calibration: judge agreed with {correct}/{len(GOLD)} gold labels = {acc:.0%}")
    for (claim, exp), g in zip(GOLD, got):
        flag = "ok" if g == exp else "MISS"
        print(f"  [{flag}] gold={exp:9} judge={g:9} | {claim[:70]}")
    if acc < min_acc:
        print(
            f"\nABORT: judge accuracy {acc:.0%} < --min-accuracy {min_acc:.0%}. "
            "Its live numbers are NOT trusted (anti-rig gate).",
            file=sys.stderr,
        )
    return acc


def load_facts(store_dir: str, include_shared: bool) -> list[tuple[str, str]]:
    """Returns [(claim, producer_category)]."""
    facts = []
    for path in sorted(glob.glob(os.path.join(store_dir, "*.facts.jsonl"))):
        if not include_shared and os.path.basename(path).startswith("_shared"):
            continue
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            claim = o.get("claim", "")
            cat = o.get("category")
            cat = cat if isinstance(cat, str) else (cat or {}).get("kind", "?")
            if claim:
                facts.append((claim, cat))
    return facts


def deterministic_sample(items: list, n: int) -> list:
    """Stable stride sample — reproducible, no RNG."""
    if n <= 0 or n >= len(items):
        return items
    stride = len(items) / n
    return [items[int(i * stride)] for i in range(n)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["calibrate", "measure", "relabel"], default="calibrate")
    ap.add_argument("--store-dir", default=os.path.expanduser("~/me/.masc/config/keepers"))
    ap.add_argument("--judge-cmd", default="sb glm-text")
    ap.add_argument("--sample", type=int, default=100, help="facts to judge in measure mode")
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--min-accuracy", type=float, default=0.78)
    ap.add_argument("--out", default="", help="relabel mode: output JSONL path")
    args = ap.parse_args()

    acc = calibrate(args.judge_cmd, args.min_accuracy)
    if acc < args.min_accuracy:
        return 2  # anti-rig: refuse to report live numbers with an untrustworthy judge
    if args.mode == "calibrate":
        return 0

    shared = load_facts(args.store_dir, include_shared=True)
    keeper_facts = load_facts(args.store_dir, include_shared=False)
    shared_only = [f for f in shared if f not in keeper_facts]

    if args.mode == "measure":
        if shared_only:
            sl = judge_all([c for c, _ in shared_only], args.judge_cmd, args.batch)
            print(f"\n_shared tier ({len(shared_only)} facts): noise_rate = {noise_rate(sl):.0%} "
                  f"(eph {sl.count('ephemeral')} / dur {sl.count('durable')} / unc {sl.count('uncertain')})")
        sample = deterministic_sample(keeper_facts, args.sample)
        sl = judge_all([c for c, _ in sample], args.judge_cmd, args.batch)
        print(f"\nkeeper store sample ({len(sample)} of {len(keeper_facts)}): "
              f"noise_rate = {noise_rate(sl):.0%} "
              f"(eph {sl.count('ephemeral')} / dur {sl.count('durable')} / unc {sl.count('uncertain')})")
        # producer-disagreement: how often the producer's category=fact is judged ephemeral
        mis = sum(1 for (_, cat), j in zip(sample, sl) if cat == "fact" and j == "ephemeral")
        nfact = sum(1 for _, cat in sample if cat == "fact")
        if nfact:
            print(f"producer mislabel: {mis}/{nfact} of category=fact are judged ephemeral "
                  f"= {mis / nfact:.0%}")
        return 0

    if args.mode == "relabel":
        labels = judge_all([c for c, _ in keeper_facts], args.judge_cmd, args.batch)
        out_path = args.out or "memory_os_relabel.jsonl"
        with open(out_path, "w") as f:
            for (claim, cat), lab in zip(keeper_facts, labels):
                f.write(json.dumps({"claim": claim, "producer_category": cat, "judge_label": lab}) + "\n")
        print(f"\nwrote {len(labels)} relabelled rows -> {out_path}; "
              f"store noise_rate = {noise_rate(labels):.0%}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
