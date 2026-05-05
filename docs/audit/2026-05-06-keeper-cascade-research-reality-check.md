# Keeper Cascade + Agent Architecture Reality Check (2026-05-06)

> Sources:
> - `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md` (926 lines)
> - `/Users/dancer/Downloads/agent_architecture_research_report.md` (130 lines, dated 2025-06)
>
> Target inspected: `masc-mcp` `main` at `1c9350f540` (`feat(ide): RFC-0027 PR-gamma -- drag reorder for multi-keeper pins (#13323)`).
>
> Purpose: convert the two external reports into current repo truth and a usable execution queue. Treat both reports as proposals, not authoritative state.

## 1. Executive Result

The reports are directionally useful but stale in important places.

The strongest surviving recommendation is still the same reliability chain:

1. Keeper turn-slot lifecycle / starvation evidence
2. OAS cancellation and zombie cleanup
3. Task oscillation control
4. Dashboard performance evidence
5. Eio cancellation hygiene

However, several report statements are no longer current:

- #12888 no longer lacks runtime work entirely: #13288 and #13299 are merged.
- The cited WIP PRs for #11929, #11927, #9798, #10395, #10710, and #10719 are closed unmerged.
- `CascadeResolver.tla` is not only a future proposal; it exists with clean and buggy cfgs and is wired into `scripts/tla-check.sh`.
- The research report's Qdrant memory recommendation is invalid for this workspace. Qdrant is retired; vector DB work must use Supabase pgvector only.

Current open tracking state is worse than the completion report claims: `gh issue list --state open --limit 300` returned 67 open issues and `gh pr list --state open --limit 100` returned 22 open PRs. The report's "42 open issues / 12 PRs" count is stale.

## 2. Source Claims

### Keeper Cascade Completion Report

The report's top-five critical gaps are:

| Rank | Report claim | Issue | Report state |
|---|---|---:|---|
| 1 | Keeper turn-slot lifecycle redesign | #12888 | TLA+ merged, runtime incomplete |
| 2 | OAS internal cancellation guard | #11929 | PR #12543 WIP |
| 3 | Dashboard enrich N+1 | #10710 | PR #12520 WIP |
| 4 | Task cycle oscillation | #10719 | PR #12521 WIP |
| 5 | Eio cancellation pattern violation | #10395 | PR #12486 WIP |

The report expands P0/P1 to seven issues by adding #11927 and #9798, and proposes this critical path:

`#12888 -> #11929 -> #11927 -> #10719 -> #10710 -> #10395 -> #9798`

### Agent Architecture Research Report

The research report recommends four architectural tracks:

| Track | Recommendation | Current decision |
|---|---|---|
| FSM / TLA+ | Model lifecycle, checkpoint, handoff, leader election | Keep, but extend existing specs first |
| Memory compaction | 3-tier memory and trigger-based compaction | Keep concept; reject Qdrant storage |
| Cascade rotation | Adaptive provider routing and cost/quality/latency metrics | Keep, but prefer native MASC/OAS contracts before external gateway adoption |
| 100+ keepers | Eio fiber pool, bounded mailbox, supervision tree | Keep as long-horizon work; requires load harness first |

## 3. Current Evidence

### P0/P1 Issue and PR State

Live GitHub issue state as of `2026-05-06T01:12:41+09:00`:

| Issue | Current state | Current meaning |
|---:|---|---|
| #12888 | OPEN | Core issue still open, but spec/runtime slices landed; remaining work is evidence and full closure criteria |
| #11929 | OPEN | OAS cancellation guard still open; old PR #12543 closed unmerged |
| #11927 | OPEN | Zombie activity-based eviction still open; old PR #12542 closed unmerged |
| #9798 | OPEN | Cascade exhausted pause/alert still open; old PR #12474 closed unmerged |
| #10395 | OPEN | Eio cancellation hygiene still open; old PR #12486 closed unmerged |
| #10710 | OPEN | Dashboard enrich N+1 still open; old PR #12520 closed unmerged |
| #10719 | OPEN | Task cycle oscillation still open; old PR #12521 closed unmerged |

Merged work related to #12888:

| PR | State | Meaning |
|---:|---|---|
| #13288 | MERGED 2026-05-05T14:55:02Z | `KeeperTurnSlot.tla` invariant and clean/buggy cfgs |
| #13299 | MERGED 2026-05-05T15:21:05Z | Runtime release/reacquire control around degraded retry |

Issue #12888's own comments say the remaining closure items are:

- live reproducer showing semaphore wait skips drop versus baseline
- normal-turn latency p50/p99 no-regression evidence

