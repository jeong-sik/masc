# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Measure models on the keeper-librarian admission evaluation sets.

    MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/eval_admission.py run --set real \
        --target base=thinkingmachines/Inkling-2-Small:peft:262144 --target A=tinker://... \
        --out artifacts/tinker/librarian/eval-<name>-real --budget 6
    uv run scripts/tinker/librarian/eval_admission.py run --set synth --requests <requests.jsonl> ...
    uv run scripts/tinker/librarian/eval_admission.py verdict --real <dir> --synth <dir> \
        --drops <e_synth_audit.py drops --out> \
        --train A=artifacts/tinker/librarian/train-A --train B=artifacts/tinker/librarian/train-B

`pass_lines.json` fixes the request, the sets, the baseline, the candidates and
the gates. `run` refuses to start when a file it pins has changed. Each item
goes to every target back to back in --target order, so the targets meet the
endpoint under the same load. A verdict run starts from an empty --out: its
baseline calls must leave next to the candidates' calls, which a call log from
an earlier run cannot show. The request is the one MASC's exact lane sends: the
admission prompt, then the schema instruction as the last user message.

Definitions:
- valid: HTTP 200, finish_reason "stop", and `admission_validator.validate`
  accepts the content against the prompt, as MASC would.
- E-real outcome agreement: candidates whose outcome equals the live answer's,
  over every candidate (an answer that is not valid agrees with nothing).
  Reported, not gated.
- E-real paired agreement (G4): on the items where both the candidate and the
  baseline answered validly, candidates whose outcome equals the live answer's.
  The lead is the candidate's share minus the baseline's. An answer that is not
  valid sends the request to the next slot, so validity is G1's business and
  G4 compares judgments only.
- E-real dropped_not_in_live (G2): memory IDs a valid answer drops that the
  live answer for the same record keeps. The live answer takes a fact out by
  `dropped` or by absorbing it into a new claim; either counts as not kept.
- E-real absorbed_not_in_live: memory IDs a valid answer absorbs that the live
  answer keeps. Listed for human review with G2's IDs, not gated: absorbing
  merges a fact into a new claim, which MASC's absorb gate checks at commit.
- E-synth outcome accuracy: candidates whose outcome equals the label and whose
  `memory_claim` points where the label's kind needs it, over every candidate
  (an answer that is not valid is wrong). A new fact names a claim the answer
  adds; a paraphrase names the existing claim it restates; a correction names a
  claim that supersedes the label's target, and the target is dropped.
- E-synth drop precision: dropped IDs that are planted stale facts or label
  correction targets, over all dropped IDs of valid answers (1.0 with no drops).
  Any other dropped ID is an off-label drop. Rows list them, and `verdict`
  needs a blind judge's class for each one (`audit_decisions`): when the judge
  takes the fact out as well, no target is scored on that memory's requests.
  A drop the judge keeps stays wrong, also when its memory leaves scoring.
- E-synth absorbed: memory IDs valid answers absorb. No label asks for one.
  Reported apart, not gated, as E-real reports its absorbs: MASC's absorb gate
  checks each absorb at commit, while nothing checks a drop.
- E-synth stale drop recall: planted stale facts dropped, over all planted. An
  absorbed stale fact is not dropped: its text lives on in the new claim.
- latency p50 (G5): median wall time of E-real calls that returned HTTP 200.
  Every target first gets each prompt with WARM_MAX_TOKENS, so the measured
  calls all read a cached prefix. `verdict` refuses when fewer than
  `warm_share_min` of a target's calls did. `tinker_oai` retries a transient
  failure itself and logs every attempt, so wall_s is one attempt. A call that
  still failed is an answer that is not valid, and `http_errors` counts them.
- `verdict` recomputes every number from rows.jsonl. It refuses unless both runs
  sent the same model under each name, and each candidate is the sampler_path
  `train_sft.py` saved for that branch under these pass lines.

Output: <out>/calls.jsonl holds raw answers (E-real answers carry Keeper memory;
keep them local), <out>/rows.jsonl numbers, IDs and verdicts, <out>/summary.json.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never, cast

import admission_request as R
import admission_validator as AV
import audit_decisions as D
import exact_store as E
import synth_render
import yojson_wire as Y
from tinker_oai import HTTP_OK, Caller

