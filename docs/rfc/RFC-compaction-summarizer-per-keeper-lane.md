---
rfc: "compaction-summarizer-per-keeper-lane"
title: "Compaction summarizer must obey the per-Keeper lane, not a fleet-wide provider slot"
status: Draft
created: 2026-07-18
updated: 2026-07-18
author: vincent
supersedes: []
superseded_by: ""
related: ["0257", "masc-oas-bridge-total-llm-dispatch-boundary", "shared-admission-primitive-knob-binding-policy"]
tracking_issues: ["25051", "24838", "24990", "24965"]
regression_from: "25062"
---

# RFC-compaction-summarizer-per-keeper-lane

- Status: Draft
- Boundary: Context compaction summarization is per-Keeper background provider work. Provider concurrency is an OAS endpoint-admission concern, not a MASC one.

## Summary

PR #25062 moved the compaction plan summarizer off each Keeper's own chat
runtime and onto a single shared `structured_judge` runtime so that the 12/16
Keepers on schema-incapable chat models could produce a structured plan. That
removed the schema-eligibility failure. It also routed every Keeper's
compaction through one endpoint with no per-Keeper isolation, which recreates a
cross-Keeper provider slot. Under fleet load the shared endpoint saturates or
degrades, compaction fails intermittently, Keeper histories are never relieved,
and the pre-existing overflow incident (#24838, #25051) returns — now
intermittent and harder to attribute.

This RFC does not propose a new mechanism. It applies two already-decided
boundaries to the compaction summarizer path:

1. RFC-0257 — each Keeper's background provider work (memory extraction,
   storage, **compaction**, forgetting) runs in its own lane and "never
   acquire[s] a fleet-wide permit and never block[s] Keeper B ... There is no
   cross-Keeper provider slot."
