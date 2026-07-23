---
rfc: "0215"
title: "Keeper sub-library extraction campaign — sequence and per-PR gates"
status: Draft
created: 2026-06-04
updated: 2026-06-05
author: jeong-sik (with Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0056", "0086", "0042", "0205"]
implementation_prs: []
---

# RFC-0215 — Keeper sub-library extraction campaign

> This is the follow-up RFC that RFC-0056 §3.4 ("Phase 1+") defers to:
> *"After Phase 0 passes the gate on `main`, future RFCs propose extractions
> in priority order based on a fan-in/fan-out audit run against `main`."*
> RFC-0056 defined the **gate** (G1–G5, §3.1). RFC-0086 ran the **rename
> prerequisite** (Phase 2.A). This RFC defines the **sequence**: which keeper
> sub-cluster extracts first, what decoupling each needs, and what each PR
> must satisfy at the gate.
>
> **Keeper extraction has NOT begun.** `lib/keeper/` is still a flat-namespace
> directory inside the mega-lib `masc` with no `dune` file. This document only
> defines the order of operations. No code moves under this RFC.

## 1. Problem (current measured state, origin/main 2026-06-04)

`lib/keeper/` holds **436 `.ml` files** (421 `.mli`) and compiles as part of
the mega-lib `masc` (`lib/dune` declares `(include_subdirs unqualified)` /
`(name masc)`; there is no `lib/keeper/dune`). Eighty-five sub-libraries have
already been extracted from `lib/` (each with its own `dune` + `library`
stanza); keeper is the single largest remaining flat-namespace block.

### 1.1 Bidirectional coupling — re-measured now, not from memory

The 2026-05-01 memory-recorded analysis (referenced in RFC-0056 §2, see §3
below) reported keeper at **189 ↔ 118** bidirectional references with the rest
of `lib/`. Those numbers are stale. Re-derived against the current tree:

| Direction | Count | Meaning |
|---|---|---|
| **rest → keeper** (cycle-creating) | **0** | No *extracted sub-library* holds a compile-time reference to a `Keeper_` module. |
| keeper → flat-ns mega-lib (`masc`) | **~70 distinct modules** | The G1-relevant forward refs. These are co-resident in `masc` today; they decide whether a keeper sub-lib can be carved without a dune cycle. |
| keeper → already-extracted sub-lib | **~63 distinct modules** | Not a blocker — declared as `(libraries ...)` deps in the new keeper `dune`. |
| flat-ns *top-level* `.ml` → keeper | **140 files** | Caller-delta input (G5), not a cycle. See §6. |

Why `rest → keeper = 0` is a structural fact, not a two-sample induction: the
mega-lib `masc` depends on every extracted sub-library, so a reverse edge
(sub-lib → `Keeper_*`) would be a dune cycle that the build rejects. The tree
compiles, therefore every `Keeper_*` token appearing in a sub-library `.ml` is
necessarily a comment or string literal, not a code reference. Spot-checks
confirm this: `lib/types/types_core.ml:477` (`[Keeper_config_text]`) and
`lib/cancel_safe/cancel_safe.ml:15` (`[Keeper_callback_failure.record]`) are
both doc-comments; neither `dune` lists keeper as a dependency.

**Measurement honesty.** The ~70 / ~63 split is a grep approximation
(`\b[A-Z][a-z][A-Za-z0-9_]*\.` extraction, classified against extracted-sublib
`(modules ...)` lists and flat-ns basenames). It is the *audit input*, not the
source of truth. The authoritative per-PR check is
`scripts/audit-sublib-cycle.py` (the G1 verifier, wired into CI in #19824) run
against the real `dune describe` graph on the proposed final file set. Each PR
self-checks with it before review — this is RFC-0056 §3.4's stance ("the audit
script is the durable artifact").

### 1.2 The ~70 flat-ns forward refs are the real blocker

The distinct flat-ns mega-lib modules keeper reaches (the G1 cycle risk) cluster
into the execution / observability mesh:

```
Admission_queue Agent_sdk_metrics_bridge Agent_sdk_response Approval_callbacks
Audit_log Auth Board Board_core_classify Board_dispatch Config
Context_compact_oas Inference_inflight_observation
Drift_guard Eval_gate Eval_harness Exec_core Failure_envelope
Inference_utils Llm_metric_bridge
Lockfree_atomic Masc_context_injector Masc_eio_env Masc_event_bus
Masc_oas_bridge Memory_hooks Memory_oas_bridge Observability_redact
Persona_dispatch_ref Progress Otel_metric_store Otel_metric_hotpath
Runtime_observation Runtime_observation_query_operation Runtime_params
Server_startup_state Shutdown Sse Task Telemetry_coverage_gap
Timeout_policy Tool_agent Tool_agent_timeline
Tool_assignment_telemetry Tool_board Tool_board_dispatch Tool_board_registry
Tool_bridge Tool_control Tool_input_validation Tool_library
Tool_local_runtime Tool_local_runtime_core Tool_misc Tool_misc_web_fetch
Tool_plan Tool_resource_gate Tool_run Tool_shard Tool_telemetry
Tool_workspace Transport_metrics Turn_mode_codec Verification Workspace
Workspace_dispatch_ref
```

This block is a historical dependency census, not a module creation list. The
removed Governance/effect-policy modules are intentionally absent and must not
be recreated by the extraction campaign. Keeper Gate remains a product-neutral
outer boundary rather than a flat-namespace policy dependency.

These fall into three families: cross-cutting infra (`legacy metrics backend`,
`Governance_registry`, `Runtime_params`, `Shutdown`, `Sse`,
`Telemetry_coverage_gap`), the tool surface (`Tool_*`), and the
execution/board hub (`Board_*`, `Exec_core`, `Workspace`, `Eval_*`,
`Verification`). A keeper sub-lib that references any of these would form
`masc → masc.keeper → masc` — a cycle. Extraction order is therefore decided by
**flat-ns fan-out** (what a cluster reaches *outward* into the mega-lib), not by
fan-in.

## 2. Goal and non-goals

**Goal.** Move keeper out of the flat-ns mega-lib into one or more wrapped
sub-libraries (`masc.keeper_*`), so that keeper's dependency direction is
compiler-enforced (a future re-coupling to `masc` becomes a build-breaking dune
cycle, not a lint-detectable drift). This promotes the
`tool-keeper-boundary-ratchet.sh` deterministic lint (RFC-0056 §7.2) to
compiler enforcement for the keeper axis.

**Non-goals.** This RFC does not (a) move any code, (b) change any `.mli`,
(c) consolidate keeper godfiles (that is RFC-0205's separate concern), or
(d) decide the *final* number of keeper sub-libraries. It fixes the order in
which clusters are attempted and the gate each must pass.

## 3. Prior analysis (referenced, not duplicated)

- **2026-05-01 memory analysis** ("keeper sub-library extraction", 189 ↔ 118
  bidirectional refs) — recorded inline in RFC-0056 §2 and cited there as the
  reason keeper is "a multi-PR campaign, not a leaf." This RFC supersedes those
  numbers with the §1.1 re-measurement; the *conclusion* (multi-PR campaign)
  stands.
- **RFC-0056** "Incremental Sub-Library Extraction" — the gate (G1–G5, §3.1),
  the `Masc.<Module>` grep lesson (§4.1), and the explicit deferral of keeper to
  "future RFCs in priority order" (§3.4). This RFC is that future RFC. The gate
  is cited, not restated.
- **RFC-0086** "Keeper namespace bulk promotion to sub-library" (Implemented,
  7 PRs #15467–#15531) — proposed bulk promotion behind a **Phase 2.A rename
  prerequisite** (~38 non-`keeper_`-prefixed files renamed to avoid
  `(wrapped false)` collisions). Re-measurement shows that prerequisite is now
  **down to 3 residual files** (§4) — most of the rename has already shipped.
  RFC-0086 chose *bulk* (one big promotion); RFC-0215 chooses *sequenced*
  (low-fan-out cluster first) because the §1.2 mesh makes a single clean cut
  unavailable today.
- **RFC-0205** "Keeper Module Consolidation" — orthogonal: it reduces keeper
  *file count* (facade elimination). It does not affect extraction direction.
  The two can proceed in parallel; fewer files lowers per-PR caller delta.

## 4. Decoupling pre-work — and what is NOT pre-work

### 4.1 Residual Phase 2.A rename (3 files) — implemented

Implemented by this PR (2026-06-04): the three residual non-prefixed files
under `lib/keeper/` were renamed to `keeper_token_count.ml`,
`keeper_sandbox_error.ml`, and `keeper_provider_error_class.ml`. Under
`(wrapped false)`, they now produce `Keeper_token_count`,
`Keeper_sandbox_error`, and `Keeper_provider_error_class`, avoiding collision
with flat-ns peers before any keeper `dune` stanza is written.

### 4.2 The tool-enum decouple PRs are NOT keeper-lib prep

PRs #20032, #20035, #20036, #20039 (merged 2026-06-04, "decouple {surface
class, progress names, capability axis names, board wrapper policy} from
{tool enum, MCP catalog}") are **intra-keeper / keeper↔tool-surface enum
decoupling**. They each touch only `lib/keeper/keeper_*.ml` + a test; none adds
a `dune` stanza, renames to a sub-lib namespace, or creates `lib/keeper/dune`.
They reduce keeper's coupling to the `Tool_name` enum, which incidentally
shrinks some of the §1.2 `Tool_*` fan-out, but they are **not** keeper
sub-library extraction prep and must not be cited as such. They are listed here
only to pre-empt that misattribution.

### 4.3 Genuine pre-work for the first cluster (see §5)

The first cluster cannot extract as a pure leaf today because no cluster has
zero flat-ns fan-out (§5 table). The pre-work is: relocate or invert the
handful of flat-ns refs that are **not** of the cluster's own domain. That
inversion — callback or interface, per the dependency-direction rule — is a
separate PR that ships *before* the `dune` stanza.

2026-06-05 correction: the former split persona implementation
module has been removed from current `main`; it is no longer an extraction
candidate. Keep the public persona profile tools on the existing
`keeper_persona` path instead of reviving a separate authoring module.

## 5. Extraction sequence

Candidate clusters and their re-measured **flat-ns fan-out** (the G1 metric).
Fan-in is shown for context but does not gate extraction.

| Order | Cluster | Modules | flat-ns fan-out (G1 blockers) | Distinct flat-ns refs |
|---|---|---|---|---|
| 1 | registry (`keeper_registry_*`) | 19 | 6 | `Admission_queue`, `Governance_registry`, `legacy metrics backend`, `Runtime_params`, `Shutdown`, `Sse` |
| 2 | error-classify (`*failure*`, `*error_class*`) | 31 | 6 | `Governance_registry`, `legacy metrics backend`, `Runtime_params`, `Shutdown`, `Telemetry_coverage_gap`, `Workspace` |
| 3 | runtime-binding (`keeper_heartbeat*`/`keeper_runtime*`/`keeper_attempt*`) | 30 | 6 | `Governance_registry`, `legacy metrics backend`, `Runtime_params`, `Sse`, `Telemetry_coverage_gap`, `Workspace` |
| 4 | hooks (`keeper_hook_oas_*`, `keeper_guard_*`) | ~9 | TBD (medium per workflow audit) | re-run G1 before scheduling |
| 5 | state-fsm (`keeper_turn_*`, `keeper_working_*`, `keeper_reconcile_*`, `keeper_lifecycle_*`) | ~41 | TBD | extract after 1–4 establish base |
| 6 | observability (`keeper_alert_*`, `keeper_metric_*`, `keeper_event_*`, `keeper_trace_*`) | ~13 | TBD (sink — many writers) | mid-campaign |
| 7 | execution (`keeper_agent_run_*`, `keeper_tool_*`, `keeper_sandbox_*`, `keeper_run_*`) | ~70 | highest | last — the mesh hub |

**Recommended first extraction: registry (`keeper_registry_*`).** It is now the
lowest live fan-out cluster after removing the retired split persona
module from the extraction queue. Its 6 refs are shared-infra modules that
several future clusters also reach, so an infra-facing interface built for
registry amortizes across registry, error-classify, and runtime-binding. The
tradeoff is that these refs are genuinely cross-cutting; each inversion must be
small enough to avoid creating a new facade god-module.

### 5.1 Per-PR shape

Each cluster ships as **two PRs**:

1. **Decoupling PR** — invert / relocate the cluster's non-domain flat-ns refs.
   No `dune` stanza. Verified by: the cluster's flat-ns fan-out drops to refs
   that are either intra-cluster, already-extracted sub-libs, or opam.
2. **Extraction PR** — add `lib/keeper_<cluster>/dune`
   (`(name masc_keeper_<cluster>) (wrapped false) (libraries ...)`), move the
   files, run the gate.

### 5.2 Per-PR G1–G5 expectations

| Gate | Expectation for each extraction PR |
|---|---|
| **G1 (no cycle)** | `python3 scripts/audit-sublib-cycle.py --root .` clean on the proposed final file set. After the §5.1 decoupling PR, the cluster's outbound refs resolve only to (a) its `dune` `(libraries ...)`, (b) intra-cluster siblings, (c) opam. Zero refs back into flat-ns `masc`. |
| **G2 (no `.mli` change)** | `git diff --stat lib/keeper_<cluster>/*.mli == 0`. The extraction PR is move-only; signatures are byte-identical. Any narrowing/widening belongs in a prior PR. |
| **G3 (no caller rename)** | Callers keep writing `Keeper_foo`, not `Masc_keeper_<cluster>.Keeper_foo`. Achieved by `(wrapped false)`. |
| **G4 (`@check` green)** | `dune build @check` succeeds locally and on CI Fundamental. Hot-path keeper changes additionally run `dune build .` (the `@check`-vs-default divergence: `@check` misses expression-level constructor type errors). |
| **G5 (caller-delta budget)** | Only `s/Masc\.Keeper_<moved>/Keeper_<moved>/g` qualifier removals outside `lib/keeper_<cluster>/`. The §1.1 count of 140 flat-ns top-level callers is the *upper bound*; per-cluster delta is a slice of it. Bare `Keeper_foo` callers need no change; only `Masc.Keeper_foo` qualified refs are rewritten. Anything beyond qualifier removal (signature accommodation, new `open`) fails G5 and means the cluster is not yet a leaf — return to §5.1 step 1. |

Failure of any gate → reject the PR. No `WORKAROUND:` override path for the
gate (RFC-0056 §3.1): reject means the candidate is not yet a leaf, and the fix
is more decoupling, not a catch-all or a lint suppression.

## 6. Trade-offs

- **No cluster extracts cleanly today.** The §5 table shows every candidate has
  non-zero flat-ns fan-out, so the headline "extractable first" framing from the
  fan-in audit is misleading — fan-in was the wrong metric. Every first move
  requires a decoupling PR first. The campaign front-loads that cost.
- **Two PRs per cluster doubles review count.** Eight clusters → up to 16 PRs,
  versus RFC-0086's single bulk promotion. The bulk approach was rejected
  because the §1.2 mesh has no single clean cut: a bulk move would carry all 70
  flat-ns refs at once and fail G1 in aggregate, with no incremental signal
  about which ref caused the cycle. Sequencing trades PR count for a
  per-cluster G1 signal.
- **`(wrapped false)` keeps the flat module namespace.** This preserves G3
  (callers unchanged) but means the 436 keeper modules continue to share a flat
  namespace — the rename collision risk (§4.1) persists for every future move,
  not just the initial 3. The alternative (`wrapped true` + `Keeper.` prefix)
  would force a caller rewrite across the 140 call sites in one PR, violating
  G5's incremental budget. We accept the residual rename discipline.
- **Shared-infra fan-out may resist inversion.** Clusters 2–4 reach
  `legacy metrics backend`, `Governance_registry`, `Runtime_params`. If these cannot be
  inverted to interfaces without a large blast radius, those clusters stall and
  the campaign halts at credential + whatever extracts cleanly. This RFC does
  not promise all eight clusters ship; it promises an *order* and a *gate* that
  refuses unsafe moves.
- **Execution cluster (≈70 modules) may never fully extract.** It is the mesh
  hub where Agent SDK, tool sandbox, runtime, and the turn FSM intersect.
  Sequencing defers it to last specifically because it may require its own RFC
  to decompose before extraction is even meaningful. Leaving it in flat-ns is an
  acceptable terminal state if 1–7 establish the boundaries that matter.
- **Measurement is grep-approximate.** The cluster fan-out numbers (§5) are
  honest grep counts, not `dune describe` truth. A cluster's real G1 result can
  differ once the script runs the actual graph (RFC-0056 §4.1 found 9 hidden
  `Masc.<Module>` callers a bare grep missed). The sequence is a *prediction*;
  `audit-sublib-cycle.py` is the *verdict*. Re-run it per PR.

## 7. Out of scope / explicitly deferred

- Keeper godfile consolidation (RFC-0205).
- The final sub-library count and naming convention beyond the §5 clusters.
- `wrapped true` migration (would be a separate RFC after the flat extraction
  proves the boundary holds).
- CI changes beyond the existing `audit-sublib-cycle.py` wiring (#19824).

## 8. Status

**Draft / Proposed.** This PR performs the §4.1 residual rename, clearing the
final `keeper_`-prefix prerequisite (3 files). After it lands, the next
concrete action this RFC authorizes is the §5.1 credential decoupling PR,
followed by a separate credential extraction PR when G1–G5 prove the cluster is
a leaf.