HERE = Path(__file__).resolve().parent
PASS_LINES = HERE / "pass_lines.json"
WORKERS = 4
# Tinker keeps a prompt's prefix cached for at least half an hour (11-08: a rerun of the
# E-real prompts read 100% of their tokens from cache), and a LoRA checkpoint has its own
# cache. Before the measured calls of an item, every target gets the same prompt with this
# output budget, so every measured call meets a warm cache whatever ran earlier.
WARM_MAX_TOKENS = 1
# A measured call counts as warm when this share of its prompt tokens came from cache.
WARM_CACHED_SHARE = 0.9
# exact_output_ready_admission.ml domain_schema_instruction_text, verbatim.
INSTRUCTION = ("Return exactly one JSON value matching this JSON Schema. Do not use Markdown "
               "code fences or include any explanation. JSON Schema: %s")

type JsonObject = dict[str, object]


@dataclass(frozen=True, slots=True)
class RealItem:
    item_id: str
    prompt: R.AdmissionPrompt
    text: str
    live: AV.AdmissionAnswer


@dataclass(frozen=True, slots=True)
class SynthItem:
    item_id: str
    prompt: R.AdmissionPrompt
    text: str
    label: JsonObject  # synth_spec.RequestLabel as JSON


type Item = RealItem | SynthItem


@dataclass(frozen=True, slots=True)
class Check:
    answer: AV.AdmissionAnswer | None
    problems: tuple[str, ...]


def schema_instruction() -> str:
    """The last user message MASC sends: Yojson.Safe.to_string of the sorted output schema."""
    return INSTRUCTION % Y.write(AV.admission_output_schema())


def check(prompt: R.AdmissionPrompt, content: str | None) -> Check:
    if content is None:
        return Check(None, ("no_answer",))
    result = AV.validate(prompt, content)
    match result:
        case AV.Valid(answer=answer):
            return Check(answer, ())
        case AV.Invalid(violations=violations):
            return Check(None, tuple(v.kind.value for v in violations))
        case _:
            assert_never(result)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_pass_lines() -> JsonObject:
    lines = cast(JsonObject, json.loads(PASS_LINES.read_text(encoding="utf-8")))
    pinned = cast(dict[str, str], lines["files_sha256"])
    changed = [name for name, sha in pinned.items() if sha256_file(HERE / name) != sha]
    if changed:
        raise SystemExit(f"pass_lines.json pins other contents for: {', '.join(changed)}")
    if hashlib.sha256(schema_instruction().encode()).hexdigest() != lines["instruction_sha256"]:
        raise SystemExit("the schema instruction differs from pass_lines.json")
    return lines


def real_items(manifest: Path, base: Path) -> list[RealItem]:
    """E-real items. A prompt this checkout's template cannot read, or a live answer the
    checker refuses, stops the run: the checker would then not be MASC's."""
    items: list[RealItem] = []
    for record in E.records_for(manifest, base):
        prompt = R.parse(record.prompt, synth_render.template())
        if isinstance(prompt, R.ParseError):
            raise SystemExit(f"{record.digest[:16]}: prompt does not parse: {prompt.detail}")
        live = check(prompt, Y.write(record.answer))
        if live.answer is None:
            raise SystemExit(f"{record.digest[:16]}: the live answer is refused: {live.problems}")
        items.append(RealItem(record.digest[:16], prompt, record.prompt, live.answer))
    return items


def synth_items(path: Path) -> list[SynthItem]:
    """Rendered synthetic requests with their labels, from synth_generate.py output."""
    items: list[SynthItem] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        row = cast(JsonObject, json.loads(line))
        request = cast(JsonObject, row["request"])
        prompt = synth_render.prompt_of(request)
        items.append(SynthItem(cast(str, request["item_id"]), prompt, R.render(prompt),
                               cast(JsonObject, row["label"])))
    return items


def outcomes(answer: AV.AdmissionAnswer) -> dict[str, tuple[str, str | None]]:
    return {j.request_id: (j.outcome, j.memory_claim) for j in answer.judgments}


def removed(answer: AV.AdmissionAnswer) -> set[str]:
    """Memory IDs the answer takes out of current memory: dropped, or absorbed into a new claim."""
    return set(answer.dropped) | {mid for mid, _ in answer.absorbed}


