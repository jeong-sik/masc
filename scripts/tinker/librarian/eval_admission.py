# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Measure models on the keeper-librarian admission evaluation sets.

    MASC_BASE_PATH=artifacts/tinker/librarian/e-real-snapshot \
        uv run scripts/tinker/librarian/eval_admission.py run --set real \
        --target base=thinkingmachines/Inkling-2-Small:peft:262144 --target A=tinker://... \
        --out artifacts/tinker/librarian/eval-<name>-real --budget 6
    uv run scripts/tinker/librarian/eval_admission.py run --set synth --requests <requests.jsonl> ...
    uv run scripts/tinker/librarian/eval_admission.py run --provider glm --target glm=<model> \
        --set synth --requests <requests.jsonl> --out <dir> --max-calls 300
    uv run scripts/tinker/librarian/eval_admission.py verdict --real <dir> --synth <dir> \
        --drops <e_synth_audit.py drops --out> --merges <merge_cases.py --out> \
        --train A=artifacts/tinker/librarian/train-A
    uv run scripts/tinker/librarian/eval_admission.py synth-numbers --synth <dir> \
        --drops <e_synth_audit.py drops --out> --merges <merge_cases.py --out>
    uv run scripts/tinker/librarian/eval_admission.py rescore --run <dir> --out <new dir> \
        [--requests <requests.jsonl>] [--base <dir>] [--template <librarian.md>]

`pass_lines.json` fixes the request, the sets, the baseline, the candidates and
the gates. `run` refuses to start when a file it pins has changed. Each item
goes to every target back to back in --target order, so the targets meet the
endpoint under the same load. A verdict run starts from an empty --out: its
baseline calls must leave next to the candidates' calls, which a call log from
an earlier run cannot show. The request is the one MASC's exact lane sends: the
admission prompt, then the schema instruction as the last user message.

Every prompt goes out drawn with the pinned template. An E-real record holds
the prompt text MASC sent, drawn with the librarian.md of that day, so it is
read with that file (`e_real.template` of the pass lines) and drawn again from
the same data. An E-synth prompt is drawn from its request.
`run --template <librarian.md>` draws every prompt with that file's template
instead. A prompt's retirement evidence goes out under the retirement policy
of the template it is drawn with, and a template without one cannot draw it,
as in MASC. The summary records the sha256 of the template the prompts were
drawn with, and `verdict` refuses a run drawn with another template than the
pinned one.

`run --provider glm` sends the same messages to Z.AI's GLM coding endpoint in
the request MASC's GLM slot sends (`glm_chat`), with the pass lines'
`max_tokens`, so a prompt change can be measured on that model too. It sends no
warm call, `--max-calls` caps its requests in place of `--budget`, and its rows
cost nothing per token: the calls draw on the key's usage quota. It waits on one
request at a time, since the key's rate limit also counts the live Keepers'
requests. The summary names the provider of the run.

`rescore` scores a finished run again under the current pass lines and sends no
call. It serves a change of the pass lines that leaves every prompt and the
request as they were, such as a change of the checker or of the scores. Each row
is made again from the call the old row names in the run's call log (its key and
send time): the call's numbers as logged, the answer checked and scored now, and
the cost the old row recorded. A call whose key is not the one the current pass
lines give the item's prompt stops it, so a changed request, set or template
cannot be scored this way: the model runs again. <out> must not exist. It gets
the run's call log byte for byte, new rows and a summary that names the run it
was scored from; the run's spending and stop stay as they were.

Definitions:
- valid: HTTP 200 with no provider error, finish_reason "stop", and
  `admission_validator.validate` accepts the content against the prompt, as
  MASC would.
- E-real valid rate in reach (G1): valid answers over the E-real items the
  baseline's endpoint did not refuse outright. A request the endpoint answers
  with HTTP 400 is past what the base model accepts, such as its context, so no
  weights trained on that model answer it. `verdict` lists those items as
  `e_real_refused` and leaves them out of every target's rate. An answer cut
  off at `max_tokens` stays in: the slot spent its time on it.
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
  `verdict` lists each candidate's IDs by item, to be read before an install:
  the count does not tell a lost memory from a stale one the live answer kept.
- E-real absorbed_not_in_live: memory IDs a valid answer absorbs that the live
  answer keeps. Listed for human review with G2's IDs, not gated: absorbing
  merges a fact into a new claim, which MASC's absorb gate checks at commit.
- E-synth memory-state accuracy (G3): candidates whose memory the answer leaves
  as their label kind needs (`memory_scores`), over every candidate (an answer
  that is not valid is wrong), also per kind.
- E-synth outcome accuracy: candidates whose outcome equals the label and whose
  `memory_claim` points where the label's kind needs it, over every candidate
  (an answer that is not valid is wrong). A new fact or a complement names a
  claim the answer adds that is not another candidate's text; a paraphrase
  names the existing claim it restates; a correction names such a claim that
  supersedes the label's target, and the target is dropped. Reported, not
  gated.
- E-synth drop precision (G3): dropped IDs that are planted stale facts or label
  correction targets, over all dropped IDs of valid answers (none with no drop,
  which fails G3).
  A dropped complement target or duplicate fact counts against it, since the
  label absorbs those (`dropped_unmerged`). Any other dropped ID is an off-label
  drop. Rows list them, and `verdict` needs a blind judge's class for each one
  (`audit_decisions`): unless the judge keeps the fact, no target is scored on
  that memory's requests. A drop the judge keeps or finds restating
  another fact stays wrong, also when its memory leaves scoring, and so does a
  dropped complement target or duplicate fact.
