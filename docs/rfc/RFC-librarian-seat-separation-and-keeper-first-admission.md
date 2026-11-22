---
rfc: "librarian-seat-separation-and-keeper-first-admission"
title: "Librarian Seat Separation and Strict Keeper-First Slot Admission"
status: Draft
created: 2026-11-19
updated: 2026-11-22
author: masc contributors
supersedes: []
superseded_by: null
related:
  - "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
  - "exact-request-waits-only-for-a-seat"
  - "judgment-lanes-take-account-admission-before-keeper-turns"
---

# Librarian Seat Separation and Strict Keeper-First Slot Admission

## 0. Summary

Keepers (`Admission_class.Standard`, mean turn ~29.5s) and Librarian (`Admission_class.Background`, mean consolidation call ~413s; covering both `librarian_memory` and the working-context `librarian` pass) operate at a **14x–57x occupancy-duration asymmetry**. Sharing remote provider concurrency pools under legacy FIFO collapse (when `admission-priority-run-limit` is unset) or small count-based run limits starves live Keeper turns behind long-running Librarian calls.

This RFC adopts two clean, magic-number-free architectural changes grounded in [RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line](./RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line.md) (§15.3) and `docs/constitution.xml`:

1. **Strict Keeper-First Class Ordering in `Llm_provider.Slot_scheduler`** (`packages/agent_core/lib/llm_provider/slot_scheduler.ml`): Every request always queues in its declared `Admission_class.t` (`Priority > Standard > Background`). When `priority_run_limit = None`, strict `Priority > Standard > Background` ordering applies with **zero** artificial weights, **zero** queue-derived fake quotas, and **zero** concurrency cap imposed on `Background` when foreground queues are empty. Operator-declared `admission-priority-run-limit` (`Some limit`) continues to apply bounded fairness **only** when explicitly configured.
2. **Account/Seat Separation with Pre-Publication Overlap Inspection**: Dedicated non-overlapping endpoints eliminate head-of-line blocking and shared-pool contention altogether without magic numbers or remote cancellation races. `Runtime.detect_librarian_keeper_seat_overlaps` inspects enabled `librarian_exact` and `librarian_memory` lanes across both HTTP `slots` and CLI `cli_slots` against Keeper-reachable runtimes and emits structured debug diagnostics (`Log.Runtime.debug`) before `Provider_admission.publish` without breaking existing single-account or shared dev configurations.

---

## 1. Evidence (RFC #53148 §15.3)

Replay measurements over 7 days of live fleet traffic (`2026-11-10` to `2026-11-17`: 16,519 closed turns across 29 Keepers; hourly mean 98.3 turns/h, p90 169 turns/h; working-context `librarian` pass 683 calls) establish:

- **Occupancy asymmetry**:
  - Keeper turns: ~29.5s average (`Standard`).
  - Durable Librarian GLM calls: p50 **407s**, mean **413s**, p90 **660s**, max **936s** (`Background`, output ~24K tokens at ~62 token/s, invariant to input size up to >1M tokens).
  - Occupancy ratio: **~14x** on GLM (and **~57x** relative to ~7.3s fast Keeper calls if a shared ollama slot slows to GLM speed).
- **Replay sensitivity to `admission-priority-run-limit` (`L`) without isolated dedicated seats (GLM speed)**:

| `admission-priority-run-limit` (`L`) | >900s waited Keeper calls (GLM / ollama) |
|---|---|
| Undeclared (`None`, prior FIFO behavior) | 283 / 1,189 |
| `L = 4` | 13,429 / 39,191 |
| `L = 16` | 0 / 37,466 |
| Strict Keeper-first (`Priority > Standard > Background`) | 0 / 0 |

- **Effect of dedicated isolated seats (`tinker`, 4 seats, measured speeds)**:
  - `>900s` Keeper wait: **0 / 0** regardless of `L`.
  - Librarian queue wait p90: **0s** (~1,851 durable syntheses/day keeping pace with Keeper turn arrival).
  - Without dedicated seats, working-context pass (`librarian`) sharing GLM experiences p90 **381s** / max **1,145s** wait (vs p90 116s / max 468s with isolation).