def score_real(item: RealItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    live = outcomes(item.live)
    got = outcomes(mine) if mine is not None else {}
    gone = removed(item.live)
    return {"candidates": len(live), "agree": sum(got.get(k, ("",))[0] == v[0] for k, v in live.items()),
            "outcomes": {k: [v[0], got.get(k, ("",))[0]] for k, v in live.items()},
            "dropped_not_in_live": sorted(set(mine.dropped) - gone) if mine is not None else [],
            "absorbed_not_in_live": sorted({mid for mid, _ in mine.absorbed} - gone) if mine is not None else [],
            "live_removed": len(gone)}


def claim_matches(label: JsonObject, claim: str | None, answer: AV.AdmissionAnswer) -> bool:
    """Whether a judgment's `memory_claim` points where the label's kind needs it.
    MASC accepts any claim of final memory, so an outcome alone can name the wrong one."""
    target = label.get("supersedes")
    match label["outcome"]:
        case "incorporated" if target is not None:
            supersedes = {new: old for old, new in answer.revisions}
            return claim is not None and supersedes.get(claim) == target and target in answer.dropped
        case "incorporated":
            return claim is not None and claim in answer.added_claims
        case "already_represented":
            return claim == label.get("already_claim")
        case _:
            return True


def score_synth(item: SynthItem, mine: AV.AdmissionAnswer | None) -> JsonObject:
    labels = {cast(str, c["request_id"]): c for c in cast(list[JsonObject], item.label["candidates"])}
    planted = set(cast(list[str], item.label["planted_stale"]))
    targets = {cast(str, c["supersedes"]) for c in labels.values() if c.get("supersedes") is not None}
    got = outcomes(mine) if mine is not None else {}
    drops = set(mine.dropped) if mine is not None else set[str]()
    gone = removed(mine) if mine is not None else set[str]()
    correct: dict[str, bool] = {}
    for rid, label in labels.items():
        outcome, claim = got.get(rid, ("", None))
        correct[rid] = mine is not None and outcome == label["outcome"] and claim_matches(label, claim, mine)
    return {"candidates": len(labels), "correct": sum(correct.values()), "per_candidate": correct,
            "dropped": len(drops), "absorbed": len(gone - drops), "dropped_expected": len(drops & (planted | targets)),
            "dropped_off_label": sorted(drops - planted - targets),
            "planted": len(planted), "planted_dropped": len(drops & planted)}


def run_item(caller: Caller, request: JsonObject, targets: list[tuple[str, str]], item: Item) -> list[JsonObject]:
    kind = "real" if isinstance(item, RealItem) else "synth"
    messages = [item.text, schema_instruction()]
    effort = cast(str, request["reasoning_effort"])
    for name, model in targets:
        if caller.ask(model=model, label=f"{kind}:{name}:{item.item_id}:warm", messages=messages, effort=effort,
                      max_tokens=WARM_MAX_TOKENS) is None:
            return []
    rows: list[JsonObject] = []
    for name, model in targets:
        call = caller.ask(model=model, label=f"{kind}:{name}:{item.item_id}", messages=messages, effort=effort,
                          max_tokens=cast(int, request["max_tokens"]))
        if call is None:
            break
        result = check(item.prompt, call.answer())
        match item:
            case RealItem():
                score = score_real(item, result.answer)
            case SynthItem():
                score = score_synth(item, result.answer)
        rows.append({"set": kind, "item": item.item_id, "target": name, "status": call.status, "finish": call.finish,
                     "sent_at": call.sent_at, "wall_s": call.wall_s, "prompt_tokens": call.prompt_tokens,
                     "cached_tokens": call.cached_tokens,
                     "completion_tokens": call.completion_tokens, "reasoning_chars": len(call.reasoning or ""),
                     "cost_usd": round(call.cost(), 6), "valid": result.answer is not None,
                     "problems": list(result.problems), **score})
    return rows


def warm(row: JsonObject) -> bool:
    return cast(int, row["cached_tokens"]) >= WARM_CACHED_SHARE * max(1, cast(int, row["prompt_tokens"]))


def summarize(kind: str, rows: list[JsonObject], wrong_elsewhere: dict[str, int] | None = None) -> JsonObject:
    """Per target numbers of a set. `wrong_elsewhere` adds, per target, E-synth drops that are
    wrong but sit on rows left out of scoring (`audit_decisions.Adjudication.wrong_outside`)."""
    out: JsonObject = {}
    for name in dict.fromkeys(cast(str, r["target"]) for r in rows):
        mine = [r for r in rows if r["target"] == name]
        ok = [cast(float, r["wall_s"]) for r in mine if r["status"] == HTTP_OK]
        valid = sum(bool(r["valid"]) for r in mine)
        part: JsonObject = {"items": len(mine), "valid": valid, "valid_rate": valid / len(mine),
                            "http_errors": len(mine) - len(ok),
                            "latency_p50_s": statistics.median(ok) if ok else None,
                            "warm_share": sum(warm(r) for r in mine) / len(mine),
                            "cost_usd": round(sum(cast(float, r["cost_usd"]) for r in mine), 4)}
        cands = sum(cast(int, r["candidates"]) for r in mine)
        if kind == "real":
            part["outcome_agreement"] = sum(cast(int, r["agree"]) for r in mine) / cands
            part["dropped_not_in_live"] = sum(len(cast(list[str], r["dropped_not_in_live"])) for r in mine)
            part["absorbed_not_in_live"] = sum(len(cast(list[str], r["absorbed_not_in_live"])) for r in mine)
        else:
            drops = sum(cast(int, r["dropped"]) for r in mine) + (wrong_elsewhere or {}).get(name, 0)
            part["outcome_accuracy"] = sum(cast(int, r["correct"]) for r in mine) / cands
            part["drop_precision"] = sum(cast(int, r["dropped_expected"]) for r in mine) / drops if drops else 1.0
            part["absorbed"] = sum(cast(int, r["absorbed"]) for r in mine)
            part["stale_drop_recall"] = (sum(cast(int, r["planted_dropped"]) for r in mine)
                                         / max(1, sum(cast(int, r["planted"]) for r in mine)))
        out[name] = part
    return out


def run(args: argparse.Namespace) -> int:
    lines = load_pass_lines()
    kind, out = cast(str, args.set), Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    targets = [cast(tuple[str, str], tuple(t.split("=", 1))) for t in cast(list[str], args.target)]
    items: list[Item]
    if kind == "real":
        real = cast(JsonObject, lines["e_real"])
        manifest = HERE / cast(str, real["manifest"])
        if sha256_file(manifest) != real["manifest_sha256"]:
            raise SystemExit("the E-real manifest differs from pass_lines.json")
        items = list(real_items(manifest, E.base_path(cast(str | None, args.base))))
    else:
        requests = Path(cast(str, args.requests))
        if sha256_file(requests) != cast(JsonObject, lines["e_synth"])["requests_sha256"]:
            raise SystemExit("the E-synth requests differ from pass_lines.json")
        items = list(synth_items(requests))
    caller = Caller(out / "calls.jsonl", cast(float, args.budget))
    request = cast(JsonObject, lines["request"])

    def one(item: Item) -> list[JsonObject]:
        return run_item(caller, request, targets, item)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        rows = [r for rs in pool.map(one, items) for r in rs]
    with (out / "rows.jsonl").open("w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    summary = {"set": kind, "pass_lines_sha256": sha256_file(PASS_LINES), "targets": dict(targets),
               "spent_usd": round(caller.spent, 4), "stopped": caller.stopped, "by_target": summarize(kind, rows)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary["by_target"]))
    return 2 if caller.stopped is not None else 0