- E-synth absorbed: memory IDs valid answers absorb, each with what the label
  says of that fact.
- E-synth merge recall: complement targets absorbed into the complement's claim
  and duplicate pairs left as one fact, over the merges the labels expect.
- E-synth absorb precision and judged merge recall (G6): `verdict` asks a
  blind judge what MASC's absorb gate asks of every absorb, in the gate's words
  (`merge_cases.py`, `merge_decisions`). Absorb precision is absorbs judged
  mergeable over all absorbs; a run with no absorb has none and fails G6.
  Judged merge recall counts a merge the label expects only when every absorb
  it made is judged mergeable; a run with no expected merge has none and fails
  G6.
- E-synth stale drop recall (G3): planted stale facts dropped, over the planted
  stale facts the labels expect to leave (none when they expect none, which
  fails G3). An absorbed stale fact is not dropped: its text lives on in the
  new claim. Labels expect merges and stale drops on every request, whatever
  the candidates (RFC-0517 §7.1).
- Growth: claims an answer adds minus the memory IDs it takes out, per item,
  beside the labels' (E-synth) or the live answers' (E-real).
- latency p50 (G5): median wall time of E-real calls that returned HTTP 200.
  Every target first gets each prompt with WARM_MAX_TOKENS, so the measured
  calls all read a cached prefix. `verdict` refuses when fewer than
  `warm_share_min` of a target's calls did. `tinker_oai` retries a transient
  failure itself and logs every attempt, so wall_s is one attempt. A call that
  still failed is an answer that is not valid, and `http_errors` counts them.
- `verdict` recomputes every number from rows.jsonl. It refuses unless both runs
  sent the same model under each name, and each candidate is the sampler_path
  `train_sft.py` saved for it under these pass lines. It also refuses while
  pass_lines.json sets no finite number for a gate, sets a gate it does not
  read, or holds another `choice` key than `order`. The choice is the first
  candidate in `choice.order` that passes every gate.
- `synth-numbers` prints each target's E-synth numbers as `verdict` computes
  them, with the drop and merge judges' classes. It reads no gate, choice or
  trained run, so the baseline's numbers can set a gate's line before any
  training.

Output: <out>/calls.jsonl holds raw answers (E-real answers carry Keeper memory;
keep them local), <out>/rows.jsonl numbers, IDs and verdicts, each row naming
the call it scores by its key and send time, <out>/summary.json.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import statistics
import sys
from collections import Counter
from collections.abc import Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Literal, assert_never, cast

import admission_request as R
import admission_validator as AV
import audit_decisions as D
import exact_store as E
import glm_chat as G
import memory_scores as M
import merge_decisions as MD
import synth_render
import synth_rows as RW
import yojson_wire as Y
from tinker_oai import HTTP_OK, Call, Caller, call_from_row, call_key

HERE = Path(__file__).resolve().parent
PASS_LINES = HERE / "pass_lines.json"
TINKER_IN_FLIGHT = 4
# The GLM key is the live Keepers' account. On 11-10 a run waiting on four GLM requests
# at once met the rate limit (1302), and a live Keeper's turn failed on it in the same minute.
GLM_IN_FLIGHT = 1
# Tinker keeps a prompt's prefix cached for at least half an hour (11-08: a rerun of the
# E-real prompts read 100% of their tokens from cache), and a LoRA checkpoint has its own
# cache. Before the measured calls of an item, every target gets the same prompt with this
# output budget, so every measured call meets a warm cache whatever ran earlier.
WARM_MAX_TOKENS = 1
# A measured call counts as warm when this share of its prompt tokens came from cache.
WARM_CACHED_SHARE = 0.9
# The endpoint's status for a request it will not take, such as one past the model's context.
HTTP_BAD_REQUEST = 400
# exact_output_ready_admission.ml domain_schema_instruction_text, verbatim.
INSTRUCTION = ("Return exactly one JSON value matching this JSON Schema. Do not use Markdown "
               "code fences or include any explanation. JSON Schema: %s")

type JsonObject = dict[str, object]
# The providers `run` sends to, as a run's summary names them (`spending`).
type Provider = Literal["tinker", "glm"]


type Item = M.RealItem | M.SynthItem


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


def e_real_files(lines: JsonObject) -> tuple[Path, Path]:
    """The E-real manifest and the librarian.md its records were drawn with, as the pass lines
    pin them. SystemExit when either file holds other bytes."""
    real = cast(JsonObject, lines["e_real"])
    manifest, recorded = HERE / cast(str, real["manifest"]), HERE / cast(str, real["template"])
    if sha256_file(manifest) != real["manifest_sha256"]:
        raise SystemExit("the E-real manifest differs from pass_lines.json")
    if sha256_file(recorded) != real["template_sha256"]:
        raise SystemExit("the E-real template differs from pass_lines.json")
    return manifest, recorded


