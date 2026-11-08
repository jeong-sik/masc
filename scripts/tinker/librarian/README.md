# keeper-librarian admission on Tinker

These scripts train a LoRA of Inkling 2 Small on Tinker for the
keeper-librarian Lane Add-on's `admission` output, and decide with fixed pass
lines whether the trained checkpoint may answer that output first.

Everything runs on the operator's machine with `uv run`. Each script pins its
dependencies in a PEP 723 header. `TINKER_API_KEY` comes from the environment
and is never written. Paths to the MASC runtime store come from `--base` or
`MASC_BASE_PATH`. Output goes under `artifacts/` (git-ignored).

## Data rule

The exact-request store holds real Keeper memory. Scripts read it in place.
Nothing from it is copied into this repository: the E-real manifest holds only
record digests and file sha256 values. E-real model answers stay in the run's
`calls.jsonl` under `artifacts/`. The committed evidence holds numbers, IDs and
verdicts.

Synthetic Keepers, memories and candidates are invented by the model from
`synth_spec.py` and `synth_prompts.py`. They carry no store content.

## Files

| File | Role |
| --- | --- |
| `pass_lines.json` | Fixed request shape, evaluation sets, baseline, candidates, gates and the files whose bytes they assume |
| `e_real_manifest.json` | E-real: the answered admission records, by digest and sha256 |
| `exact_store.py` | Reads answered admission records from the store, read only |
| `e_real_manifest.py` | Writes the manifest |
| `synth_spec.py` | Plan of a synthetic request: measured distributions, ID shapes, labels |
| `synth_candidate_plan.py` | Plans a split's candidates before any call, dealing marks and lengths out per label kind |
| `synth_prompts.py` | Prompts that ask the model for role material, memories and candidates |
| `synth_generate.py` | Builds synthetic requests with labels (`--split eval` or `train`) |
| `synth_render.py` | Renders a synthetic request as the admission prompt MASC would send |
| `e_synth_audit.py` | Picks requests for a blind judge and drops the ones whose labels the judge does not confirm |
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
| `eval_admission.py` | Measures targets on E-real and E-synth, then applies the gates |
| `teacher_sample.py` | Keeps teacher answers that match the training labels |
| `train_sft.py` | Trains branch A (answer only) or B (teacher thinking and answer) |

The tests are `scripts/tests/test_tinker_librarian_*.py`. They read only
invented rows and the invented Keeper in
`scripts/tests/tinker_librarian_fixtures.py`. Each one runs as
`uv run --python 3.12 scripts/tests/<test file>`; the verdict test imports the
Tinker caller, so its header pins openai. `pyrightconfig.json` puts this
directory on the tests' import path, so `pyright` checks them from the
repository root.

## Request shape

Every evaluation call sends what MASC's exact lane sends: the admission prompt,
then the schema instruction as the last user message, with
`reasoning_effort: "low"` and `max_tokens: 32768`.

An exact request carries `max_tokens` only when its lane declares
`max_output_tokens`. A binding's `max-tokens` does not reach it. MASC clamps the
lane's value to each slot's declared or catalog output ceiling. At rollout the
checkpoint's binding declares an output ceiling of 32,768, and the lane's
`max_output_tokens` is at least that, so the checkpoint receives 32,768.

## Order

1. Write the E-real manifest and generate E-synth.
2. Run the base model on E-synth, audit the labels with a judge that sees
   neither the labels nor the answers, and keep the requests it confirms.
3. Fix `pass_lines.json` and commit it before any training.
4. Generate the training split, sample the teacher, train branch A and branch B.
5. Measure the base model, A and B in one run per set, from an empty `--out`,
   then `verdict`.

```sh
MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/e_real_manifest.py \
  --out scripts/tinker/librarian/e_real_manifest.json
uv run scripts/tinker/librarian/synth_generate.py --split eval --seed 20261109 \
  --out artifacts/tinker/librarian/synth-eval --budget 5
uv run scripts/tinker/librarian/e_synth_audit.py cases \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --run artifacts/tinker/librarian/eval-base-synth --baseline base \
  --sample 30 --seed 20261109 --out artifacts/tinker/librarian/e-synth-audit
uv run scripts/tinker/librarian/e_synth_audit.py apply \
  --requests artifacts/tinker/librarian/synth-eval/requests.jsonl \
  --audit artifacts/tinker/librarian/e-synth-audit \
  --final artifacts/tinker/librarian/e-synth/requests.jsonl
MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/eval_admission.py run --set real \
  --target base=thinkingmachines/Inkling-2-Small:peft:262144 \
  --target A=<sampler path of A> --target B=<sampler path of B> \
  --out artifacts/tinker/librarian/verdict-real --budget 6
uv run scripts/tinker/librarian/eval_admission.py run --set synth \
  --requests artifacts/tinker/librarian/e-synth/requests.jsonl \
  --target base=thinkingmachines/Inkling-2-Small:peft:262144 \
  --target A=<sampler path of A> --target B=<sampler path of B> \
  --out artifacts/tinker/librarian/verdict-synth --budget 9
uv run scripts/tinker/librarian/eval_admission.py verdict \
  --real artifacts/tinker/librarian/verdict-real --synth artifacts/tinker/librarian/verdict-synth
```

A rerun with the same `--out` reuses every answered call and pays only for the
rest. A budget stop exits with status 2. `verdict` refuses a run where a
candidate's call and the baseline's call for the same item left more than
`same_item_window_s` apart, so a baseline answered in an earlier run cannot
stand in for the one G5 compares against.
