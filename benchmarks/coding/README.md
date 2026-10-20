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

`runs.jsonl` contains the coding report's measured fields. It does not create
Task, provider-attempt or independent-verdict IDs, and a model name is
not an artifact revision. The report reader consumes the same row producer as
the harness. These coding results alone cannot qualify the reliable-change G1
acceptance contract. The optional `--manifest` checker invocation does not fill
the missing joins; G1 needs observations from the actual runtime and verifier
producers. `--execution-mode matrix` does not supply controlled provider
responses or turn a live coding episode into a G1 matrix fixture.

The row's `operation_id` is copied from the actual `masc_keeper_msg` admission
response saved in `runs/<run-id>/msg-submit.json`. It identifies the same
durable chat operation the harness polls. It remains attached when later
verification fails or the episode times out; it is null when no accepted
identity was observed. The report validates it with the runtime's canonical
operation-ID type. This observation does not claim a Task or verification ID.

Every status response must explicitly identify that admitted operation before
its state can settle the episode. A foreign, absent or malformed identity is
recorded as a transport error, with the original normalized MCP envelope retained in
`runs/<run-id>/operation-invalid.json`. Prepared artifacts are still graded for
diagnostics, but a contradictory response cannot qualify the episode as passed.

An episode whose Keeper setup fails before workspace preparation still records
its failure. Verification runs only against a workspace prepared by that
episode, including timed-out episodes; a directory left by an interrupted
earlier run is not graded after a new admission failure.