Count-based `L` is structurally blind to duration asymmetry: any `L` smaller than the 14x–57x occupancy ratio harms Keeper latency worse than undeclared FIFO by periodically granting 413s `Background` holds into foreground bursts.

---

## 2. Rejected Alternatives

### 2.1 Candidate (B): Shared Account with Last-Seat Reservation (`K` seats reserved for Keepers)

- Fails Keeper bursts: on GLM `max_slots = 8`, once Keepers go briefly quiet, `Background` claims `8 - K` seats. When `>= 2` Keepers burst simultaneously, callers 2..8 block up to 413s (p90 660s, max 936s).
- Deadlocks `Background` when `max_slots = 1` (or when `Slot_scheduler.reconfigure` lowers `max_slots` to 1): free seats never exceed 1, starving `Background` indefinitely even with 0 active callers.
- Violates `docs/constitution.xml` (`magic_number`): choosing `K` is an arbitrary constant with no intrinsic hardware or protocol basis.

### 2.2 Candidate (C): Mid-Flight Preemption of Active Librarian HTTP/CLI Calls

- **Unsafe under non-streaming HTTP semantics**: `Exact_output.execute_flow_once` executes non-streaming synchronous HTTP POSTs (`Http_client`). While `Eio.Promise` + `Eio.Fiber.first` cleanly cancels the local fiber and releases the local `Slot_scheduler` permit in microseconds, upstream inference servers (GLM, Ollama Cloud, API gateways) do not immediately reclaim remote concurrency slots until output finishes or socket write fails (as `Exact_output` documents: *"remote cancellation or billing is not implied"*).
- Immediate dispatch of a waiting Keeper into that "freed" local permit triggers remote **HTTP 429** (`too many concurrent requests`), marking the shared Keeper slot in backpressure rest and degrading fleet-wide Keeper availability.
- Wastes 100% of generated output and thinking tokens accumulated over 200–350s (uncacheable by prefix caching) while burning shared RPM/TPM quotas.
- Repeated Keeper bursts shorter than 413s induce **permanent Librarian livelock** with snowballing backlog growth.
- For CLI fallback slots (`cli_slots`), SIGTERM/SIGKILL carries orphaned session conflicts (`Session_conflict`).

### 2.3 Candidate (D): Duration-Weighted Fair Queuing / Virtual Time / Deficit Round Robin

- Violates `docs/constitution.xml` (`magic_number`, `budget_gate`): requires choosing arbitrary class weight ratios (`Standard` vs `Background`) and virtual-clock clamp bounds across idle periods.
- Remains non-preemptive (head-of-line blocking persists whenever a 413s Librarian call occupies a seat) and suffers large concurrency overshoot because request latency (24s vs 936s) is unknown at admission time and resets on every process restart (~10.7/day).

---

## 3. Adopted Architecture

### 3.1 Strict Keeper-First `Slot_scheduler` Ordering

In `packages/agent_core/lib/llm_provider/slot_scheduler.{mli,ml}`:

- Requests always join their class queue (`Priority`, `Standard`, or `Background`) regardless of whether `priority_run_limit` is set.
- When `priority_run_limit = None`:
  - `next_queue` strictly grants **`Priority > Standard > Background`**, preserving FIFO arrival order within each class.
  - Zero queue-derived quotas, artificial weights, or fake defaults exist.
  - Zero concurrency cap is imposed on `Background` (`Librarian` uses full `max_slots` whenever `Priority` and `Standard` queues are empty, critical for dedicated Librarian endpoints).
- When `priority_run_limit = Some limit` (explicitly operator-declared `admission-priority-run-limit` in `runtime.toml`):
  - Bounded service guarantees prevent `Background` and `Standard` starvation on explicitly opted-in shared endpoints without altering strict priority ordering when `None`.

### 3.2 Candidate (A): Seat Separation + Load-Time Overlap Diagnostics

