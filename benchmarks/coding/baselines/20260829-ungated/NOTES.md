# Coding-outcome baseline, ungated — 2026-08-29 (RFC-0396 W2 complete)

Same case, same model, same command as [`../20260829`](../20260829/NOTES.md) —
the only change is that the harness now answers the approval surfaces an
eval keeper has no operator for. That earlier collection measured 0/2 with
both episodes starving at the 900s budget; the mechanism landed as #31640.

## Result

**pass@1 = 1.00 over n=2 (`min_runs_met=false` — below the n≥5 gate).**
Both episodes completed and verified green: 117s (8 tool calls) and 95s
(5 tool calls). The first run's tool sequence carried a live specimen of the
RFC-0396 D6-1 target: `Edit` missed its `old_string`, the keeper re-`Read`
the file, and the second `Edit` landed — recovery exactly along the path the
current error message suggests.

| Run | Outcome | verify | Duration | Tool calls |
|---|---|---|---|---|
| 1 | completed | 0 (green) | 117s | 8 |
| 2 | completed | 0 (green) | 95s | 5 |

## What "ungated" means (the #31640 resolution, wired into the harness)

1. **Chat-stream approval**: `pre_tool_use` elicits an operator approval per
   effectful call and expires unanswered asks in ~180s; the keeper retried
   the same call into the next expiry, forever. The harness now sets the
   product's per-keeper stance after `masc_keeper_up`:
   `POST /api/v1/keepers/tool-approval-mode {"name", "mode": "yolo"}`
   (in-memory, process-lifetime — exactly the scope an eval run wants).
2. **Durable gate**: the keeper profile the harness writes into its isolated
   config copy (`<config>/keepers/<name>.toml`) carries `always_allow = true`
   (plus the parser-required `instructions` and `sandbox_profile`).
   `MASC_CONFIG_DIR` shadows the base-path overlay, so the profile must live
   in that directory to be read at creation.
3. **Workspace placement**: the local profile writes inside the keeper
   playground and the model addresses paths relative to it, so the case
   workspace is materialized at `.masc/playground/<keeper>/workspace` —
   an external absolute directory failed every call with
   `cwd_not_directory` / file-not-found.

## Reading these numbers

n=2 on one L1 case is a smoke line, not a verdict; `min_runs_met` says so.
What it establishes: the pipeline completes end to end on a local model, the
pass verdict comes from the case verify script alone, and the gated-vs-
ungated pair shows the eval measuring a product property (approval-surface
behavior for headless keepers) before it ever measured a model. W3 fills the
L1–L3 corpus and n≥5.

```bash
scripts/harness_coding_eval.sh --models "ollama:qwen3:8b" \
  --case-ids l1-calc-add --repeats 2 --out <dir>
```
