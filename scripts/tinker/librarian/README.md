# keeper-librarian admission on Tinker

These scripts train a LoRA of Inkling 2 Small on Tinker for the
keeper-librarian Lane Add-on's `admission` output, and decide with fixed pass
lines whether the trained checkpoint may answer that output first.

Everything runs on the operator's machine with `uv run`. Each script pins its
dependencies in a PEP 723 header. `TINKER_API_KEY`, and `ZAI_API_KEY` for a GLM
run, come from the environment and are never written. `--base` or
`MASC_BASE_PATH` names a MASC base path: the server's when the E-real snapshot
is taken, the snapshot's for an E-real run. Output goes under `artifacts/`
(git-ignored).

## Data rule

The exact-request store holds real Keeper memory. The server removes an
admission's text once every candidate is committed and acknowledged, so
`e_real_manifest.py --snapshot` copies the answered admission records into
`artifacts/tinker/librarian/e-real-snapshot/`, readable by its owner alone,
when E-real is pinned. E-real runs read that copy. Nothing from the store is
copied into this repository: the E-real manifest holds only record digests and
file sha256 values. E-real model answers stay in the run's
`calls.jsonl` under `artifacts/`. The committed evidence holds numbers, IDs and
verdicts. A GLM run sends E-real prompts to Z.AI, where MASC's GLM slot sends
them.

Synthetic Keepers, memories and candidates are invented by the model from
`synth_spec.py` and `synth_prompts.py`. They carry no store content.

## Files

| File | Role |
| --- | --- |
| `pass_lines.json` | Fixed request shape, evaluation sets, baseline, candidates, gates and the files whose bytes they assume: every module `eval_admission.py`, `e_synth_audit.py` and `merge_cases.py` import, and the prompt template |
| `e_real_manifest.json` | E-real: the answered admission records, by digest and sha256 |
| `exact_store.py` | Reads answered admission records and copies them into the E-real snapshot; never writes the server's store |
| `e_real_manifest.py` | Takes the E-real snapshot and writes its manifest |
| `synth_spec.py` | Plan of a synthetic request: measured distributions, ID shapes, labels |
| `synth_candidate_plan.py` | Plans a split's candidates before any call, dealing marks and lengths out per label kind |
| `synth_prompts.py` | Prompts that ask the model for role material, memories and candidates |
| `synth_generate.py` | Builds synthetic requests (`--split eval` or `train`) |
| `synth_rows.py` | Writes a synthetic request as a row of requests.jsonl, and reads a row back into typed facts, candidates and their label |
| `synth_render.py` | Renders a synthetic request as the admission prompt MASC would send |
| `e_synth_audit.py` | Picks requests for a blind judge and drops the ones whose labels the judge does not confirm; at verdict time, makes the judge's cases for facts an answer dropped off label |
| `audit_decisions.py` | Checks the judge's decisions, and turns its classes for off-label drops into the memories the verdict leaves out |
| `merge_cases.py` | At verdict time, asks a blind judge of every memory an answer absorbs what MASC's absorb gate asks, in the gate's words |
| `merge_decisions.py` | Checks the judge's classes for absorbs, and counts absorb precision and judged merge recall from them |
| `admission_request.py` | Reads an admission prompt into typed parts and writes it back byte for byte |
| `admission_template.py` | Splits `config/prompts/librarian.md` at its variables |
| `prompt_facts.py` | Reads and writes the prompt's current memory and candidates as MASC's JSON |
| `memory_variables.py` | Writes the `facts_budget` and `memory_limits` texts MASC derives from the current facts |
| `ocaml_text.py` | The OCaml Stdlib text functions MASC applies to prompt and answer text |
| `admission_validator.py` | Accepts or refuses an answer the way MASC does, one rule at a time |
| `admission_result.py` | The accepted answer or the refusal that `admission_validator.validate` returns |
| `lane_addon_checks.py` | The lane add-on steps an exact-lane answer passes before the admission rules |
| `admission_judgment.py` | The judgment wrapper and support checks of `keeper_memory_admission_judgment.ml` |
| `librarian_selection.py` | `selection_of_json_result` of `keeper_librarian.ml`, over the answer's `memory` |
| `yojson_wire.py` | Reads and writes JSON the way MASC's Yojson does |
| `check_validator_on_store.py` | Runs the parser and the validator over every retained admission record and prints counts, read only |
| `tinker_oai.py` | Budgeted calls to Tinker's OpenAI-compatible endpoint, cached for resume |
| `glm_chat.py` | Capped calls to Z.AI's GLM coding endpoint in the request MASC's GLM slot sends, cached for resume |
| `eval_admission.py` | Measures targets on E-real and E-synth, then applies the gates |
| `memory_scores.py` | Scores one answer: E-real against the live answer, E-synth by the memory it leaves |
| `teacher_sample.py` | Keeps teacher answers that leave the memory their training labels ask for, and those that absorb a memory once the merge judge finds each absorb mergeable |
| `train_sft.py` | Trains the candidate A on the teacher's answers |
| `prompt_lines.json` | A prompt draft's comparison, fixed before the draft runs: the baseline runs, the runs per side and the noise widths |
| `prompt_compare.py` | Decides whether a prompt draft goes in, from runs of the pinned template and of the draft |