def real_items(manifest: Path, recorded: Path, base: Path) -> list[M.RealItem]:
    """E-real items, each prompt read with `recorded`, the librarian.md its record was drawn
    with. A prompt that template cannot read, or a live answer the checker refuses, stops the
    run: the checker would then not be MASC's."""
    template = synth_render.template_at(recorded)
    items: list[M.RealItem] = []
    for record in E.records_for(manifest, base):
        prompt = R.parse(record.prompt, template)
        if isinstance(prompt, R.ParseError):
            raise SystemExit(f"{record.digest[:16]}: prompt does not parse: {prompt.detail}")
        live = check(prompt, Y.write(record.answer))
        if live.answer is None:
            raise SystemExit(f"{record.digest[:16]}: the live answer is refused: {live.problems}")
        items.append(M.RealItem(record.digest[:16], prompt, record.prompt, live.answer))
    return items


def synth_items(path: Path) -> list[M.SynthItem]:
    """Rendered synthetic requests with their labels (`synth_rows.label_of_row`), from synth_generate.py
    output. SystemExit on a request the generator cannot write, such as one an earlier generator wrote."""
    items: list[M.SynthItem] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        row = cast(JsonObject, json.loads(line))
        request = cast(JsonObject, row["request"])
        label = RW.label_of_row(request)
        if label is None:
            raise SystemExit(f"{path}:{number}: the request is not one synth_generate.py writes")
        prompt = synth_render.prompt_of(request)
        items.append(M.SynthItem(cast(str, request["item_id"]), prompt, R.render(prompt), label))
    return items


def retemplated(item: Item, template: R.AdmissionTemplate) -> Item:
    """The item with its prompt drawn with `template` from the same data, its retirement evidence
    under the template's retirement policy. SystemExit when the template has no policy for the
    evidence: MASC refuses that admission (keeper_librarian_runtime.ml `admission_suffix`)."""
    retirement = item.prompt.retirement
    if retirement is not None:
        if template.retirement_policy is None:
            raise SystemExit(f"{item.item_id}: the template has no retirement policy for the prompt's evidence")
        retirement = replace(retirement, policy=template.retirement_policy)
    prompt = replace(item.prompt, template=template, retirement=retirement)
    return replace(item, prompt=prompt, text=R.render(prompt))


def drawn_with(template: Path | None, items: list[Item]) -> tuple[Path, list[Item]]:
    """The template file the prompts go out in, the pinned one or the file `template` names, and
    each item drawn with it. An E-real item was read with the template of its record, so the
    pinned template draws it again too."""
    path = synth_render.TEMPLATE if template is None else template
    drawn = synth_render.template_at(path)
    return path, [retemplated(i, drawn) for i in items]


@dataclass(frozen=True, slots=True)
class TinkerLane:
    """Tinker's endpoint: the pass lines' effort and output budget, a warm call first, a price per token."""

    caller: Caller
    effort: str
    max_tokens: int


@dataclass(frozen=True, slots=True)
class GlmLane:
    """GLM's coding endpoint in MASC's request (`glm_chat`): the pass lines' output budget, no warm
    call, no price per token."""

    caller: G.Caller
    max_tokens: int


type Lane = TinkerLane | GlmLane


def measured(lane: Lane, model: str, label: str, messages: list[str]) -> tuple[Call, float] | None:
    """The measured call and what it cost in USD, or None once the lane stops."""
    match lane:
        case TinkerLane(caller=caller, effort=effort, max_tokens=max_tokens):
            call = caller.ask(model=model, label=label, messages=messages, effort=effort, max_tokens=max_tokens)
            return (call, round(call.cost(), 6)) if call is not None else None
        case GlmLane(caller=caller, max_tokens=max_tokens):
            call = caller.ask(model=model, label=label, messages=messages, max_tokens=max_tokens)
            return (call, 0.0) if call is not None else None
        case _:
            assert_never(lane)


def in_flight(lane: Lane) -> int:
    """Requests the run waits on at once."""
    match lane:
        case TinkerLane():
            return TINKER_IN_FLIGHT
        case GlmLane():
            return GLM_IN_FLIGHT
        case _:
            assert_never(lane)


def spending(lane: Lane) -> JsonObject:
    match lane:
        case TinkerLane(caller=caller):
            return {"provider": "tinker", "spent_usd": round(caller.spent, 4)}
        case GlmLane(caller=caller):
            return {"provider": "glm", "requests_sent": caller.sent}
        case _:
            assert_never(lane)


def run_item(lane: Lane, targets: list[tuple[str, str]], item: Item) -> list[JsonObject]:
    kind = "real" if isinstance(item, M.RealItem) else "synth"
    messages = [item.text, schema_instruction()]
    match lane:
        case TinkerLane(caller=caller, effort=effort):
            for name, model in targets:
                if caller.ask(model=model, label=f"{kind}:{name}:{item.item_id}:warm", messages=messages,
                              effort=effort, max_tokens=WARM_MAX_TOKENS) is None:
                    return []
        case GlmLane():
            pass
        case _:
            assert_never(lane)
    rows: list[JsonObject] = []
    for name, model in targets:
        got = measured(lane, model, f"{kind}:{name}:{item.item_id}", messages)
        if got is None:
            break
        call, cost = got
        rows.append(scored_row(item, name, call, cost))
    return rows


