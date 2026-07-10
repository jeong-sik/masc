# RFC-0260 — Provider health gate and audited failover

- Status: Draft
- Date: 2026-06-19
- Related: RFC-0257 (per-keeper memory lane), RFC-0153 (runtime backpressure and admission)
- Origin: 2026-06-19 product adversarial audit — re-verification of P0-1 (runtime provider control) and P0-4 (librarian).

## Why this exists (and why it is NOT a librarian RFC)

The 2026-06-19 audit raised P0-4 "librarian not trustable." RFC-0257 owns Keeper-local ordering
through `Keeper_memory_lane`. It does not own provider-fleet admission: the later per-Keeper
`with_provider_slot` gate duplicated the lane and discarded extraction after a hardcoded wait, so
it was retired. Provider capacity, health, and fallback belong to this runtime/provider boundary.

What is NOT owned anywhere is the **provider-availability** axis that actually produced the live
residual. After the 2026-06-19 dawn RunPod outage and the 12:25 restart, librarian routing was
correctly on `ollama_cloud.minimax-m3`, yet it still logged `provider returned empty response` /
`timed out`. That residual is downstream of an unmanaged provider outage, so this RFC addresses
provider health and failover, not the librarian.

## Problem

1. **Outage is undetected.** `runpod_mtp` healthcheck is disabled
   (`config/runtime.toml`, comment: "Re-enable after provider_health.ml config wiring"). When
   RunPod returned 404 during the 2026-06-19 dawn window, nothing flagged it automatically; the
   fleet kept routing to a dead provider (`awaiting_provider` day_total 136, first 01:12Z).

2. **Recovery is an untracked manual edit.** A tmux hand-edit of the live runtime.toml redirected
   all 13 keepers + default to `ollama_cloud.deepseek-v4-flash`. That edit was git-untracked for
   hours (reconciled only later by an out-of-band config PR), and **invisible in logs** — provider
   reassignment leaves no audit trail at all (a fresh `assignment_change` log scan returns zero
   events).

3. **Failover overloads the shared librarian pool.** Routing the whole fleet onto `ollama_cloud`
   put every keeper's librarian round-trip onto one provider. Even after `librarian=minimax-m3`
   went live, librarian still logged empty/timeout. A Keeper-local gate cannot represent provider
   capacity; the runtime must expose and enforce that capacity without coupling Keeper lanes.

Net: provider outages are (a) undetected, (b) recovered by untracked manual edits with no audit
trail, (c) followed by degraded dependent subsystems (librarian) until the operator manually
reverts.

## Non-goals

- Keeper-local librarian ordering — owned by RFC-0257. Do not add a second MASC lane or slot.
- Librarian model JSON capability — already fixed (`deepseek-flash` JSON gap → `minimax-m3`, #21521).
- Mutex poison hardening — separate latent-defect concern, scoped out by RFC-0256.

## Design

Three pieces, each on a clean boundary.

### 1. Health probe (deterministic)

- Re-enable `[providers.*.healthcheck]` by wiring `provider_health.ml` (the deferred work the toml
  comment names). A probe result is a pure function of an observed HTTP response: `Healthy |
  Degraded of reason | Down of reason`. No heuristics, no model judgment.
- Probe cadence and timeout are config, not code constants.

### 2. Declarative failover chain (policy)

- `[runtime]` gains an optional ordered `fallback` per binding key, e.g.
  `default_fallback = ["runpod_mtp.qwen36-35b-a3b-mtp", "ollama_cloud.deepseek-v4-flash"]`.
- Selection is deterministic: first chain entry whose health is `Healthy` (or `Degraded` if no
  healthy entry). An empty/exhausted chain is an explicit error surfaced to the operator, never a
  silent local-model fallback (the anti-pattern called out in `software-development.md`
  "Unknown → Permissive Default").
- A health-driven reassignment is a **config-equivalent event**: it writes the same audited record
  a manual change would (see #3), so automatic and manual changes are indistinguishable downstream.

### 3. Audited provider-change ledger (governance — closes P0-1)

- Every default/assignment/librarian/provider change — whether via the existing
  `POST /api/v1/runtime/config/raw` (already `Masc_domain.CanAdmin`-gated), a manual file edit
  detected on load, or an automatic failover — appends one structured log event: `{actor, ts, key,
  from, to, reason, source: api|file|health}`.
- This makes the `assignment_change` incident signal non-empty so operators can answer "when/why
  did routing change" without grepping config history.
- Dashboard surfaces a degraded-provider banner when any active binding's provider is `Down`.

## Boundaries (deterministic / declarative / operator)

- **Deterministic:** health probe verdict (function of HTTP response).
- **Declarative policy:** the fallback chain in config; selection order is data, not code.
- **Operator:** manual override is allowed, but it must produce the same audited ledger event as an
  automatic change (no privileged untracked path). "Ask human" is never a runtime resolver — if no
  healthy provider and no operator decision, the state is explicit `Down`, surfaced, not silently
  routed (consistent with RFC-0254/0255 autonomous-lane Allow/Deny determinism).

## Tests

- Health probe: 200 / empty-body / 404 / timeout responses → `Healthy / Degraded / Down` (table test).
- Failover selection: chain `[down, healthy]` picks healthy; `[down, down]` → explicit error, no
  silent local fallback.
- Ledger: api edit, file edit, and health failover each emit exactly one event with correct
  `source`; an `assignment_change` log scan count matches the number of changes.
- Degraded banner appears iff an active binding provider is `Down`.

## Rollback

Feature-flag the gate (`MASC_PROVIDER_HEALTH_GATE`, default off initially). Off = current behavior
(manual edits, no probe). The ledger is additive (log-only) and can ship first, independently, as
the smallest safe slice.

## Smallest first slice

The ledger (#3, log-only) is the smallest independently-valuable piece: it closes the P0-1
audit-trail gap, is additive, and needs no failover machinery. Ship it before the probe/chain.
