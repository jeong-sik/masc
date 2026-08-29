# Coding-outcome eval corpus (RFC-0396)

Each case is a self-contained coding task a Keeper is asked to finish. The
only pass verdict is deterministic: `verify.sh <workspace-dir>` exits 0
(RFC-0396 D2). No grader, score, or string match decides a pass.

## Case layout

```
benchmarks/coding/cases/<case-id>/
  case.json      # id, level, lang, timeout_sec, verify, prompt, description
  workspace/     # copied fresh per run; verify FAILS on this pristine state
  solution/      # reference fix; overlaying it onto workspace turns verify green
  verify.sh      # verify.sh <workspace-dir> — exit 0 iff the task is done
```

`case.json` fields:

| Field | Meaning |
|---|---|
| `id` | Case id; equals the directory name |
| `level` | `L1` single-file bug fix, `L2` small feature, `L3` multi-file change |
| `lang` | Language of the workspace (`python`, `typescript`, `ocaml`, ...) |
| `timeout_sec` | Per-run budget for the Keeper episode; the runner polls until this deadline |
| `verify` | Verify script path relative to the case directory |
| `prompt` | Task message sent to the Keeper; the runner appends the absolute workspace path |
| `description` | One line for reports |

Contracts enforced by `test/test_coding_eval_cases.ml` (no LLM involved):

1. Every `case.json` decodes.
2. `verify.sh` on a pristine workspace copy exits non-zero — the task starts red.
3. Overlaying `solution/` onto the workspace copy makes `verify.sh` exit 0 —
   the task is solvable and the verify script measures the right thing.

## Running

```bash
# Smoke: one case, n=2, one local model
CODING_EVAL_MODELS=ollama:qwen3-coder \
scripts/harness_coding_eval.sh --case-ids l1-calc-add --repeats 2

# Summarize an existing runs.jsonl without executing anything
scripts/dune-local.sh exec test/coding_eval_report_cli.exe -- \
  --cases benchmarks/coding/cases --runs <out-dir>/runs.jsonl --out <out-dir>
```

The runner writes one evidence JSON per run and appends `runs.jsonl`; the
report CLI aggregates through `Eval_harness.summarize_runs` (pass@k without
replacement, `min_runs_met` n>=5 reported honestly) and writes `REPORT.md` +
`report.json`. Reruns with the same `--out` directory skip runs whose
evidence already exists, so sharded and resumed collection is the normal
path (RFC-0396 D4).