def scored_row(item: Item, name: str, call: Call, cost: float) -> JsonObject:
    """The row of the call the target `name` answered `item` with: the call's numbers, what it
    cost, and the answer checked and scored."""
    result = check(item.prompt, call.answer())
    match item:
        case M.RealItem():
            kind, score = "real", M.score_real(item, result.answer)
        case M.SynthItem():
            kind, score = "synth", M.score_synth(item, result.answer)
    return {"set": kind, "item": item.item_id, "target": name, "call_key": call.key,
            "status": call.status, "error": call.error, "finish": call.finish,
            "sent_at": call.sent_at, "wall_s": call.wall_s, "prompt_tokens": call.prompt_tokens,
            "cached_tokens": call.cached_tokens,
            "completion_tokens": call.completion_tokens, "reasoning_chars": len(call.reasoning or ""),
            "cost_usd": cost, "valid": result.answer is not None,
            "problems": list(result.problems), **score}


def warm(row: JsonObject) -> bool:
    return cast(int, row["cached_tokens"]) >= WARM_CACHED_SHARE * max(1, cast(int, row["prompt_tokens"]))


def by_kind(rows: list[JsonObject]) -> JsonObject:
    """Memory-state accuracy per label kind, over the rows' candidates of that kind."""
    totals: dict[str, tuple[int, int]] = {}
    for r in rows:
        for kind, (n, ok) in cast(dict[str, list[int]], r["state_by_kind"]).items():
            before = totals.get(kind, (0, 0))
            totals[kind] = (before[0] + n, before[1] + ok)
    return {kind: {"candidates": n, "accuracy": ok / n} for kind, (n, ok) in sorted(totals.items())}


def summarize(kind: str, rows: list[JsonObject], wrong_elsewhere: dict[str, int] | None = None) -> JsonObject:
    """Per target numbers of a set. `wrong_elsewhere` adds, per target, E-synth drops that are
    wrong but sit on rows left out of scoring (`audit_decisions.Adjudication.wrong_outside`)."""
    out: JsonObject = {}
    for name in dict.fromkeys(cast(str, r["target"]) for r in rows):
        mine = [r for r in rows if r["target"] == name]
        ok = [cast(float, r["wall_s"]) for r in mine if r["status"] == HTTP_OK and r.get("error") is None]
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
            part["net_per_item"] = (sum(cast(int, r["added"]) for r in mine)
                                    - sum(cast(int, r["removed"]) for r in mine)) / len(mine)
            part["live_net_per_item"] = (sum(cast(int, r["live_added"]) for r in mine)
                                         - sum(cast(int, r["live_removed"]) for r in mine)) / len(mine)
        else:
            drops = sum(cast(int, r["dropped"]) for r in mine) + (wrong_elsewhere or {}).get(name, 0)
            part["outcome_accuracy"] = sum(cast(int, r["correct"]) for r in mine) / cands
            part["drop_precision"] = sum(cast(int, r["dropped_expected"]) for r in mine) / drops if drops else None
            part["absorbed"] = sum(cast(int, r["absorbed"]) for r in mine)
            planted = sum(cast(int, r["planted"]) for r in mine)
            part["stale_drop_recall"] = (sum(cast(int, r["planted_dropped"]) for r in mine) / planted
                                         if planted else None)
            part["memory_state_accuracy"] = sum(cast(int, r["state_correct"]) for r in mine) / cands
            part["state_by_kind"] = by_kind(mine)
            part["dropped_unmerged"] = sum(len(cast(list[str], r["dropped_unmerged"])) for r in mine)
            part["planted_absorbed"] = sum(cast(int, r["planted_absorbed"]) for r in mine)
            ahead = sum(cast(int, r["scheduled_ahead"]) for r in mine)
            part["scheduled_ahead_keep_rate"] = (
                1 - sum(cast(int, r["scheduled_ahead_dropped"]) for r in mine) / ahead if ahead else None)
            past = sum(cast(int, r["scheduled_past"]) for r in mine)
            part["scheduled_past_drop_recall"] = (
                sum(cast(int, r["scheduled_past_dropped"]) for r in mine) / past if past else None)
            merges = sum(cast(int, r["merges"]) for r in mine)
            part["merge_recall"] = sum(cast(int, r["merges_done"]) for r in mine) / merges if merges else None
            part["net_per_item"] = (sum(cast(int, r["added"]) for r in mine)
                                    - sum(cast(int, r["removed"]) for r in mine)) / len(mine)
            part["expected_net_per_item"] = (sum(cast(int, r["expected_added"]) for r in mine)
                                             - sum(cast(int, r["expected_removed"]) for r in mine)) / len(mine)
        out[name] = part
    return out


def run_summary(kind: str, template: Path, targets: list[tuple[str, str]], lane: Lane,
                rows: list[JsonObject]) -> JsonObject:
    """summary.json of a run: the pins and the template file it went out under, the lane's spending
    and stop, and the numbers per target."""
    return {"set": kind, "pass_lines_sha256": sha256_file(PASS_LINES), "template_sha256": sha256_file(template),
            "targets": dict(targets), **spending(lane), "stopped": lane.caller.stopped,
            "by_target": summarize(kind, rows)}


