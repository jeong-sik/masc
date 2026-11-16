# pyright: basic
"""Memory-set view of the contrasts of the pass-time research runs. Numbers and IDs only.

    python3 time_cluster.py --runs judged-runs.json --requests <requests.jsonl> --draft F --baseline base \
        [--root <runs folder>] [--judged judged.json] [--screen screen.json] [--out cluster.json]

The pinned E-synth set asks several requests over one memory: requests that carry the same list of
memory claims form a memory set, and they differ only in their candidates. prompt_compare.py divides
a difference by a binomial σ, which treats every drop or absorb as its own draw; the same memory
judged in three requests is not three draws. So this script resamples memory sets. Both sides
answered the same pinned requests, so a resample draws memory sets with replacement and takes each
side's rows of every request of those sets (paired cluster bootstrap, 10,000 draws, fixed seed).
For each metric it prints both sides' counts, the difference of the rates, the 2.5th and 97.5th
percentile of the resampled difference, the share of draws where the draft's rate is lower, how many
memory sets hold a chance of the metric, and the largest share one memory set holds.

It also prints: how many memories of each kind the set holds per request and as distinct memories,
whether two memory sets share a claim, and how far the use times lie from the requests' times;
each memory set's kept count of the memories whose use is still ahead, how many distinct such
memories a side kept in every answer, and the count without invalid answers (an invalid answer
changes no memory, so the scorer counts its memories as kept); and the judged absorbs split by
whether their answer absorbs BIG_ANSWER memories or more, and without the memory set that holds the
most absorbs.

Counts per request come from rows.jsonl and, for absorbs, the blind merge judge's key.jsonl and
judge/decisions.jsonl. An absorb the judge was not asked about (a planted stale fact) counts as not
mergeable, as merge_decisions.py counts it. A side without a merge judge's folder has no absorb
counts. The script stops when a side's totals differ from the counts time_judged.py wrote
(`--judged`) or time_screen.py wrote (`--screen`).
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
import random
from pathlib import Path
from typing import Any

DRAWS = 10_000
SEED = 20261116
# An answer that absorbs this many memories or more is counted as a big answer (time_screen.py).
BIG_ANSWER = 10
JUDGED = ("absorb_precision", "drop_precision")
LABEL_ONLY = {"ahead_keep": "ahead_keep", "past_drop": "past_drop", "stale_drop_recall": "stale_drop",
              "memory_state_accuracy": "state", "drop_precision": "drop_prec"}
METRICS = ("ahead_keep", "past_drop", "drop_precision", "absorb_precision", "stale_drop_recall",
           "memory_state_accuracy")

# How synth_generate.py writes a memory's use time (synth_rows.TIME_FORMAT).
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

type Pair = tuple[int, int]


def lines(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def memory_sets(requests: Path) -> tuple[dict[str, str], dict[str, dict[str, frozenset[str]]], dict[str, Pair], str]:
    """Each request's memory set, its memory IDs by kind, (per-request total, distinct) by kind, and
    a line on what the sets share and how far the use times lie from the requests' times."""
    of_item: dict[str, str] = {}
    kinds: dict[str, dict[str, frozenset[str]]] = {}
    total: collections.Counter[str] = collections.Counter()
    distinct: dict[str, set[tuple[str, str]]] = collections.defaultdict(set)
    sets_of_claim: dict[str, set[str]] = collections.defaultdict(set)
    days: dict[str, list[float]] = {"ahead": [], "past": []}
    asked_on: set[dt.date] = set()
    for row in lines(requests):
        request = row["request"]
        claims = [fact["claim"] for fact in request["facts"]]
        held = hashlib.sha256(json.dumps(claims, ensure_ascii=False).encode()).hexdigest()
        of_item[request["item_id"]] = held
        for claim in claims:
            sets_of_claim[claim].add(held)
        # The pass time the research harness shows: the time of the request's last candidate.
        asked = dt.datetime.fromtimestamp(max(c["seen_at"] for c in request["candidates"]), dt.UTC)
        asked_on.add(asked.date())
        for fact in request["facts"]:
            if fact["use_at"] is not None:
                use = dt.datetime.strptime(fact["use_at"], TIME_FORMAT).replace(tzinfo=dt.UTC)
                days["past" if fact["planted_stale"] else "ahead"].append((use - asked).total_seconds() / 86400)
        by_kind: dict[str, set[str]] = {"all": set(), "ahead": set(), "past": set(), "stale": set()}
        for index, fact in enumerate(request["facts"]):
            mid = f"m{index + 1}"  # prompt_facts.surrogate_id
            names = ["all"] + (["stale"] if fact["planted_stale"] else [])
            if fact["use_at"] is not None:
                names.append("past" if fact["planted_stale"] else "ahead")
            for name in names:
                by_kind[name].add(mid)
                total[name] += 1
                distinct[name].add((held, mid))
        kinds[request["item_id"]] = {name: frozenset(ids) for name, ids in by_kind.items()}
    shared = sum(len(found) > 1 for found in sets_of_claim.values())
    note = (f"claims that two memory sets share {shared}; request days {', '.join(str(day) for day in sorted(asked_on))}; "
            f"use time minus request time in days: ahead {min(days['ahead']):+.1f} to {max(days['ahead']):+.1f}, "
            f"past {min(days['past']):+.1f} to {max(days['past']):+.1f}")
    return of_item, kinds, {name: (total[name], len(distinct[name])) for name in ("all", "ahead", "past", "stale")}, note