Account separation is the unique design guaranteeing **0 Keeper wait behind Librarian**, **0 Librarian starvation when backed by a dedicated slot**, **0 livelock/wasted output tokens**, and **0 magic numbers**:

- `Runtime.detect_librarian_keeper_seat_overlaps` in `lib/runtime/runtime.{mli,ml}` runs during `Runtime.set_loaded` immediately before `Provider_admission.publish` (and can be invoked purely on materialized configurations prior to publication).
- **Inspection scope**:
  - **Both Librarian `Background` exact lanes**: `Standalone_lane.Librarian` (working-context exact pass) and `Standalone_lane.Librarian_memory` (memory consolidation pass), whenever `enabled = true`.
  - **Both slot channels**: HTTP `slots` and official-client `cli_slots`.
  - **Keeper-reachable runtimes**: `default_runtime`, every candidate in `default_route` (resolving lanes), and every target in `keeper_assignments` (resolving lanes).
  - **Identity rules**:
    - Identical `runtime_id` (`Same_runtime_id`).
    - HTTP pairs (`Shared_http_account`): matching `provider_kind`, canonicalized `base_url` (lowercased scheme/host, explicit default ports `80`/`443`, trimmed trailing slash), and shared credential identity (`Secret.identity` when authorized or `quota_scope` / both keyless local endpoints).
    - CLI pairs (`Shared_cli_account`): `Runtime_execution.same_account_selection` / matching `Runtime_instance.quota_scope` (`Claude_code` / `Codex_app_server` `account_home`, `Muse_serve` `account_home`, `Antigravity_cli` `oauth_source` / `quota_scope`, `Vibe_cli`).
- **Non-breaking rollout**: Overlap detection logs structured `Log.Runtime.debug` diagnostics (quiet at default boot log levels; run with `MASC_LOG_LEVEL=debug` to inspect) and returns typed `librarian_keeper_seat_overlap list` values so existing dev/single-account and live configurations continue booting cleanly until operators complete slot allocation decisions.
- **Known external boundary**: Two distinct API keys belonging to the same provider organization concurrency pool cannot be proven identical locally from `(kind, canonical_base_url, Secret.identity)`.

---

## 4. Open Operator Decision

Live deployments currently place shared `glm`, `ollama_cloud`, `opencode_go`, and fallback `claude_code` seats in both Keeper routing and Librarian `slots` / `cli_slots` declarations. Promoting overlap diagnostics to strict load-time rejection (`Runtime.load_list` refusal before `Provider_admission.publish`) requires resolving the fleet seat topology first:

- **Option 1 — Dedicated Librarian seat(s)**: Allocate at least one dedicated HTTP endpoint/API account (or dedicated local runtime such as `tinker`) exclusively to `[runtime.exact_output_lanes.librarian_exact]` and `[runtime.exact_output_lanes.librarian_memory]`, removing shared `glm` / `ollama_cloud` / `opencode_go` / `claude_code` entries from Librarian slots (or dedicating separate paid accounts/CLI homes).
- **Option 2 — Keep Librarian optional/disabled on single-account installs**: On single-key or single-subscription hosts without a separate Librarian runtime, set `enabled = false` on optional `[runtime.exact_output_lanes.librarian_memory]` (and ensure `[runtime.exact_output_lanes.librarian_exact]` routes do not collide) before enabling strict seat-isolation enforcement.

**Status**: Left explicitly as an **Open Operator Decision**. MASC enforces strict Keeper-first admission in `Llm_provider.Slot_scheduler` (`packages/agent_core/lib/llm_provider/slot_scheduler.ml`, `next_queue` ordering `Admission_class.Priority > Standard > Background`) and keeps `Runtime.detect_librarian_keeper_seat_overlaps` available without hard-rejecting shared default configs until the operator confirms seat allocation. Overlap diagnostics are emitted at `Log.Runtime.debug` rather than `warn` so default boot logs stay quiet; operators inspecting shared seats can start with `MASC_LOG_LEVEL=debug`.
