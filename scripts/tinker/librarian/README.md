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
when E-real is pinned. E-real runs read that copy. It is the only copy once the
server removed a record's text. When the snapshot is lost,
`e_real_manifest.py --of <manifest>` takes that manifest's records again from a
base that still holds them. The manifest it writes names the earlier one and
lists the records that are gone (`of.gone`), and E-real is the records left.
Nothing from the store is copied into this repository: the E-real manifest
holds only record digests and file sha256 values. E-real model answers stay in the run's
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
| `e_real_template.md` | The `config/prompts/librarian.md` the E-real records were drawn with (commit `7b026dc68ea0`); their prompt text is read with it |
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
| `audit_baseline.py` | Answers requests the pass lines do not pin with the base model, for their blind label audit |
| `teacher_sample.py` | Shows the teacher what each audited training label says and keeps the answers that leave the memory the label asks for, those that absorb a memory once the merge judge finds each absorb mergeable |
| `sft_examples.py` | What the candidate A is trained on: the teacher answers accepted for their requests, the reasoning effort they are rendered at, and the steps of one pass |
| `train_sft.py` | Trains the candidate A in one pass over the examples `sft_examples.py` plans |
| `prompt_lines.json` | A prompt draft's comparison, fixed before the draft runs: each model's baseline as numbers, the runs per side and the noise widths |
| `prompt_counts.py` | Counts one run of the pinned sets for a prompt comparison, from its rows and its judges' decisions |
| `prompt_lines.py` | Reads `prompt_lines.json`, and refuses one that is malformed, holds a stale baseline or pins other files than the present ones |
| `prompt_compare.py` | Decides whether a prompt draft goes in, from the pinned baselines and runs of the draft; prints the baseline that runs of the pinned template counted |

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
`reasoning_effort: "low"` and `max_tokens: 32768`. Both values are pinned in
`pass_lines.json` under `request`.

An exact request carries `max_tokens` only when its lane declares
`max_output_tokens`. A binding's `max-tokens` does not reach it. MASC sends the
lane's value to every slot of the lane, clamped to each slot's declared or
catalog output ceiling (`output_token_ceiling` in
`packages/agent_core/lib/llm_provider/backend_openai_request.ml`). The live
admission lane declares no `max_output_tokens` today, so its requests carry no
`max_tokens`.

When the operator puts a checkpoint in the admission lane, the roll-out saves
65,536 as the lane's `max_output_tokens` and declares an output ceiling of
32,768 on the checkpoint's binding. The checkpoint then receives 32,768, the
value these runs send. The GLM slot receives 65,536: its catalog row
(`glm-5.3-flash` under `glm-coding` in `packages/agent_core/models.toml`) sets a
ceiling of 131,072. Every other slot of the lane receives 65,536 clamped to its
own ceiling.

`glm_chat.py` sends the two messages as MASC's GLM slot does, with thinking
enabled and a `json_object` response format. It sends the pinned
`max_tokens: 32768` too, so a prompt draft and its baseline meet the same
ceiling. The live GLM slot sends no `max_tokens` until the roll-out saves the
lane value. The slot declares no effort, so the request carries none, and the
endpoint applies its default.

## Order

1. Write the E-real manifest and generate E-synth. Besides planted stale facts
   and duplicate pairs, a memory may hold records with a use time: notes for
   one day, which carry that day's date. A record used on a day after the
   candidates' is to stay; one used before them is planted stale, so the stale
   drop recall counts it. On requests whose label asks for a change, the
   E-synth numbers add `scheduled_ahead_keep_rate` and
   `scheduled_past_drop_recall`. A record still ahead that an answer drops is
   also an off-label drop (step 6).
2. Run the base model on E-synth (`audit_baseline.py`: the set is not pinned
   yet), audit the labels with a judge that sees neither the labels nor the
   answers, and keep the requests it confirms.
   E-synth can be made in batches. Generate each batch with its own seed and
   with `--first-memory` at the number where the last batch's memories ended,
   run and audit it by itself, and join the audited batches with
   `e_synth_audit.py pool`. It writes the requests in item ID order and refuses
   batches that share a memory key. `pass_lines.json` lists the batches and
   their audits under `e_synth.batches`.
3. Fix `pass_lines.json` and commit it before any training. The G6 merge lines
   come from the base model's merge numbers on the fixed E-synth:
   `eval_admission.py synth-numbers` prints them once the drop and merge judges
   (steps 6 and 7) have classed that run's answers. It reads no gate, choice
   or trained run. `verdict` and `train_sft.py` refuse while a gate has no
   number.