def per_request(synth: Path, merges: Path | None) -> dict[str, dict[str, Any]]:
    mergeable: set[tuple[str, str]] | None = None
    if merges is not None:
        mergeable = set()
        decisions = {row["case"]: row["decision"] for row in lines(merges / "judge" / "decisions.jsonl")}
        for key in lines(merges / "key.jsonl"):
            if decisions[key["case"]] == "mergeable":
                mergeable.update((absorb[0], absorb[2]) for absorb in key["absorbs"])
    out: dict[str, dict[str, Any]] = {}
    for row in lines(synth / "rows.jsonl"):
        item = row["item"]
        absorbs = list(row["absorbs"])
        ahead, past = int(row["scheduled_ahead"]), int(row["scheduled_past"])
        out[item] = {
            "ahead_keep": (ahead - int(row["scheduled_ahead_dropped"]), ahead),
            "past_drop": (int(row["scheduled_past_dropped"]), past),
            "drop_precision": (int(row["dropped_expected"]), int(row["dropped"])),
            "stale_drop_recall": (int(row["planted_dropped"]), int(row["planted"])),
            "memory_state_accuracy": (int(row["state_correct"]), int(row["candidates"])),
            "absorb_precision": None if mergeable is None else (
                sum((item, memory) in mergeable for memory in absorbs), len(absorbs)),
            "valid": bool(row["valid"]),
            "big": bool(row["valid"]) and len(absorbs) >= BIG_ANSWER,
            "dropped_off_label": frozenset(row["dropped_off_label"]),
        }
    return out


def added(pairs: list[Pair]) -> Pair:
    return sum(h for h, _ in pairs), sum(c for _, c in pairs)