So the next useful #12888 action is not another speculative runtime redesign. It is a controlled evidence harness for live/staging proof.

### TLA+ State

`find specs -name '*.tla'` returned 90 specs on current `main`.

Relevant existing files:

- `specs/keeper-state-machine/KeeperTurnSlot.tla`
- `specs/keeper-state-machine/KeeperTurnSlot.cfg`
- `specs/keeper-state-machine/KeeperTurnSlot-buggy.cfg`
- `specs/boundary/CascadeResolver.tla`
- `specs/boundary/CascadeResolver.cfg`
- `specs/boundary/CascadeResolver-buggy.cfg`

`scripts/tla-check.sh` runs both clean and buggy variants for `KeeperTurnSlot` and `CascadeResolver`.

This means the reports' TLA+ recommendations should start by extending existing specs, not adding parallel replacement specs.

### Live Runtime Snapshot

`/health` was reachable during this audit and reported:

- build commit `1feadb3c2d`
- base path `/Users/dancer/me`
- MASC root `/Users/dancer/me/.masc`
- startup phase `ready`
- `keeper_fibers=17`
- `keeper_config_parse_error_count=0`
- `keeper_config_unknown_key_count=0`

This is good operational evidence, but it is not enough to close #12888 because the live process was behind inspected `main` (`1c9350f540`) and no forced timeout reproducer was run.

The companion harness confirms the same gap from persisted decision logs:

```console
$ scripts/keeper-turn-slot-evidence.sh --base-path /Users/dancer/me --window-min 1440 --min-normal-samples 1
...
analyst          ... INSUFFICIENT:no_slot_release_phase
executor         ... INSUFFICIENT:no_slot_release_phase
...
verifier         ... INSUFFICIENT:no_slot_release_phase
```

Recent normal latency samples exist, but the selected window has no persisted `slot_release_at_phase` rows.

## 4. Rejected or Adjusted Recommendations

| Report recommendation | Decision | Reason |
|---|---|---|
| Qdrant-backed Semantic+Procedural memory | Reject | Workspace SSOT says Qdrant is retired; use Supabase pgvector only |
| Adopt LiteLLM Router as first Phase 1 action | Defer | Requires current external docs and infra decision; native cascade telemetry and resolver work already exists |
| Redesign Keeper FSM from 13 states to 8-10 states now | Defer | Current FSM is tied to TLA specs and dashboard surfaces; compression is a high-risk redesign, not a first recovery step |
| Add new CascadeResolver spec from scratch | Reject as stated | `CascadeResolver.tla` already exists; extend it |
| Treat #12888 as "runtime missing" | Adjust | Runtime slice #13299 merged; closure now needs live evidence and p50/p99 regression proof |

## 5. Execution Queue

### Companion Harness

This audit adds `scripts/keeper-turn-slot-evidence.sh` as the #12888 closure evidence harness:

- Inputs:
  - active `$BASE_PATH/.masc/keepers/*.decisions.jsonl`
  - `semaphore_wait_ms`
  - persisted receipt rows with `slot_release_at_phase`
  - normal successful tool-use keeper latency samples
- Outputs:
  - summary table: slot waits, release phase counts, p50/p99 normal turn latency
  - explicit "not enough data" status when live reproducer has not been run

This is the safest immediate step because #13299 already changed runtime behavior, while #12888 remains open mainly because acceptance evidence is missing.

### Next PR-Sized Slice

Run a forced #12888 retry reproducer on a runtime at or after #13299 and capture the harness output before and after the run. The issue should stay open until the output shows both:

- `slot_release_at_phase` evidence in the selected window.
- Enough normal successful tool-use samples to compare p50/p99 latency.

### Follow-On Slices

1. #11929: rebuild cancellation guard from current `main`; old PR #12543 cannot be reused as current truth.
2. #11927: make zombie cleanup race fixture pass; do after cancellation semantics are verified.
3. #10719: add task oscillation detector around cycle_count > 3 and evidence for arbiter selection.
4. #10710: measure current dashboard enrich latencies on current code before rewriting; old numbers may be stale.
5. #10395: classify Eio cancellation sites by risk instead of attempting a repo-wide sweep.
6. #9798: wire cascade exhaustion into pause/alert after the terminal reason taxonomy is stable.

## 6. Completion Criteria for This Audit

This audit is complete when:

- The two Download reports are represented as repo-local current-state evidence.
- Stale or policy-invalid recommendations are called out explicitly.
- The P0/P1 issue queue is mapped to live GitHub state.
- The next action is narrowed to one PR-sized slice with a concrete evidence harness.

This file satisfies those criteria. It does not claim the 22-week roadmap is implemented.