def lane_of(args: argparse.Namespace, log: Path, request: JsonObject) -> Lane:
    """The lane --provider names, with its limit: --budget on Tinker, --max-calls on GLM."""
    budget, max_calls = cast(float | None, args.budget), cast(int | None, args.max_calls)
    match cast(str, args.provider), budget, max_calls:
        case "tinker", float(), None:
            return TinkerLane(Caller(log, budget), cast(str, request["reasoning_effort"]),
                              cast(int, request["max_tokens"]))
        case "glm", None, int():
            return GlmLane(G.Caller(log, max_calls), cast(int, request["max_tokens"]))
        case _:
            raise SystemExit("--provider tinker needs --budget alone, --provider glm needs --max-calls alone")


def set_items(lines: JsonObject, kind: str, args: argparse.Namespace) -> tuple[Path, list[Item]]:
    """The template file the prompts go out in and the items of the pinned set `kind` drawn with it
    (`drawn_with`): E-real from --base, E-synth from --requests, which must be the pinned file."""
    items: list[Item]
    if kind == "real":
        manifest, recorded = e_real_files(lines)
        items = list(real_items(manifest, recorded, E.base_path(cast(str | None, args.base))))
    else:
        requests = Path(cast(str, args.requests))
        if sha256_file(requests) != cast(JsonObject, lines["e_synth"])["requests_sha256"]:
            raise SystemExit("the E-synth requests differ from pass_lines.json")
        items = list(synth_items(requests))
    return drawn_with(None if args.template is None else Path(cast(str, args.template)), items)


def run(args: argparse.Namespace) -> int:
    lines = load_pass_lines()
    kind, out = cast(str, args.set), Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    lane = lane_of(args, out / "calls.jsonl", cast(JsonObject, lines["request"]))
    targets = [cast(tuple[str, str], tuple(t.split("=", 1))) for t in cast(list[str], args.target)]
    template, items = set_items(lines, kind, args)

    def one(item: Item) -> list[JsonObject]:
        return run_item(lane, targets, item)

    with ThreadPoolExecutor(max_workers=in_flight(lane)) as pool:
        rows = [r for rs in pool.map(one, items) for r in rs]
    with (out / "rows.jsonl").open("w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    summary = run_summary(kind, template, targets, lane, rows)
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary["by_target"]))
    return 2 if lane.caller.stopped is not None else 0


def provider_of(summary: JsonObject) -> Provider:
    match summary["provider"]:
        case "tinker":
            return "tinker"
        case "glm":
            return "glm"
        case other:
            raise SystemExit(f"a run on {other!r} is not one `run` makes")


def logged_key(provider: Provider, model: str, request: JsonObject, messages: list[str]) -> str:
    """The key the provider's caller logs a measured call of `model` under, for these messages and
    the pass lines' request."""
    max_tokens = cast(int, request["max_tokens"])
    match provider:
        case "tinker":
            return call_key(model, cast(str, request["reasoning_effort"]), max_tokens, 0, messages)
        case "glm":
            return G.call_key(G.request_body(model, messages, max_tokens))
        case _:
            assert_never(provider)


def logged_spending(provider: Provider, summary: JsonObject) -> JsonObject:
    """What the run spent, as its summary records it (`spending`)."""
    match provider:
        case "tinker":
            return {"provider": provider, "spent_usd": summary["spent_usd"]}
        case "glm":
            return {"provider": provider, "requests_sent": summary["requests_sent"]}
        case _:
            assert_never(provider)


def rescore(args: argparse.Namespace) -> int:
    lines = load_pass_lines()
    source, out = Path(cast(str, args.run)), Path(cast(str, args.out))
    if out.exists():
        raise SystemExit(f"{out} exists: rescore writes a new folder")
    old = cast(JsonObject, json.loads((source / "summary.json").read_text(encoding="utf-8")))
    kind, provider, targets = cast(str, old["set"]), provider_of(old), cast(dict[str, str], old["targets"])
    template, items = set_items(lines, kind, args)
    if sha256_file(template) != old["template_sha256"]:
        raise SystemExit(f"{source} drew its prompts with another template than {template}")
    by_item = {item.item_id: item for item in items}
    log = (source / "calls.jsonl").read_text(encoding="utf-8").splitlines()
    calls = (call_from_row(json.loads(line)) for line in log)
    # A call logged without its send time cannot be told from the other attempts under its key.
    logged: dict[tuple[str, float | None], Call] = {(c.key, c.sent_at): c for c in calls
                                                    if c is not None and c.sent_at is not None}
    request = cast(JsonObject, lines["request"])
    rows: list[JsonObject] = []
    for number, row in enumerate(read_rows(source), start=1):
        name = cast(str, row["target"])
        item, model = by_item.get(cast(str, row["item"])), targets.get(name)
        if item is None or model is None:
            raise SystemExit(f"{source}/rows.jsonl:{number} names an item or a target the run does not hold")
        key = logged_key(provider, model, request, [item.text, schema_instruction()])
        call = logged.get((key, cast(float | None, row["sent_at"])))
        if row["call_key"] != key or call is None:
            raise SystemExit(f"{source}/rows.jsonl:{number}: the call log holds no call sent when the row says "
                             "under the key the current pass lines give the item's prompt")
        rows.append(scored_row(item, name, call, cast(float, row["cost_usd"])))
    out.mkdir(parents=True)
    shutil.copyfile(source / "calls.jsonl", out / "calls.jsonl")
    with (out / "rows.jsonl").open("w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    summary = {"set": kind, "pass_lines_sha256": sha256_file(PASS_LINES), "template_sha256": old["template_sha256"],
               "targets": targets, **logged_spending(provider, old), "stopped": old["stopped"],
               "rescored_from": {"run": str(source), "pass_lines_sha256": old["pass_lines_sha256"],
                                 "rows_sha256": sha256_file(source / "rows.jsonl"),
                                 "calls_sha256": sha256_file(source / "calls.jsonl")},
               "by_target": summarize(kind, rows)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(summary["by_target"]))
    return 0


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