def read_rows(out: Path) -> list[JsonObject]:
    return [cast(JsonObject, json.loads(line)) for line in (out / "rows.jsonl").read_text(encoding="utf-8").splitlines()]


def by_item(rows: list[JsonObject], name: str) -> dict[str, JsonObject]:
    return {cast(str, r["item"]): r for r in rows if r["target"] == name}


def paired(rows: list[JsonObject], baseline: str, name: str) -> JsonObject:
    """G4: outcome agreement on the E-real items that `name` and the baseline both answered validly."""
    mine, base = by_item(rows, name), by_item(rows, baseline)
    both = sorted(i for i in mine.keys() & base.keys() if mine[i]["valid"] and base[i]["valid"])
    cands = sum(cast(int, base[i]["candidates"]) for i in both)
    agree, base_agree = (sum(cast(int, side[i]["agree"]) for i in both) for side in (mine, base))
    return {"items": len(both), "candidates": cands,
            "agreement": agree / cands if cands else None,
            "baseline_agreement": base_agree / cands if cands else None,
            "lead": (agree - base_agree) / cands if cands else None}


def widest_gap_s(rows: list[JsonObject], baseline: str, name: str) -> float | None:
    """The widest gap over items between the baseline's call and this target's call.
    None when an item lacks one of the two calls or its send time."""
    mine, base = by_item(rows, name), by_item(rows, baseline)
    if not mine or mine.keys() != base.keys():
        return None
    gaps: list[float] = []
    for item, row in mine.items():
        a, b = row["sent_at"], base[item]["sent_at"]
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            return None
        gaps.append(abs(a - b))
    return max(gaps)


