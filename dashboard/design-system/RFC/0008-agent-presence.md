# RFC 0008 — AgentPresence Manager

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation — `IdGenerator`)
- **Independent of**: RFC 0003 / 0005. AgentPresence does not bind
  rover or menu semantics directly; consumer UI may compose them.
- **Blocks**: spec §5.4 — TaskQueue (RFC 0009), CollaborationCursor
  (RFC 0010), InlineSuggestion (RFC 0011) all subscribe to the same
  presence registry.
- **Builds on**: existing 12-slot OkLCH keeper palette (`--k-1` ~
  `--k-12`) and `kSlot(id)` FNV-1a hash assignment.

---

## 1. Motivation

The dashboard already renders Keeper avatars, sigils, and status
indicators across at least four surfaces:

- **Keeper card** (`dashboard/src/components/keeper-card/`) —
  per-keeper avatar + state dot + idle/working badge.
- **Agent monitor** (`dashboard/src/components/agent-monitor/`) —
  fleet-level grid of avatars with pulse animation on active.
- **Lifeline / heartbeat strip** — color band per active keeper.
- **Composer mention dropdown** — `@keeper-name` autocomplete.

Each surface owns its own registry of "which keepers exist, what is
each one doing right now" by polling MASC endpoints or listening to
its own SSE channel. The duplication produces:

- **State drift**: avatar in keeper-card shows `working` while
  agent-monitor shows `idle` for the same keeper, because the two
  panels poll independently and SSE deliveries race.
- **Sigil collision**: when two keepers share the first 2 letters of
  their name, each surface picks its own collision-break suffix.
- **`prefers-reduced-motion` inconsistency**: pulse animation skipped
  in some surfaces, not others.
- **No SR announcements**: keeper state changes are visual-only — a
  screen-reader user gets no signal when a keeper transitions to
  `error`.

This RFC defines a single `createAgentPresenceManager` registry that
owns the canonical roster, state, sigil, color slot, and live cursor
position for every agent. Consumers subscribe and render — they do
not own state.

## 2. Non-Goals

- Render markup. Headless. Consumer owns avatar / dot / pulse DOM.
- Network sync. The manager exposes `update*` methods; the SSE / WS
  bridge is consumer's concern (a thin adapter at the app boundary).
- Replace MASC's keeper roster server-side. The manager mirrors,
  it does not author.
- Keeper RBAC, permissions, identity. Out of scope; this is purely
  presentation state.

## 3. Public API

### 3.1 Core types

```ts
// headless-core/src/agent-presence.ts
export type AgentState =
  | "idle"
  | "working"
  | "thinking"
  | "waiting_for_human"
  | "error"
  | "completed";

export type AgentColorSlot = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12;

export interface AgentSigil {
  /** 2-character display label, uppercase. e.g. "NC", "SS". */
  readonly text: string;
  /** Optional disambiguator when sigil collides. e.g. "NC²". */
  readonly suffix?: string;
}

export interface AgentDescriptor {
  readonly id: string;
  readonly name: string;
  readonly sigil: AgentSigil;
  readonly colorSlot: AgentColorSlot;
}

export interface AgentRuntimeState {
  readonly state: AgentState;
  readonly currentFile?: string;
  readonly cursor?: { readonly line: number; readonly column: number };
  /** ISO timestamp; manager updates on every change. */
  readonly stateChangedAt: string;
  /** ms since last heartbeat; consumer renders "stalled 12m" etc. */
  readonly idleMs?: number;
}

export interface Agent extends AgentDescriptor, AgentRuntimeState {}
```

### 3.2 Manager