2. The withdrawn `shared-admission-primitive-knob-binding-policy` RFC (purged in
   #25131) recorded the ratified boundary: "provider/account concurrency belongs
   to OAS endpoint admission; MASC observes it and keeps each Keeper owner
   runnable. A blocked activity may park, but it may not deny, drop, pause, or
   fleet-serialize other work."

#25062 violates both. The remediation restores per-Keeper compaction and leaves
provider concurrency to OAS endpoint admission.

## Problem (evidence)

Observed on the live fleet 2026-07-17/18 (server build `3b8fa29337`, which
already contains #25062):

- `keeper_compaction_llm_summarizer.ml` builds the plan request by inlining the
  full message list as text (`indexed_messages_text`, `messages_for_plan`,
  `run_plan`), with no windowing. The request grows with the history.
- Compaction fails **intermittently**, not deterministically: `nick0cave`
  chain-exhausted 12:50 then succeeded 13:09; `executor` chain-exhausted 13:51
  (checkpoint 2,062,893 bytes / 1,477 messages) then succeeded 15:18. Same
  Keeper, larger history later, yet later success — the failure tracks load, not
  size alone.
- Dominant provider error is an opaque `Invalid request (unknown): Bad Request`
  from `ollama_cloud.deepseek-v4-flash` on **small** requests
  (`system_and_user_bytes` 10–57 KB, `context=200000` not overflowed), latency
  up to 70 s; plus 747 rate-limit lines that day. The shared `ollama_cloud`
  pool is degraded, not merely oversized.
- Consequence chain: compaction cannot relieve history → `context_budget=262144`
  saturates → `keeper cycle FAILED` (taskmaster ×3,041 that window) → retry
  storm (oas turns ×42,971 at ~18.6 s, `pipeline stage failed` ×41,333, 132 MB
  log/day) → server saturation → unrelated fast MCP calls
  (`masc_pause_status`) time out at 10,000 ms.

The 10 s MCP timeout the operator sees is collateral saturation, not a
compaction-specific limit.

## Root cause

`keeper_compact_policy.ml` seeds the compaction candidate list as
`[structured_judge; own_chat_runtime]` (schema-filtered), and
`Runtime.runtime_id_for_structured_judge` resolves to a single fleet-wide value
(`runtime.toml`), so all 16 Keepers' compaction converges on one endpoint. There
is no per-Keeper lane and no MASC-side or OAS-side backpressure bound on that
endpoint (`max_concurrent_requests` is unset for the native lane). Before
#25062, the four schema-capable Keepers compacted on distinct runtimes; #25062
collapsed them onto the shared one as well.

The merged failure variant `Plan_unavailable_or_invalid` conflates "no
summarizer resolved", "summarizer call failed", and "output failed validation",
so the live logs cannot distinguish which is occurring.

## Contract (what compaction summarization must obey)

1. **Per-Keeper lane (RFC-0257).** Keeper A's compaction runs in A's own ordered
   background lane. It does not acquire a fleet-wide permit and does not block
   Keeper B. A compaction failure parks A's lane; A stays runnable and retries
   on its next cadence.
2. **No MASC-side fleet admission.** MASC does not add a global cardinality cap,
   `Skip_if_full`, or fleet FIFO over compaction. That approach was withdrawn
   (#25131). MASC observes saturation; it does not serialize the fleet on it.
3. **Provider concurrency is OAS endpoint admission.** If the structured lane's
   provider/account needs a concurrency bound, it is declared as OAS endpoint
   admission (`Provider_config.max_concurrent_requests`, #2641) keyed by endpoint
   identity, whose excess parks in FIFO at the OAS boundary. This bounds to what
   the provider accepts; it does not encode a MASC policy.
4. **Bounded input.** A history that exceeds the summarizer context is compacted
   in windows (incremental/hierarchical), not sent whole. Compaction must be
   able to relieve exactly the oversized state it exists to relieve.
5. **Eager trigger.** Compaction fires before the history reaches the provider
   context ceiling, while requests are small and the pool has slack, rather than
   at the overflow edge.
6. **Typed failure.** `Plan_unavailable_or_invalid` is split into distinct
   causes (no-candidate / call-failed / output-invalid) so the failure mode is
   observable.

## Non-goals / explicitly rejected

- A MASC-side fleet-wide concurrency cap on the shared summarizer endpoint. This
  is the pattern withdrawn in #25131; it fleet-serializes independent Keeper
  lanes and does not restore per-Keeper isolation. It is also a cap-workaround
  under the CLAUDE.md workaround bar (symptom suppression without removing the
  convergence).
- Telemetry that counts compaction failures without restoring the lane. Making
  the failure visible is not fixing it (RFC-0149).
- Reverting #25062's schema-eligibility gain. The routing-to-schema-capable
  behavior is kept; what is added is per-Keeper isolation and bounded input.

## Remediation (implementation scope)

1. Compaction summarizer resolution keeps schema filtering (from #25062) but
   dispatches within the originating Keeper's background lane (RFC-0257), so
   contention parks that lane rather than converging the fleet.
2. Window the summarizer input so a >context history compacts in bounded chunks.
   Remove the unbounded `indexed_messages_text` whole-history request.
3. Split the `Plan_unavailable_or_invalid` variant; log the distinct cause at the
   `run_plan` failure site (currently returns `None` silently).
4. Move the compaction trigger earlier (eager), driven by typed compact policy,
   not at the provider ceiling.
5. If the structured lane needs a provider concurrency bound, declare it at the
   OAS endpoint (#2641), not in MASC.

## Verification

- Same-Keeper compaction is FIFO and durable across restart.
- Different Keepers' compaction progresses concurrently; no shared MASC slot.
- A history larger than the summarizer context still compacts (windowed proof).
- Compaction failure surfaces a distinct typed cause, not the merged variant.
- Counterfactual: reverting the per-Keeper lane reintroduces the convergence —
  one Keeper's overflow persists while others hold the shared endpoint. A TLA+
  bug-model action (`FleetConvergedCompaction`) violates a
  `KeeperStaysRunnableUnderPeerCompaction` invariant on the buggy spec and holds
  on the clean spec.
- Under fleet load, no Keeper's context grows unbounded because a peer's
  compaction is in flight.

## Open questions

- Does the structured lane share the same `ollama_cloud` account/pool as the
  chat lanes? If so, dedicated capacity (separate account or reserved slots) may
  be required for compaction to make progress under chat-turn load; a per-Keeper
  lane alone does not add provider capacity.
- The opaque `Invalid request (unknown): Bad Request` on small deepseek-v4-flash
  requests is not explained by size and may be a distinct provider/request-shape
  defect; it is tracked separately from this RFC.