def choose(names: list[str], result: JsonObject, synth: dict[str, JsonObject], rows: list[JsonObject],
           margin: float) -> str | None:
    """The first passing candidate in pass_lines order, unless a later passing one leads it by `margin`
    on E-synth outcome accuracy and on E-real agreement over the items both answered validly.
    The two are compared with each other, not through their leads over the baseline: those leads
    are measured on different items."""
    passing = [n for n in names if cast(JsonObject, result[n])["pass"]]
    if not passing:
        return None
    pick = passing[0]
    for other in passing[1:]:
        ahead = paired(rows, pick, other)["lead"]
        if (cast(float, synth[other]["outcome_accuracy"]) - cast(float, synth[pick]["outcome_accuracy"]) >= margin
                and ahead is not None and cast(float, ahead) >= margin):
            pick = other
    return pick


def trained_runs(pairs: list[str]) -> dict[str, JsonObject]:
    """name=<train_sft --out> pairs, read as {name: summary.json}."""
    out: dict[str, JsonObject] = {}
    for pair in pairs:
        name, _, folder = pair.partition("=")
        out[name] = cast(JsonObject, json.loads((Path(folder) / "summary.json").read_text(encoding="utf-8")))
    return out


def binding_problem(real_targets: dict[str, str], synth_targets: dict[str, str], baseline: str,
                    baseline_model: str, names: list[str], trained: dict[str, JsonObject], pin: str) -> str | None:
    """Why the two runs cannot be judged together, or None. Each name must send the same model in
    both runs, and each candidate must be the checkpoint its training run saved under `pin`."""
    if synth_targets != real_targets:
        return f"the runs sent different models: real {real_targets}, synth {synth_targets}"
    if set(real_targets) != {baseline, *names}:
        # Another target's off-label drops could take memories out of the candidates' scoring.
        return f"the runs sent {sorted(real_targets)}; the pass lines name {baseline} and {names} only"
    if real_targets.get(baseline) != baseline_model:
        return f"the runs have no {baseline}={baseline_model} target"
    for name in names:
        run_ = trained.get(name)
        if run_ is None:
            return f"no --train {name}=<dir>: {name} cannot be tied to the run that trained it"
        if (run_.get("branch"), run_.get("pass_lines_sha256"), run_.get("sampler_path")) != (
                name, pin, real_targets.get(name)):
            return f"{name}={real_targets.get(name)} is not the checkpoint branch {name} saved under these pass lines"
    return None