@dataclass(frozen=True, slots=True)
class Gates:
    """pass_lines.json `gates`."""

    g1_e_real_valid_rate_min: float
    g2_e_real_dropped_not_in_live_max: float
    g3_e_synth_memory_state_accuracy_min: float
    g3_e_synth_drop_precision_min: float
    g3_e_synth_stale_drop_recall_min: float
    g4_e_real_paired_lead_min: float
    g5_e_real_latency_p50_ratio_max: float
    g6_e_synth_absorb_precision_min: float
    g6_e_synth_judged_merge_recall_min: float


def gates_of(raw: JsonObject) -> Gates:
    """The gates. SystemExit when pass_lines.json sets no finite number for one, or sets one the verdict
    does not read: a gate left over from earlier pass lines would look applied and be ignored."""
    read: list[str] = []

    def number(key: str) -> float:
        read.append(key)
        value = raw.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise SystemExit(f"pass_lines.json sets no finite number for {key}")
        return float(value)

    gates = Gates(
        g1_e_real_valid_rate_min=number("G1_e_real_valid_rate_min"),
        g2_e_real_dropped_not_in_live_max=number("G2_e_real_dropped_not_in_live_max"),
        g3_e_synth_memory_state_accuracy_min=number("G3_e_synth_memory_state_accuracy_min"),
        g3_e_synth_drop_precision_min=number("G3_e_synth_drop_precision_min"),
        g3_e_synth_stale_drop_recall_min=number("G3_e_synth_stale_drop_recall_min"),
        g4_e_real_paired_lead_min=number("G4_e_real_paired_lead_min"),
        g5_e_real_latency_p50_ratio_max=number("G5_e_real_latency_p50_ratio_max"),
        g6_e_synth_absorb_precision_min=number("G6_e_synth_absorb_precision_min"),
        g6_e_synth_judged_merge_recall_min=number("G6_e_synth_judged_merge_recall_min"))
    unread = sorted(set(raw) - set(read))
    if unread:
        raise SystemExit(f"pass_lines.json sets gates the verdict does not read: {', '.join(unread)}")
    return gates


def choice_of(raw: JsonObject) -> list[str]:
    """pass_lines.json `choice.order`: the candidates, in the order the verdict prefers them. SystemExit
    for another key, which would look applied and be ignored, and for an order that names no candidate."""
    order = raw.get("order")
    names = cast(list[object], order) if isinstance(order, list) else []
    if set(raw) != {"order"} or not names or not all(isinstance(n, str) for n in names):
        raise SystemExit("pass_lines.json choice holds `order` alone, a list of candidate names")
    return [cast(str, n) for n in names]


def ready_to_train(lines: JsonObject, candidate: str) -> Gates:
    """The gates `candidate` trains toward. SystemExit while a gate has no number or `choice.order` does
    not name the candidate: no weights change before the verdict can judge them."""
    gates = gates_of(cast(JsonObject, lines["gates"]))
    if candidate not in choice_of(cast(JsonObject, lines["choice"])):
        raise SystemExit(f"pass_lines.json choice.order does not name {candidate}")
    return gates


def at_least(value: object, line: float) -> bool:
    """Whether a number reaches its line. A number with nothing to count over (None) reaches none."""
    return value is not None and cast(float, value) >= line


def real_numbers(rows: list[JsonObject], base: str) -> tuple[dict[str, JsonObject], list[str]]:
    """Each target's E-real numbers (`summarize`) with `valid_rate_in_reach`, and the items left out of
    that rate: the ones `base`'s endpoint refused outright (HTTP 400). Such a request is past what the
    base model accepts, so no weights trained on it answer it. The rate is the target's valid answers
    over the other items, None when there is no other item."""
    refused = {cast(str, r["item"]) for r in rows if r["target"] == base and r["status"] == HTTP_BAD_REQUEST}
    numbers = cast(dict[str, JsonObject], summarize("real", rows))
    for name, part in numbers.items():
        reach = [bool(r["valid"]) for r in rows if r["target"] == name and r["item"] not in refused]
        part["valid_rate_in_reach"] = sum(reach) / len(reach) if reach else None
    return numbers, sorted(refused)


def off_live_drops(rows: list[JsonObject], name: str) -> dict[str, list[str]]:
    """The memory IDs `name` dropped that the live answer keeps, by E-real item: the IDs G2 counts."""
    return {cast(str, r["item"]): cast(list[str], r["dropped_not_in_live"]) for r in rows
            if r["target"] == name and r["dropped_not_in_live"]}