4. Generate the training split and audit its labels as step 2 audits
   E-synth's, with `--sample` above the number of requests, so that the judge
   sees every request. Sample the teacher on the requests the audit keeps
   (`teacher_sample.py sample`). The teacher is the base model at the
   reasoning effort and output budget `pass_lines.json` sets for a request.
   Besides the request and the schema instruction it gets a note of what the
   request's label says, so it follows the label, and a label no judge
   confirmed would become a wrong training target: `sample` refuses a request
   no `--audit` folder holds a case for, and one an audit took out alone or
   with its memory, whatever another audit says of it. A request is tied to
   its case by item ID: an audit records no sha256 of the requests it judged.
   A training example is the request, the schema instruction and the answer.
   The note is not one of its messages. The `reason` fields of the answer are
   the teacher's words and can repeat the note's, and no check reads them. An
   answer that absorbs a memory waits for the merge judge, also when its
   label expects the merge: `teacher_sample.py cases` gives the judge the
   absorb gate's question as `merge_cases.py` does, and `apply` keeps the
   answer only when every absorb is judged mergeable. `train_sft.py` trains A
   on the answers `apply` keeps, in one pass: each example is in one
   optimizer step. It reads them from the teacher's folder as `apply` does,
   so `accepted.jsonl` is a list to read, not what is trained on. `cases`,
   `apply` and training take a record only when its answer is the reply the
   call log holds for its request, asked with the label note at the
   reasoning effort and output budget the pass lines set now, and the answer
   still passes the teacher's screen for that request. They stop at a record
   that does not, at a request with two records, and at a record file that
   holds another number of records than the teacher's summary counts.
   Training renders the examples at that effort with the answer as the
   model's whole message, so A is trained to start its answer at once, where
   the base model writes a thinking part first. It refuses a teacher run
   that did not ask every request to the end (it stopped on its budget, or a
   request ended in an HTTP error) and one that names no label audit. A
   record names its request by item ID, so `sample`, `cases`, `apply` and
   training refuse requests of which two share one. Run `train_sft.py` with
   `--dry-run` first: that prints the number of examples, their tokens and
   the cost estimate, and trains nothing. A run writes `summary.json`, which
   `verdict --train` reads, then saves the weights with the optimizer state
   for seven days and writes that checkpoint's path to `state.json`. A
   failure during the pass leaves no checkpoint.
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
# The pinned E-synth is two batches: --seed 20261112, then --seed 20261113 --first-memory 10.
uv run scripts/tinker/librarian/synth_generate.py --split eval --seed 20261112 \
  --out artifacts/tinker/librarian/synth-eval --budget 6
uv run scripts/tinker/librarian/audit_baseline.py \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --out artifacts/tinker/librarian/eval-base-synth --budget 3
uv run scripts/tinker/librarian/e_synth_audit.py cases \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --run artifacts/tinker/librarian/eval-base-synth --baseline base \
  --sample 1000 --seed 20261112 --out artifacts/tinker/librarian/e-synth-audit
uv run scripts/tinker/librarian/e_synth_audit.py apply \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --audit artifacts/tinker/librarian/e-synth-audit \
  --final artifacts/tinker/librarian/e-synth/requests.jsonl
# E-synth in batches: the steps above once per batch, each `apply` to its own file, then
uv run scripts/tinker/librarian/e_synth_audit.py pool \
  --batch artifacts/tinker/librarian/e-synth-1/requests.jsonl \
  --batch artifacts/tinker/librarian/e-synth-2/requests.jsonl \
  --final artifacts/tinker/librarian/e-synth/requests.jsonl
# The training split (step 4): the same audit, then the teacher on the requests it keeps.
uv run scripts/tinker/librarian/synth_generate.py --split train --seed 20261114 \
  --out artifacts/tinker/librarian/synth-train --budget 12
uv run scripts/tinker/librarian/audit_baseline.py \
  --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
  --out artifacts/tinker/librarian/train-base --budget 6
uv run scripts/tinker/librarian/e_synth_audit.py cases \
  --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
  --run artifacts/tinker/librarian/train-base --baseline base \
  --sample 1000 --seed 20261114 --out artifacts/tinker/librarian/train-audit
uv run scripts/tinker/librarian/e_synth_audit.py apply \
  --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
  --audit artifacts/tinker/librarian/train-audit \
  --final artifacts/tinker/librarian/train-audited/requests.jsonl
uv run scripts/tinker/librarian/teacher_sample.py sample \
  --requests artifacts/tinker/librarian/train-audited/requests.jsonl \
  --audit artifacts/tinker/librarian/train-audit \
  --out artifacts/tinker/librarian/teacher --budget 10
uv run scripts/tinker/librarian/teacher_sample.py cases \
  --requests artifacts/tinker/librarian/train-audited/requests.jsonl --out artifacts/tinker/librarian/teacher
uv run scripts/tinker/librarian/teacher_sample.py apply \
  --requests artifacts/tinker/librarian/train-audited/requests.jsonl --out artifacts/tinker/librarian/teacher