def verdict(args: argparse.Namespace) -> int:
    lines = load_pass_lines()
    real_dir, synth_dir = Path(cast(str, args.real)), Path(cast(str, args.synth))
    pin = sha256_file(PASS_LINES)
    real = cast(JsonObject, json.loads((real_dir / "summary.json").read_text(encoding="utf-8")))
    synth = cast(JsonObject, json.loads((synth_dir / "summary.json").read_text(encoding="utf-8")))
    if {real["pass_lines_sha256"], synth["pass_lines_sha256"]} != {pin}:
        raise SystemExit("a run used other pass lines")
    gates, comparison = cast(JsonObject, lines["gates"]), cast(JsonObject, lines["comparison"])
    choice = cast(JsonObject, lines["choice"])
    base, names = cast(str, comparison["baseline"]), cast(list[str], choice["order"])
    problem = binding_problem(cast(dict[str, str], real["targets"]), cast(dict[str, str], synth["targets"]),
                              base, cast(str, comparison["baseline_model"]), names,
                              trained_runs(cast(list[str], args.train)), pin)
    if problem is not None:
        raise SystemExit(problem)
    rows, synth_rows = read_rows(real_dir), read_rows(synth_dir)
    # Recomputed from the rows, so an edited or stale summary.json cannot pass a gate.
    r_all = cast(dict[str, JsonObject], summarize("real", rows))
    expected = {"real": cast(JsonObject, lines["e_real"])["items"], "synth": cast(JsonObject, lines["e_synth"])["items"]}
    for kind, part in (("real", r_all), ("synth", cast(dict[str, JsonObject], summarize("synth", synth_rows)))):
        counts = {n: t["items"] for n, t in part.items()}
        if any(counts.get(n) != expected[kind] for n in [base, *names]):
            raise SystemExit(f"the {kind} run has not answered every item for every target: {counts}")
    drops = D.off_label(synth_rows)
    if drops and args.drops is None:
        raise SystemExit(f"{sum(len(m) for m in drops.values())} off-label E-synth drops need the blind judge: "
                         "run e_synth_audit.py drops, then pass its --out as --drops")
    judged = D.read_adjudication(Path(cast(str, args.drops)), drops, synth_render.TEMPLATE) if drops else D.NO_DROPS
    scored = judged.scored(synth_rows)
    if not scored:
        raise SystemExit("the judge's drops leave no E-synth request to score")
    s_all = cast(dict[str, JsonObject], summarize("synth", scored, judged.wrong_outside()))
    window = cast(float, comparison["same_item_window_s"])
    result: JsonObject = {}
    warm_min = cast(float, comparison["warm_share_min"])
    for name in names:
        gap = widest_gap_s(rows, base, name)
        if gap is None or gap > window:
            raise SystemExit(f"{name} and {base} calls did not leave together: widest gap {gap} s, limit {window} s")
        for who in (base, name):
            share = cast(float, r_all[who]["warm_share"])
            if share < warm_min:
                raise SystemExit(f"{share:.2f} of {who}'s E-real calls met a warm cache, {warm_min} needed: "
                                 "G5 would compare unlike cache states")
        r, s, rb = r_all[name], s_all[name], r_all[base]
        pair = paired(rows, base, name)
        lead, p50, b50 = pair["lead"], r["latency_p50_s"], rb["latency_p50_s"]
        checks = {
            "G1": cast(float, r["valid_rate"]) >= cast(float, gates["G1_e_real_valid_rate_min"]),
            "G2": cast(int, r["dropped_not_in_live"]) <= cast(int, gates["G2_e_real_dropped_not_in_live_max"]),
            "G3": (cast(float, s["outcome_accuracy"]) >= cast(float, gates["G3_e_synth_outcome_accuracy_min"])
                   and cast(float, s["drop_precision"]) >= cast(float, gates["G3_e_synth_drop_precision_min"])
                   and cast(float, s["stale_drop_recall"]) >= cast(float, gates["G3_e_synth_stale_drop_recall_min"])),
            "G4": lead is not None and cast(float, lead) >= cast(float, gates["G4_e_real_paired_lead_min"]),
            "G5": (p50 is not None and b50 is not None
                   and cast(float, p50) <= cast(float, b50) * cast(float, gates["G5_e_real_latency_p50_ratio_max"])),
        }
        result[name] = {"pass": all(checks.values()), **checks, "paired": pair, "widest_gap_s": round(gap, 1)}
    result["e_synth_drops"] = judged.record(len({r["item"] for r in scored}))
    result["choice"] = choose(names, result, s_all, rows, cast(float, choice["prefer_later_when_ahead_by"]))
    print(json.dumps(result))
    (real_dir / "verdict.json").write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--set", choices=["real", "synth"], required=True)
    r.add_argument("--target", action="append", required=True, help="name=model, sent in this order")
    r.add_argument("--requests", help="E-synth requests.jsonl (for --set synth)")
    r.add_argument("--base", default=None, help="MASC base path (default: MASC_BASE_PATH)")
    r.add_argument("--out", required=True)
    r.add_argument("--budget", type=float, required=True)
    v = sub.add_parser("verdict")
    v.add_argument("--real", required=True)
    v.add_argument("--synth", required=True)
    v.add_argument("--drops", default=None,
                   help="e_synth_audit.py drops --out, with the judge's judge/decisions.jsonl; needed when an "
                        "answer dropped a fact off label")
    v.add_argument("--train", action="append", required=True, help="name=<train_sft --out>, one per candidate")
    args = ap.parse_args()
    return run(args) if args.command == "run" else verdict(args)


if __name__ == "__main__":
    sys.exit(main())
