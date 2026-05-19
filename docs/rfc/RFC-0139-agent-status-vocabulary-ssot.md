---
rfc: "0139"
title: "Agent Status Vocabulary SSOT"
status: Draft
created: 2026-05-19
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0135"]
implementation_prs: [16698, 16707, 16708, 16711, 16714]
---

# RFC-0139 — Agent Status Vocabulary SSOT

## §1 Problem

RFC-0135 (Dashboard Keeper Operational SSOT) consolidated **keeper.status** / **keeper.phase** classification into typed `KeeperOperationalState` plus primitive predicates (`isKeeperPaused`, `isKeeperOffline`, etc.) in `dashboard/src/lib/keeper-predicates.ts`.

**Agent.status** is a *parallel* string vocabulary that the audit 2026-05-19 §A6 identified as a separate-but-overlapping SSOT gap:

```ts
agent.status === 'active' | 'busy' | 'offline' | 'inactive' | 'retired'
```

Discovered callsites (8 production, audit Goal-2/Axis-A6):

| File | Line | Usage |
|------|------|-------|
| `dashboard/src/live-store.ts` | 76, 117-120 | direct `agent.status === 'active'\|'busy'` comparisons |
| `dashboard/src/components/ide/keeper-presence-store.ts` | 113 | presence-status branching |
| `dashboard/src/components/ide/ide-presence-strip.ts` | 57, 330 | presence-dot color |
| `dashboard/src/components/activity-graph-view.ts` | 17, 104, 271 | activity bucketing |
| `dashboard/src/components/overview/overview.ts` | 469, 565 | session.status tone — *adjacent vocab*, possibly shared |
| `dashboard/src/components/governance.ts` | 94, 220, 462 | judge.status — *separate vocab* but vocab-overlapping (`'offline'`, `'stale_visible'`, `'backoff'`) |

`lib/keeper-predicates.ts:52 isOfflineStatus` already exists as a *keeper-domain* predicate. It happens to accept the same `'offline' | 'inactive' | 'unbooted'` string set that several agent callsites also use — accidental overlap, not intentional sharing.

## §2 Vocab boundary question

The three vocabularies overlap on the string `'offline'` but diverge elsewhere:

| Vocab | Domain | Distinct tokens |
|-------|--------|-----------------|
| **keeper.status** | dashboard keeper-runtime registry | `'active' \| 'idle' \| 'busy' \| 'paused' \| 'offline' \| 'inactive' \| 'unbooted' \| 'stopped' \| 'listening' \| 'working'` |
| **agent.status** | live agent presence registry | `'active' \| 'busy' \| 'offline' \| 'inactive' \| 'retired'` |
| **judge.status** | governance judge runtime | `'active' \| 'offline' \| 'stale_visible' \| 'backoff'` |

A keeper and the agent it backs may legitimately disagree on status (an agent is `retired` while its keeper is still `Stopped` in the registry mid-shutdown). Forcing one shared vocabulary loses that distinction; leaving three independent string sets means three places will silently drift apart on `'offline'`-class transitions.

## §3 Options (decision required from author)

### Option A — Strict separation (3 typed sums, 3 predicate modules)

Three closed sums emitted from one module each. No string overlap (the predicates take the typed value, never the raw string). Conversion at the wire boundary only.

```ts
// lib/keeper-status.ts (existing — already promoted by RFC-0135)
export type KeeperStatus = ...
export function isKeeperOffline(k: Keeper): boolean

// lib/agent-status.ts (NEW)
export type AgentStatus = 'active' | 'busy' | 'offline' | 'inactive' | 'retired'
export function isAgentOffline(a: Agent): boolean
export function isAgentActive(a: Agent): boolean

// lib/judge-status.ts (NEW)
export type JudgeStatus = 'active' | 'offline' | 'stale_visible' | 'backoff'
export function isJudgeOffline(j: Judge): boolean
```

**Tradeoff**: explicit boundaries, but offline-class transitions need 3 parallel updates if the backend emits a new "off" token.

### Option B — Unified runtime-presence SSOT

Single `RuntimePresence` typed sum across keepers, agents, judges. One predicate set. Backend wire-format mapping is per-domain at the schema boundary.

```ts
// lib/runtime-presence.ts (NEW)
export type RuntimePresence = 'active' | 'busy' | 'offline' | 'transient_off'
export function isOffline(p: RuntimePresence): boolean
```

**Tradeoff**: single source for offline-class logic, but loses domain-specific distinctions (`retired` vs `Stopped`, `stale_visible` vs `Dead`).

### Option C — Lightweight: rename `isOfflineStatus` → `isAgentRuntimeOffline`, no other change

The existing `lib/keeper-predicates.ts:52 isOfflineStatus` is, by string-set inspection, an *agent* status predicate misfiled in keeper-predicates. Rename + relocate to `lib/agent-status.ts`; keeper-predicates re-exports for compat. 7-10 callsites migrate to the new name; no new types.

**Tradeoff**: minimal scope, no boundary decision; keepers and agents still share the same string vocab informally.

## §4 Recommendation

**Option A**, scoped to phases:

1. **Phase 0** (this RFC) — accept the typed-sum direction.
2. **Phase 1** — extract `lib/agent-status.ts` with `AgentStatus` closed sum + `isAgentOffline` / `isAgentActive` predicates. Migrate 8 callsites. ~150 LoC.
3. **Phase 2** — extract `lib/judge-status.ts` with `JudgeStatus` + predicates. Migrate 3 callsites. ~80 LoC.
4. **Phase 3** — lint guard in `scripts/lint/dashboard-ssot-keeper-state.sh` for new direct `agent.status === '<literal>'` comparisons, mirroring RFC-0135 §9-1.

Phase 1 is the load-bearing PR. Phases 2 and 3 are independent and can ship out of order after Phase 1.

## §5 Out of scope

- **Backend OCaml status types** (`lib/server/agent_registry.ml`, etc.) — wire-format strings are emitted directly. A typed sum on the OCaml side would mirror Phase 1 but is a separate RFC.
- **session.status** in `components/overview/overview.ts` — adjacent vocab, possibly shared with agent. Audit deferred classification to this RFC. Will inspect during Phase 1 implementation; if shared, fold into Phase 1; if distinct, separate Phase 2 alongside judge.

## §6 Migration order

Phase 1 PR sequence:
1. **PR-1a** — `lib/agent-status.ts` module + tests (no callsite migration). Reviewers can verify the typed sum independently.
2. **PR-1b** — migrate `live-store.ts` + `keeper-presence-store.ts` (3 callsites).
3. **PR-1c** — migrate `activity-graph-view.ts` + `ide-presence-strip.ts` (5 callsites).
4. **PR-1d** — lint gate (§9-1b mirror) + remove deprecated `isOfflineStatus` from `keeper-predicates.ts`.

## §7 Decision points (author input needed)

1. **Option A / B / C** — author preference for boundary strategy.
2. **`isOfflineStatus` deprecation timeline** — Phase 1 immediate vs gradual.
3. **session.status classification** — inspect-and-decide-in-Phase-1 OK, or pre-classify now?

Author response on the GitHub PR thread or RFC body update before Phase 1 PR-1a starts.