uv run scripts/tinker/librarian/train_sft.py \
  --requests artifacts/tinker/librarian/train-audited/requests.jsonl \
  --teacher artifacts/tinker/librarian/teacher \
  --out artifacts/tinker/librarian/train-A --budget 70
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
case stands for. A label or drop case shows the time of the request, that of
its last candidate: the prompt shows a candidate's time only in epoch seconds,
and a record's use date tells which side of it the record is on.
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
G1 counts the E-real items the baseline's endpoint did not refuse outright. An
item its call got HTTP 400 for is past what the base model accepts, such as its
context, so no weights trained on that model answer it: `verdict.json` lists
those items under `e_real_refused` and gives each candidate's
`valid_rate_in_reach`. An answer cut off at `max_tokens` stays counted.
It also lists, by item, the memory IDs each candidate dropped that the live
answer keeps (`dropped_not_in_live`). G2 caps their number; read the list
before an install, since the count does not tell a lost memory from a stale
one the live answer kept.

A rerun with the same `--out` reuses every answered call and pays only for the
rest. A budget stop exits with status 2. So does HTTP 402 from Tinker: the
endpoint takes no call for the account until its billing changes, and the run
ends there with the reason in `stopped`. `verdict` refuses a run where a
candidate's call and the baseline's call for the same item left more than
`same_item_window_s` apart, so a baseline answered in an earlier run cannot
stand in for the one G5 compares against.

Every prompt goes out drawn with the pinned template. An E-real record holds
the prompt text MASC sent, so it is first read with the template of that day
(`e_real_template.md`, pinned as `e_real.template_sha256`) and drawn again from
the same data; its retirement evidence goes out under the retirement policy of
the template it is drawn with. `run --template <librarian.md>` measures a
prompt change on the same sets: it draws every prompt with that file's template
instead. `summary.json` records the sha256 of the template the prompts were
drawn with, and `verdict` refuses a run whose template is not the pinned one.

`prompt_compare.py compare --runs <runs.json> --out <compare.json>` decides
whether a draft of `config/prompts/librarian.md` goes in (RFC-0517 §2.3).
`prompt_lines.json` fixes the comparison before the draft runs: the pass
lines, the template of the baseline, two runs per side on Inkling and one on
GLM, the noise widths, and each model's baseline. A baseline is what the
model's runs of the pinned template counted, kept as numbers: each metric's
hits over chances summed over the runs and, for each run, its E-real record,
the sha256 of the rows the counts came from and the answered calls it counted.
An answered call is named by one sha256 of its key and the time it was sent
(`answered_sha256`). `compare` reads the baseline from the file
and measures only the draft's runs (`prompt_counts.py`), so a comparison needs
neither the baseline's run folders nor its judges' decisions, and neither can
move a pinned count. Nor can the comparison hold a pinned baseline to the runs
it was counted from: the file is the record, and a count changed in it is read
as it stands. A model whose baseline is `null` cannot be compared yet.
A draft run that counts an answered call a pinned baseline counted is refused,
and so is one whose rows file has the sha256 of a baseline's rows.
A run made in a copy of a baseline run's folder answers from that folder's log
every request the draft leaves as it was, and a row written again with other
spacing or key order names the same call.
`compare.json` names the rows of both sides by sha256.

`prompt_compare.py baseline --runs <runs.json>` measures runs of the pinned
template and prints the baseline to put in `prompt_lines.json`. A baseline
names the provider and the model it was counted for, and the pass lines, the
template and the `prompt_counts.py` it was counted under. Once the file names
another of them the baseline is stale, and `prompt_lines.py` refuses the file.
After a change of `prompt_counts.py` alone, set the baseline to `null`, count
the same runs again and pin what `baseline` prints. After a change of the
model, the pass lines or the template the old runs are refused too, so the
model runs again first.

`prompt_lines.json` names two kinds of files, and both commands stop when one
of them is not the present one. It names the pass lines and the template of
the baseline. That template is `config/prompts/librarian.md` as the pass lines
pin it, so pass lines pinned again for a new template leave the file refused
until it names that template. It also pins `prompt_counts.py`,
`prompt_lines.py` and `prompt_compare.py` by sha256 (`files_sha256`). After a
change of `prompt_lines.py` or `prompt_compare.py` only `files_sha256` is
pinned again and the baselines stand; a change of `prompt_counts.py` leaves
them stale as above. `prompt_lines.json` and `runs.json` are read as written:
a file that is not JSON, a key the comparison does not read, a key written
twice in one object, or a value of another shape is refused.

Each metric counts hits over
chances, summed over a side's runs. Its noise σ is the binomial standard error
of the difference at the pooled rate. A metric is worse below -2.5σ and better
above +2σ. The widths are compared in exact fractions, so a difference of
exactly a width is neither. The draft goes in when no metric of either model is worse and an
Inkling E-synth quality metric is better: memory state accuracy, stale drop
recall or judged merge recall. Drop and absorb precision and the valid rates
remain non-degradation checks; their improvement alone does not admit a draft.
A metric with chances on only one side remains
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