def gate_checks(gates: Gates, real: JsonObject, synth: JsonObject, merges: JsonObject, pair: JsonObject,
                baseline_real: JsonObject) -> dict[str, bool]:
    """Each gate for one candidate: its E-real numbers (`real_numbers`), its E-synth numbers
    (`summarize`), its merge numbers (`merge_decisions.MergeAdjudication.numbers`), its pairing with
    the baseline (`paired`) and the baseline's E-real numbers."""
    p50, b50 = real["latency_p50_s"], baseline_real["latency_p50_s"]
    return {
        "G1": at_least(real["valid_rate_in_reach"], gates.g1_e_real_valid_rate_min),
        "G2": cast(int, real["dropped_not_in_live"]) <= gates.g2_e_real_dropped_not_in_live_max,
        "G3": (at_least(synth["memory_state_accuracy"], gates.g3_e_synth_memory_state_accuracy_min)
               and at_least(synth["drop_precision"], gates.g3_e_synth_drop_precision_min)
               and at_least(synth["stale_drop_recall"], gates.g3_e_synth_stale_drop_recall_min)),
        "G4": at_least(pair["lead"], gates.g4_e_real_paired_lead_min),
        "G5": (p50 is not None and b50 is not None
               and cast(float, p50) <= cast(float, b50) * gates.g5_e_real_latency_p50_ratio_max),
        "G6": (at_least(merges["absorb_precision"], gates.g6_e_synth_absorb_precision_min)
               and at_least(merges["judged_merge_recall"], gates.g6_e_synth_judged_merge_recall_min)),
    }


def judged_candidate(gates: Gates, name: str, base: str, real: Mapping[str, JsonObject],
                     synth: Mapping[str, JsonObject], merges: Mapping[str, JsonObject], pair: JsonObject) -> JsonObject:
    """`name`'s gates on its own numbers, G5 against `base`'s E-real latency. It passes when every gate does."""
    checks = gate_checks(gates, real[name], synth[name], merges[name], pair, real[base])
    return {"pass": all(checks.values()), **checks, "paired": pair}


def choose(names: list[str], result: JsonObject) -> str | None:
    """The first candidate in pass_lines order that passes every gate."""
    return next((n for n in names if cast(JsonObject, result[n])["pass"]), None)


def trained_runs(pairs: list[str]) -> dict[str, JsonObject]:
    """name=<train_sft --out> pairs, read as {name: summary.json}."""
    out: dict[str, JsonObject] = {}
    for pair in pairs:
        name, _, folder = pair.partition("=")
        out[name] = cast(JsonObject, json.loads((Path(folder) / "summary.json").read_text(encoding="utf-8")))
    return out


def pinned_problem(summaries: list[JsonObject], pin: str, template: str) -> str | None:
    """Why a run was not made under these pass lines, or with prompts drawn with another template than
    their pinned one; None when every run was."""
    if {s["pass_lines_sha256"] for s in summaries} != {pin}:
        return "a run used other pass lines"
    if {s["template_sha256"] for s in summaries} != {template}:
        return "a run drew its prompts with another template than the pinned one"
    return None


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
        if (run_.get("candidate"), run_.get("pass_lines_sha256"), run_.get("sampler_path")) != (
                name, pin, real_targets.get(name)):
            return f"{name}={real_targets.get(name)} is not the checkpoint {name} saved under these pass lines"
    return None


@dataclass(frozen=True, slots=True)
class SynthMeasure:
    """Each target's E-synth numbers on the rows the drop judge leaves scored, the drop judge's record,
    and the merge judge's report (`merge_decisions.report`)."""

    by_target: dict[str, JsonObject]
    drops: JsonObject
    merges: JsonObject


def measure_synth(synth_dir: Path, items: int, targets: list[str], drops_dir: Path | None,
                  merges_dir: Path | None) -> SynthMeasure:
    """The E-synth numbers of `targets`, recomputed from rows.jsonl, so an edited or stale summary.json
    cannot pass a gate. SystemExit when a target has not answered all `items`, an off-label drop has
    no judge's folder, an absorb has no merge judge's folder, or the judged drops leave nothing to score."""
    synth_rows = read_rows(synth_dir)
    counts = Counter(cast(str, r["target"]) for r in synth_rows)
    if any(counts[n] != items for n in targets):
        raise SystemExit(f"the synth run has not answered every item for every target: {dict(counts)}")
    off = D.off_label(synth_rows)
    if not off:
        judged = D.NO_DROPS
    elif drops_dir is None:
        raise SystemExit(f"{sum(len(m) for m in off.values())} off-label E-synth drops need the blind judge: "
                         "run e_synth_audit.py drops, then pass its --out as --drops")
    else:
        judged = D.read_adjudication(drops_dir, off, synth_render.TEMPLATE)
    scored = judged.scored(synth_rows)
    if not scored:
        raise SystemExit("the judge's drops leave no E-synth request to score")
    by_target = cast(dict[str, JsonObject], summarize("synth", scored, judged.wrong_outside(synth_rows)))
    merges = MD.report(synth_rows, scored, merges_dir, synth_render.TEMPLATE, synth_dir, targets)
    return SynthMeasure(by_target, judged.record(synth_rows), merges)


def folder(arg: object) -> Path | None:
    return None if arg is None else Path(cast(str, arg))