def rate(pair: Pair) -> float | None:
    return pair[0] / pair[1] if pair[1] else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--draft", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--judged", default=None)
    parser.add_argument("--screen", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    config_path = Path(args.runs).resolve()
    root = config_path.parent.parent if args.root is None else Path(args.root).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))

    def at(value: str | None) -> Path | None:
        return None if value is None else (Path(value) if Path(value).is_absolute() else root / value)

    def side(label: str) -> list[dict[str, dict[str, Any]]]:
        listed = []
        for run in {**config.get("baseline", {}), **config.get("drafts", {}), **config.get("label_only", {})}[label]:
            synth = at(run["synth"])
            assert synth is not None
            listed.append(per_request(synth, at(run.get("merges"))))
        return listed

    requests = Path(args.requests)
    set_of, kinds, held, note = memory_sets(requests)
    labels = {"draft": args.draft, "baseline": args.baseline}
    sides = {name: side(label) for name, label in labels.items()}
    items = sorted(set_of)
    for runs in sides.values():
        for run in runs:
            if sorted(run) != items:
                raise SystemExit("a run did not answer the requests of --requests")
    members: dict[str, list[str]] = collections.defaultdict(list)
    for item in items:
        members[set_of[item]].append(item)
    sets = sorted(members)
    # A set is named by the ID parts its requests share: eval-<keeper>-<memory number>.
    name_of = {s: "-".join(os.path.commonprefix([item.split("-") for item in members[s]])) for s in sets}
    sets.sort(key=lambda s: name_of[s])
    print(f"requests {len(items)} (sha256 {hashlib.sha256(requests.read_bytes()).hexdigest()[:8]}), memory sets {len(sets)}, "
          f"requests per set {dict(sorted(collections.Counter(len(m) for m in members.values()).items()))}")
    print("memories, per request and distinct: " + ", ".join(
        f"{name} {total} / {distinct} in {len({set_of[i] for i in items if kinds[i][name]})} sets"
        for name, (total, distinct) in held.items()))
    print(note)

    def total(name: str, metric: str, among: list[str]) -> Pair | None:
        pairs = [run[i][metric] for run in sides[name] for i in among]
        return None if any(pair is None for pair in pairs) else added(pairs)

    judged = None if args.judged is None else json.loads(Path(args.judged).read_text(encoding="utf-8"))["sides"]
    screen = None if args.screen is None else json.loads(Path(args.screen).read_text(encoding="utf-8"))["groups"]
    rng = random.Random(SEED)
    draws = [[rng.choice(sets) for _ in sets] for _ in range(DRAWS)]
    report: dict[str, Any] = {"draft": args.draft, "baseline": args.baseline, "requests": len(items),
                              "memory_sets": len(sets), "draws": DRAWS, "seed": SEED, "metrics": {}}
    for metric in METRICS:
        totals = {name: total(name, metric, items) for name in sides}
        if totals["draft"] is None or totals["baseline"] is None:
            print(f"{metric}: a side has no merge judge's folder")
            continue
        for name, label in labels.items():
            if judged is not None and metric in JUDGED and label in judged and tuple(judged[label][metric]) != totals[name]:
                raise SystemExit(f"{label} {metric}: counted {totals[name]}, judged.json has {judged[label][metric]}")
            if screen is not None and metric in LABEL_ONLY and label in screen and (
                    tuple(screen[label][LABEL_ONLY[metric]]) != totals[name]):
                raise SystemExit(f"{label} {metric}: counted {totals[name]}, screen.json has {screen[label][LABEL_ONLY[metric]]}")
        in_set = {name: {s: total(name, metric, members[s]) or (0, 0) for s in sets} for name in sides}
        diffs = []
        for draw in draws:
            d, b = rate(added([in_set["draft"][s] for s in draw])), rate(added([in_set["baseline"][s] for s in draw]))
            if d is not None and b is not None:
                diffs.append(d - b)
        diffs.sort()
        low, high = diffs[int(0.025 * len(diffs))], diffs[int(0.975 * len(diffs)) - 1]
        lower = sum(d < 0 for d in diffs) / len(diffs)
        draft, base = totals["draft"], totals["baseline"]
        point = draft[0] / draft[1] - base[0] / base[1]
        chances = {s: in_set["draft"][s][1] + in_set["baseline"][s][1] for s in sets}
        top = max(sets, key=lambda s: in_set["draft"][s][1])
        top_chances = in_set["draft"][top][1]
        report["metrics"][metric] = {
            "draft": list(draft), "baseline": list(base), "d": round(point, 4), "low": round(low, 4),
            "high": round(high, 4), "draft_lower_share": round(lower, 4), "undefined_draws": DRAWS - len(diffs),
            "sets_with_chances": sum(c > 0 for c in chances.values()), "largest_set": name_of[top],
            "largest_set_chances": top_chances,
        }
        print(f"{metric}: draft {draft[0]}/{draft[1]} baseline {base[0]}/{base[1]} d {point:+.3f} "
              f"[{low:+.3f}, {high:+.3f}] draft lower in {lower:.1%} of {len(diffs)} draws; "
              f"{sum(c > 0 for c in chances.values())} sets hold chances; the largest holds {top_chances} of the draft's {draft[1]}")

    print("memories whose use is still ahead, kept/chances per memory set (set, requests, distinct memories, baseline, draft):")
    per_set = []
    for s in sets:
        if not kinds[members[s][0]]["ahead"]:
            continue
        base, draft = total("baseline", "ahead_keep", members[s]), total("draft", "ahead_keep", members[s])
        assert base is not None and draft is not None
        per_set.append({"set": name_of[s], "requests": len(members[s]), "memories": len(kinds[members[s][0]]["ahead"]),
                        "baseline": list(base), "draft": list(draft)})
        print(f"  {name_of[s]} | {len(members[s])} | {len(kinds[members[s][0]]['ahead'])} | {base[0]}/{base[1]} | {draft[0]}/{draft[1]}")
    moved = [(row["draft"][0] / row["draft"][1]) - (row["baseline"][0] / row["baseline"][1]) for row in per_set]
    print(f"  sets where the draft's rate is higher {sum(m > 0 for m in moved)}, lower {sum(m < 0 for m in moved)}, equal {sum(m == 0 for m in moved)}")
    report["ahead_per_set"] = per_set
    report["ahead_distinct"] = {}
    for name, label in labels.items():
        asked: collections.Counter[tuple[str, str]] = collections.Counter()
        kept: collections.Counter[tuple[str, str]] = collections.Counter()
        for run in sides[name]:
            for item in items:
                for mid in kinds[item]["ahead"]:
                    asked[(set_of[item], mid)] += 1
                    kept[(set_of[item], mid)] += mid not in run[item]["dropped_off_label"]
        always = sum(kept[m] == asked[m] for m in asked)
        # A refused answer changes no memory, so the scorer counts what it was asked about as kept.
        refused = [len(kinds[item]["ahead"]) for run in sides[name] for item in items
                   if not run[item]["valid"] and kinds[item]["ahead"]]
        whole = total(name, "ahead_keep", items)
        assert whole is not None
        report["ahead_distinct"][label] = {"memories": len(asked), "kept_in_every_answer": always,
                                           "invalid_answers": len(refused), "memories_in_invalid_answers": sum(refused),
                                           "kept_in_valid_answers": [whole[0] - sum(refused), whole[1] - sum(refused)]}
        print(f"  {label}: of {len(asked)} distinct memories, kept in every answer {always}, dropped in at least one {len(asked) - always}; "
              f"{len(refused)} invalid answers hold {sum(refused)} of the chances, without them {whole[0] - sum(refused)}/{whole[1] - sum(refused)}")

    report["absorbs"] = {}
    for name, label in labels.items():
        if total(name, "absorb_precision", items) is None:
            continue
        big = added([run[i]["absorb_precision"] for run in sides[name] for i in items if run[i]["big"]])
        rest = added([run[i]["absorb_precision"] for run in sides[name] for i in items if not run[i]["big"]])
        answers = sum(run[i]["big"] for run in sides[name] for i in items)
        whole = total(name, "absorb_precision", items)
        assert whole is not None
        most = max(sets, key=lambda s: (total(name, "absorb_precision", members[s]) or (0, 0))[1])
        inside = total(name, "absorb_precision", members[most])
        assert inside is not None
        report["absorbs"][label] = {"big_answers": answers, "big": list(big), "rest": list(rest), "largest_set": name_of[most],
                                    "largest_set_absorbs": list(inside), "without_largest_set": [whole[0] - inside[0], whole[1] - inside[1]]}
        print(f"absorbs of {label}: {answers} answers absorb {BIG_ANSWER}+ and hold {big[0]}/{big[1]}; the rest {rest[0]}/{rest[1]}; "
              f"set {name_of[most]} holds {inside[0]}/{inside[1]}, without it {whole[0] - inside[0]}/{whole[1] - inside[1]}")
    if args.out is not None:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