The tests are `scripts/tests/test_tinker_librarian_*.py`. They read only
invented rows and the invented Keepers in
`scripts/tests/tinker_librarian_fixtures.py` and
`scripts/tests/tinker_librarian_synth_fixtures.py`. Each one runs as
`uv run --python 3.12 scripts/tests/<test file>`; the verdict test imports the
Tinker caller, so its header pins openai. `pyrightconfig.json` puts this
directory on the tests' import path, so `pyright` checks them from the
repository root.

## Request shape

Every evaluation call sends what MASC's exact lane sends: the admission prompt,
then the schema instruction as the last user message, with
`reasoning_effort: "low"` and `max_tokens: 32768`.

An exact request carries `max_tokens` only when its lane declares
`max_output_tokens`. A binding's `max-tokens` does not reach it. MASC sends the
lane's value to every slot of the lane, clamped to each slot's declared or
catalog output ceiling. Rollout saves 32,768 as the lane's
`max_output_tokens`, and the checkpoint's binding declares an output ceiling of
32,768, so the checkpoint receives 32,768.

A GLM run sends what MASC's GLM slot then sends: the same two messages, with
thinking enabled, a `json_object` response format and the same `max_tokens`
(GLM's output ceiling is higher). The slot declares no effort, so the request
carries none, and the endpoint applies its default.

## Order

1. Write the E-real manifest and generate E-synth.
2. Run the base model on E-synth, audit the labels with a judge that sees
   neither the labels nor the answers, and keep the requests it confirms.
3. Fix `pass_lines.json` and commit it before any training. The G6 merge lines
   come from the base model's merge numbers on the fixed E-synth:
   `eval_admission.py synth-numbers` prints them once the drop and merge judges
   (steps 6 and 7) have classed that run's answers. It reads no gate, choice
   or trained run. `verdict` and `train_sft.py` refuse while a gate has no
   number.
4. Generate the training split and sample the teacher (`teacher_sample.py
   sample`). An answer that absorbs a memory waits for the merge judge, also
   when its label expects the merge: `teacher_sample.py cases` gives the judge
   the absorb gate's question as `merge_cases.py` does, and `apply` keeps the
   answer only when every absorb is judged mergeable. Train A on the
   `accepted.jsonl` that `apply` writes.
5. Measure the base model and A in one run per set, from an empty `--out`.
6. When a valid E-synth answer dropped a fact its label does not name (not
   planted stale, not a correction or complement target, not a fact of a
   duplicate pair), a judge that sees neither the labels nor the answers
   classifies that fact among others of the same memory (`e_synth_audit.py
   drops`). Every case of one memory shows the same facts: the ones the label
   audit picks on any request of that memory, the dropped ones and a fill.
   Unless the judge keeps the fact, no target is scored on that memory. A drop
   the judge keeps or finds restating another fact stays wrong, also when its
   memory leaves scoring, and so does a dropped complement target or duplicate
   fact.
7. When a valid E-synth answer absorbs a memory, a judge that sees no label,
   target or request answers the question MASC's absorb gate asks of it, in
   the gate's words and with the state the gate sends (`merge_cases.py`): can
   this memory retire into that claim? An absorbed planted stale fact gets no
   case: no candidate continues that transient state, so its label makes the
   absorb wrong. Absorb precision is the share of absorbs judged mergeable;
   judged merge recall counts a merge the label expects only when every absorb
   it made is judged mergeable. Then `verdict`.

```sh
MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/e_real_manifest.py \
  --snapshot artifacts/tinker/librarian/e-real-snapshot \
  --out scripts/tinker/librarian/e_real_manifest.json
uv run scripts/tinker/librarian/synth_generate.py --split eval --seed 20261110 \
  --out artifacts/tinker/librarian/synth-eval --budget 6
uv run scripts/tinker/librarian/e_synth_audit.py cases \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --run artifacts/tinker/librarian/eval-base-synth --baseline base \
  --sample 1000 --seed 20261110 --out artifacts/tinker/librarian/e-synth-audit
uv run scripts/tinker/librarian/e_synth_audit.py apply \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --audit artifacts/tinker/librarian/e-synth-audit \
  --final artifacts/tinker/librarian/e-synth/requests.jsonl
MASC_BASE_PATH=artifacts/tinker/librarian/e-real-snapshot \
  uv run scripts/tinker/librarian/eval_admission.py run --set real \
  --target base=thinkingmachines/Inkling-2-Small:peft:262144 \
  --target A=<sampler path of A> \
  --out artifacts/tinker/librarian/verdict-real --budget 6
uv run scripts/tinker/librarian/eval_admission.py run --set synth \
  --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
  --target base=thinkingmachines/Inkling-2-Small:peft:262144 \
  --target A=<sampler path of A> \
  --out artifacts/tinker/librarian/verdict-synth --budget 9
uv run scripts/tinker/librarian/e_synth_audit.py drops \
  --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
  --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-drops
uv run scripts/tinker/librarian/merge_cases.py \
  --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
  --run artifacts/tinker/librarian/verdict-synth --out artifacts/tinker/librarian/verdict-merges
uv run scripts/tinker/librarian/eval_admission.py verdict \
  --real artifacts/tinker/librarian/verdict-real --synth artifacts/tinker/librarian/verdict-synth \
  --drops artifacts/tinker/librarian/verdict-drops --merges artifacts/tinker/librarian/verdict-merges \
  --train A=artifacts/tinker/librarian/train-A
```

`cases`, `drops` and `merge_cases.py` keep the key in `--out` and put the
judge's material in `--out/judge/`. Give the judge that folder itself, not a
copy, and nothing else: it reads `judge.md` and `cases.jsonl` there and writes
`decisions.jsonl` next to them. They refuse an `--out` whose judge folder
already holds `decisions.jsonl`. The check cannot tell decisions made under other
rules: copy a `decisions.jsonl` into another `--out` only to re-check an audit
under the same rules. `judge.md` names
its rules as `config/prompts/librarian.md`, and the folder holds a copy at that
path; the merge judge's `judge.md` quotes the gate's slots from it. The key
holds the label's classes and the dropped facts, or the absorbs each merge
case stands for.
`--out/judge-files.json` holds the sha256 of the three files the judge was
given. `apply` and `verdict` read the decisions only while those files are
unchanged and the rules copy equals this checkout's `config/prompts/librarian.md`.
A merge case shows the claim of the call its row names, and
`merge_cases.py` writes `--out/run-files.json`, the sha256 of the run's
`calls.jsonl` and `rows.jsonl`: `verdict` reads the merge decisions only for
the `--synth` run that holds those files.
`verdict` refuses while an off-label drop or an absorb has no decision. It
records each drop, its class, the memories left out, each target's wrong drops
on them, each absorb's class, each target's absorb numbers and the judges' file
sha256 values in `verdict.json`.

A rerun with the same `--out` reuses every answered call and pays only for the
rest. A budget stop exits with status 2. `verdict` refuses a run where a
candidate's call and the baseline's call for the same item left more than
`same_item_window_s` apart, so a baseline answered in an earlier run cannot
stand in for the one G5 compares against.

`run --template <librarian.md>` measures a prompt change on the same sets: it
draws every prompt with that file's template from the same request data. An
E-real prompt is first read with the pinned template, and its retirement
evidence goes out under the new template's retirement policy. `summary.json`
records the sha256 of the template the prompts were drawn with, and `verdict`
refuses a run whose template is not the pinned one.

`prompt_compare.py --runs <runs.json> --out <compare.json>` decides whether a
draft of `config/prompts/librarian.md` goes in (RFC-0517 §2.3).
`prompt_lines.json` fixes the comparison before the draft runs: the pass
lines, the template and rows of each baseline run, two runs per side on
Inkling and one on GLM, and the noise widths. Each metric counts hits over
chances, summed over a side's runs. Its noise σ is the binomial standard error
of the difference at the pooled rate. A metric is worse below -2.5σ and better
above +2σ. The draft goes in when no metric of either model is worse and an
Inkling E-synth quality metric is better: memory state, stale drops, judged
merges or absorb precision. A metric with chances on only one side remains
`uncounted` and appears in `uncompared`; the comparison is incomplete and the
draft does not go in. With no chances on either side, that metric supplies
neither degradation nor improvement; the other measured metrics still decide.
A draft runs on GLM only after its
Inkling runs pass. The drop and merge judges of steps 6 and 7 class the
E-synth runs of both sides under the pinned template's rules. E-real outcome
agreement and the drops of memories the live answer kept are recorded, not
judged: a person reads the drops that changed.

`run --provider glm --target glm=<model> --max-calls <n>` measures the same
sets on GLM (`glm_chat.py`). It sends no warm call, and its rows cost nothing
per token. It waits on one request at a time, since the key's rate limit (1302)
also counts the live Keepers' requests. `--max-calls` caps the requests under `--out`, counting the ones
already logged; a run killed mid-call can pass the cap by the calls that were
in flight, since an attempt counts once its row is logged. GLM's code is read
as MASC reads it: under another status than 200, only a quota, auth or
context-overflow code takes the status's place, and in a 200 body the code
decides. A spent usage window, plan or balance (1113, 1308-1311, 1313, 1314,
1316-1321) or an auth code stops the run with GLM's message, which names the
reset time, and exits with status 2. A rerun with the same `--out` after the
reset sends only the rest. No response, a 408, 429 or 5xx that no code
overrides, and a rate-limit or server code in a 200 body are sent again; any
other failure leaves that answer not valid.
Keep GLM and Tinker runs in separate `--out` folders: each caller counts every
row of its log against its own limit.