```ts
export interface AgentPresenceOptions {
  /** Roster bootstrap. Subsequent register() calls add or replace. */
  initialAgents?: ReadonlyArray<AgentDescriptor>;
  /** Suppress pulse animations etc. via prefers-reduced-motion. */
  reducedMotion?: () => boolean;
  /** Sigil collision policy. Default: collisionSuffixDigits. */
  sigilDisambiguate?: (
    candidate: AgentSigil,
    existing: ReadonlyArray<AgentSigil>,
  ) => AgentSigil;
}

export interface AgentPresenceManager {
  readonly agents: ReadonlyMap<string, Agent>;

  // Roster
  register(agent: AgentDescriptor): void;
  unregister(id: string): void;
  has(id: string): boolean;

  // Runtime updates (consumer wires SSE/WS to these)
  updateState(id: string, state: AgentState): void;
  updateCursor(id: string, file: string, line: number, column: number): void;
  clearCursor(id: string): void;
  heartbeat(id: string): void;  // resets idleMs

  // Queries
  byState(state: AgentState): ReadonlyArray<Agent>;
  withinFile(file: string): ReadonlyArray<Agent>;

  // Subscriptions
  subscribe(listener: (snapshot: ReadonlyArray<Agent>) => void): () => void;
  subscribeAgent(id: string, listener: (agent: Agent) => void): () => void;

  // ARIA helpers
  /** SR announce string for state change: "<name> is now <state>". */
  announceStateChange(id: string, prevState: AgentState): string;
}

export function createAgentPresenceManager(
  opts?: AgentPresenceOptions,
): AgentPresenceManager;
```

### 3.3 Sigil + slot derivation

```ts
// Sigil from name: first 2 alpha chars uppercase.
// Collision: suffix with superscript digit (² ³ ⁴ ...).
export function deriveSigil(name: string): AgentSigil;

// kSlot is the existing FNV-1a mod-12 helper in tokens; re-exported.
export function kSlot(id: string): AgentColorSlot;
```

### 3.4 Preact adapter

```ts
// headless-preact/src/use-agent-presence.ts
export function useAgentPresence(manager: AgentPresenceManager): {
  agents: ReadonlyArray<Agent>;
};

export function useAgent(
  manager: AgentPresenceManager,
  id: string,
): Agent | undefined;

export function useAgentsByState(
  manager: AgentPresenceManager,
  state: AgentState,
): ReadonlyArray<Agent>;
```

## 4. State machine

```
   ┌──────┐  start  ┌─────────┐  hitl    ┌──────────────────┐
   │ idle │────────▶│ working │─────────▶│ waiting_for_human│
   └──────┘         └─────────┘          └──────────────────┘
       ▲                │  │                       │
       │                │  │ think                 │ resume
       │                │  ▼                       ▼
       │           ┌──────────┐                ┌─────────┐
       │           │ thinking │                │ working │
       │           └──────────┘                └─────────┘
       │                │
       │  done          │  fail
       │                ▼
       │           ┌──────────┐ ─────────────────▶ ┌────────┐
       └───────────│ completed│                    │ error  │
                   └──────────┘                    └────────┘
                                                       │
                                                       └──▶ idle (after retry)
```

The manager does not enforce transitions — consumer / backend may
report any next state. The diagram is **descriptive**: it documents
which transitions trigger announcements and which trigger pulse
animations.

| Transition | SR announce | Visual cue |
|---|---|---|
| `* → working` | "<name> is now working" | start pulse |
| `working → thinking` | (silent) | switch to slow pulse |
| `* → waiting_for_human` | "<name> is waiting for your input" | static, brass ring |
| `* → error` | "<name> reported an error" (assertive) | static, err ring |
| `* → completed` | "<name> completed" | static, ok ring |
| `* → idle` | (silent) | static, no ring |

## 5. Colors and accessibility

- **Color slot** comes from `kSlot(agent.id)` (FNV-1a mod 12). Re-using
  the existing keeper palette ensures cross-surface consistency.
- **Color is not the only signal**. Sigil text + state ring style
  carry the same information for color-blind users.
- **`prefers-reduced-motion`**: pulse becomes a static brass ring
  outline; spec text is unchanged.