def verdict(args: argparse.Namespace) -> int:
    lines = load_pass_lines()
    real_dir, synth_dir = Path(cast(str, args.real)), Path(cast(str, args.synth))
    pin = sha256_file(PASS_LINES)
    real = cast(JsonObject, json.loads((real_dir / "summary.json").read_text(encoding="utf-8")))
    synth = cast(JsonObject, json.loads((synth_dir / "summary.json").read_text(encoding="utf-8")))
    pinned = pinned_problem([real, synth], pin, sha256_file(synth_render.TEMPLATE))
    if pinned is not None:
        raise SystemExit(pinned)
    gates, comparison = gates_of(cast(JsonObject, lines["gates"])), cast(JsonObject, lines["comparison"])
    base, names = cast(str, comparison["baseline"]), choice_of(cast(JsonObject, lines["choice"]))
    problem = binding_problem(cast(dict[str, str], real["targets"]), cast(dict[str, str], synth["targets"]),
                              base, cast(str, comparison["baseline_model"]), names,
                              trained_runs(cast(list[str], args.train)), pin)
    if problem is not None:
        raise SystemExit(problem)
    rows = read_rows(real_dir)
    # Recomputed from the rows, so an edited or stale summary.json cannot pass a gate.
    r_all, refused = real_numbers(rows, base)
    counts = {n: t["items"] for n, t in r_all.items()}
    if any(counts.get(n) != cast(JsonObject, lines["e_real"])["items"] for n in [base, *names]):
        raise SystemExit(f"the real run has not answered every item for every target: {counts}")
    measure = measure_synth(synth_dir, cast(int, cast(JsonObject, lines["e_synth"])["items"]), [base, *names],
                            folder(args.drops), folder(args.merges))
    m_all = cast(dict[str, JsonObject], measure.merges["by_target"])
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
        result[name] = {**judged_candidate(gates, name, base, r_all, measure.by_target, m_all,
                                           paired(rows, base, name)),
                        "widest_gap_s": round(gap, 1), "valid_rate_in_reach": r_all[name]["valid_rate_in_reach"],
                        "dropped_not_in_live": off_live_drops(rows, name)}
    result["e_real_refused"] = refused
    result["e_synth_drops"] = measure.drops
    result["e_synth_merges"] = measure.merges
    result["choice"] = choose(names, result)
    print(json.dumps(result))
    (real_dir / "verdict.json").write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    return 0


def synth_numbers(args: argparse.Namespace) -> int:
    """Each target's E-synth numbers as `verdict` computes them, written to <synth>/synth-numbers.json."""
    lines = load_pass_lines()
    synth_dir = Path(cast(str, args.synth))
    summary = cast(JsonObject, json.loads((synth_dir / "summary.json").read_text(encoding="utf-8")))
    if summary["set"] != "synth":
        raise SystemExit(f"{synth_dir} holds no E-synth run")
    pinned = pinned_problem([summary], sha256_file(PASS_LINES), sha256_file(synth_render.TEMPLATE))
    if pinned is not None:
        raise SystemExit(pinned)
    targets = list(cast(dict[str, str], summary["targets"]))
    measure = measure_synth(synth_dir, cast(int, cast(JsonObject, lines["e_synth"])["items"]), targets,
                            folder(args.drops), folder(args.merges))
    m_all = cast(dict[str, JsonObject], measure.merges["by_target"])
    numbers: JsonObject = {n: {**measure.by_target[n], "merges": m_all[n]} for n in targets}
    print(json.dumps(numbers))
    record = {**numbers, "e_synth_drops": measure.drops, "e_synth_merges": measure.merges}
    (synth_dir / "synth-numbers.json").write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")
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
    r.add_argument("--provider", choices=["tinker", "glm"], default="tinker")
    r.add_argument("--budget", type=float, default=None, help="USD, for --provider tinker")
    r.add_argument("--max-calls", type=int, default=None, help="requests under --out, for --provider glm")
    s = sub.add_parser("rescore", help="score a finished run again under these pass lines, sending no call")
    s.add_argument("--run", required=True, help="the run's --out")
    s.add_argument("--out", required=True, help="a new folder")
    s.add_argument("--requests", help="E-synth requests.jsonl (for an E-synth run)")
    s.add_argument("--base", default=None, help="MASC base path (default: MASC_BASE_PATH)")
    for p in (r, s):
        p.add_argument("--template", default=None,
                       help="a librarian.md to draw every prompt with (default: the pinned config/prompts/librarian.md)")
    v = sub.add_parser("verdict")
    v.add_argument("--real", required=True)
    v.add_argument("--train", action="append", required=True, help="name=<train_sft --out>, one per candidate")
    n = sub.add_parser("synth-numbers", help="each target's E-synth numbers, with no gate or trained run")
    for p in (v, n):
        p.add_argument("--synth", required=True)
        p.add_argument("--drops", default=None,
                       help="e_synth_audit.py drops --out, with the judge's judge/decisions.jsonl; needed when an "
                            "answer dropped a fact off label")
        p.add_argument("--merges", default=None,
                       help="merge_cases.py --out, with the judge's judge/decisions.jsonl; needed when an answer "
                            "absorbed a memory")
    args = ap.parse_args()
    match cast(str, args.command):
        case "run":
            return run(args)
        case "rescore":
            return rescore(args)
        case "verdict":
            return verdict(args)
        case "synth-numbers":
            return synth_numbers(args)
        case other:
            raise SystemExit(f"no command {other}")


if __name__ == "__main__":
    sys.exit(main())