- **State change announcements**: `announceStateChange()` returns the
  SR string. Consumer wires it into a `role="status"` live region
  attached to the agent monitor surface.
- **Per-agent live region** is not used — the consolidated manager
  region prevents announcement storms when 12 agents change state in
  the same tick.

## 6. Sigil disambiguation

Default `sigilDisambiguate`:

1. Take first 2 alpha chars of `name`, uppercase.
2. If unique vs existing roster, return as-is.
3. Else append superscript digit (`²`, `³`, ...) to the second
   collider, third collider, etc.

Examples:

- "nick0cave" → `NC`
- "nicolas-cage" → `NC²` (registers second)
- "northcat" → `NC³`
- "alice" → `AL`

The function is pluggable (`opts.sigilDisambiguate`) so consumers can
override with workspace conventions.

## 7. Test plan

`headless-core/src/agent-presence.test.ts`:

1. **Register / unregister** — `has(id)` flips true / false; agents
   map updates; subscribers fire.
2. **`updateState`** — agent state flips; `stateChangedAt` updates;
   subscriber fires once.
3. **`announceStateChange`** — returns expected SR string for each
   transition row in §4.
4. **`subscribeAgent` isolation** — listener fires only for its
   own agent.
5. **`byState` / `withinFile`** — filter queries return correct
   subsets.
6. **`updateCursor` / `clearCursor`** — cursor field set and unset.
7. **`heartbeat`** — resets `idleMs` to 0.
8. **`deriveSigil` collision** — third "nick…" agent gets `³`.
9. **`kSlot` determinism** — same id always maps to same slot.
10. **`reducedMotion: () => true`** — no pulse-related metadata in
    snapshots (consumer keys off `agent.state` directly; primitive
    is animation-agnostic, but exposes `reducedMotion()` getter).
11. **High-throughput** — 12 agents × 100 state updates → 1200
    subscriber callbacks, no leaked timers.
12. **Multiple subscriptions** — N listeners receive the same
    snapshot array reference; primitive does not mutate.

`headless-preact/src/use-agent-presence.test.tsx`:

13. **Hook reactivity** — Preact re-renders on state change.
14. **`useAgent` undefined** — returns `undefined` for unknown id,
    no throw.

`jest-axe` against an agent-monitor fixture rendering 12 agents.

## 8. Migration path

Consumer migrations (separate PRs):

1. **Agent monitor grid** — replaces the inline registry with
   `useAgentPresence`. Adds the SR announcement live region.
2. **Keeper card** — `useAgent(id)` instead of local prop.
3. **Lifeline strip** — `useAgentsByState("working")` for the active
   color band.
4. **Composer mention dropdown** — roster from `manager.agents` via
   `useAgentPresence`.

Backend SSE bridge (`dashboard/src/sse/`) receives state events and
calls `manager.updateState(id, state)` once. All four surfaces re-
render via subscriptions.

## 9. Merge criteria

- [ ] `headless-core/src/agent-presence.ts` lands
- [ ] All 12 core tests + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on agent-monitor fixture with 12 agents
- [ ] `headless-preact/src/use-agent-presence.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Agent monitor grid
      recommended — highest visibility)
- [ ] CHANGELOG entry under v0.5
- [ ] Sigil + color slot derivation matches existing keeper palette
      output (no token regen needed)

## 10. Open questions

1. **Should `register()` be idempotent or replace?** Current proposal:
   replace (last register wins). Avoids silent ignore of legitimate
   metadata updates (e.g., name change). Confirm.
2. **Heartbeat staleness threshold** — when does `idleMs > X` flip
   the state to a synthetic `stalled` for UI? Probably consumer-side,
   not manager. Document.
3. **Disconnect / reconnect** — when SSE drops, all agents go where?
   Proposal: leave state as last-known; flag with `idleMs` so UI can
   render "stale 5m". No state mutation. Confirm.

These do not block draft acceptance but must close before the
implementation PR opens.
