# RFC 0010 — CollaborationCursor

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**:
  - RFC 0001 (Headless Foundation — `IdGenerator`)
  - RFC 0008 (AgentPresence — `cursor` field already in `Agent`)
- **Independent of**: RFC 0003 / 0005 / 0009.
- **Blocks**: spec §5.4.2 collaboration UI consumer.
- **References**: Operational Transform synchronization.
  Implementation of OT itself is out of scope; the primitive
  consumes already-resolved cursor positions from a sync layer.

---

## 1. Motivation

When two or more agents act on the same file simultaneously — Cypress
test agent reading + edit agent writing, or two reviewers pointing at
diff hunks — the dashboard today shows nothing. There is no visual
signal that someone else is in the file, no conflict warning when
overlapping edits are queued, and no SR announcement on conflict.

Operators have explicitly asked for the Google Docs / Live Share
pattern: see other agents' cursors with a per-agent color, see when
two agents target the same line, and get an SR alert on conflict.

This RFC defines `createCollaborationManager` as a thin layer over
`AgentPresenceManager`. AgentPresence already carries each agent's
`cursor: { line, column }`; this RFC adds:

- File-scoped grouping (`activeAgentsInFile(path)`).
- Conflict detection (overlapping line ranges).
- ARIA-correct conflict announcements.

## 2. Non-Goals

- Implement Operational Transform. The sync layer (a separate
  `dashboard/src/collab/` module) feeds resolved positions. This RFC
  cares only about presentation primitives.
- Render markup. Cursor blocks, sigil tags, conflict overlays — all
  consumer's concern.
- Edit history / blame. Out of scope; that's a code-review surface.
- Multi-file conflict aggregation. One file at a time; consumer can
  query multiple files independently.

## 3. Public API

### 3.1 Core types

```ts
// headless-core/src/collaboration.ts
import type {
  Agent,
  AgentPresenceManager,
} from "./agent-presence.js";

export interface CursorPosition {
  readonly line: number;     // 1-indexed
  readonly column: number;   // 1-indexed
}

export interface Selection extends CursorPosition {
  /** End position; equal to start when no range selected. */
  readonly end: CursorPosition;
}

export interface AgentCursor {
  readonly agent: Agent;
  readonly file: string;
  readonly position: CursorPosition;
  readonly selection?: Selection;
}

export interface FileConflict {
  readonly file: string;
  /** Line range with at least 2 agents present. */
  readonly lineFrom: number;
  readonly lineTo: number;
  readonly agents: ReadonlyArray<Agent>;
}
```

### 3.2 Manager

```ts
export interface CollaborationOptions {
  /** AgentPresenceManager source of cursor state. */
  presence: AgentPresenceManager;
  /** Lines counted as a "conflict zone" around each cursor.
   *  Default: 3 (cursor line ± 1). */
  conflictRadius?: number;
}

export interface CollaborationManager {
  /** All agents whose cursor is currently in `file`. */
  activeAgentsInFile(file: string): ReadonlyArray<AgentCursor>;

  /** Detect overlapping cursor zones in a file. */
  conflictsInFile(file: string): ReadonlyArray<FileConflict>;

  /** Record a selection (range edit). Falls back to position when
   *  end == start. */
  setSelection(agentId: string, file: string, sel: Selection): void;

  /** Returns the SR announcement text for a new conflict. */
  announceConflict(conflict: FileConflict): {
    readonly text: string;
    readonly assertive: true;  // always — conflict is high signal
  };

  // Subscriptions
  subscribeFile(
    file: string,
    listener: (cursors: ReadonlyArray<AgentCursor>) => void,
  ): () => void;

  subscribeConflicts(
    listener: (conflicts: ReadonlyArray<FileConflict>) => void,
  ): () => void;
}

export function createCollaborationManager(
  opts: CollaborationOptions,
): CollaborationManager;
```

### 3.3 Preact adapter

```ts
// headless-preact/src/use-collaboration.ts
export function useFileCursors(
  manager: CollaborationManager,
  file: string,
): ReadonlyArray<AgentCursor>;

export function useFileConflicts(
  manager: CollaborationManager,
  file: string,
): ReadonlyArray<FileConflict>;
```

## 4. Conflict detection

Two agents conflict when their cursor zones overlap. Cursor zone
defaults to `[cursor.line - 1, cursor.line + 1]` (radius 1, 3 lines
total). Selections expand to `[selection.line - 1, selection.end.line + 1]`.

Algorithm:

1. Group active agents by `file`.
2. Within each file, sort by zone start.
3. Sweep: emit a `FileConflict` whenever two or more zones overlap.
4. Merge contiguous overlap zones into a single `FileConflict`.

This produces O(N log N) per file where N is concurrent agents in
that file (typically ≤ 12 per file).

`conflictRadius: 0` makes only **same-line** overlap a conflict.

## 5. Cursor color and identification

- Color comes from `agent.colorSlot` → `--k-N` token already on the
  page.
- Sigil text follows the cursor as a small floating label (consumer's
  CSS responsibility).
- Selection range gets a translucent fill of the same color
  (`rgba(<k-N>, 0.15)` style, but consumer composes the RGB).
- Conflict zone gets diagonal stripes of the two agents' colors —
  again, consumer renders.

## 6. Accessibility

Each cursor element carries:

- `aria-label="<agent.name> editing line N column M"`.
- `role="img"` if the cursor is purely decorative; `role="presentation"`
  if the consumer has a separate text channel.
- `pointer-events: none` (consumer rule) so the editor's text
  selection is not blocked.

Conflict announcement:

- Connected to a `role="alert"` live region in the editor surface.
- Manager emits one announcement per *new* conflict (not per
  cursor move within an existing conflict).
- Text format: "Editing conflict between <name1> and <name2> on
  lines N–M of <basename>".
- 3+ agent conflicts: "Editing conflict between <name1>, <name2>,
  and 1 other on lines N–M".

## 7. Test plan

`headless-core/src/collaboration.test.ts`:

1. **No conflict** — two agents in different files → no conflict
   emitted, both visible in their respective `activeAgentsInFile`.
2. **Same-line conflict** — two agents at line 42 / column varies →
   conflict on lines 41–43 (radius 1).
3. **Selection conflict** — agent A line 10–20 + agent B line 18 →
   conflict 9–21.
4. **Three-agent conflict** — three agents overlapping → single
   `FileConflict.agents` length 3.
5. **Disjoint after move** — agents originally in conflict, one
   moves to line 100 → conflict subscriber fires with empty list.
6. **`announceConflict` 2 agents** — text matches §6 format.
7. **`announceConflict` 3+ agents** — "and N other(s)" suffix.
8. **`subscribeFile` isolation** — moves in file A do not fire
   listeners for file B.
9. **Same-line radius 0** — `conflictRadius: 0` emits only when
   exact line match.
10. **Cursor clear** — `presence.clearCursor` removes the agent from
    `activeAgentsInFile`.
11. **Scale** — 12 agents distributed across 6 files, 100 cursor
    moves: subscriber fires once per move; conflict subscriber fires
    only when overlap state changes.
12. **AgentPresence integration** — cursor updates flow through the
    presence manager only; no direct write API.

`headless-preact/src/use-collaboration.test.tsx`:

13. **`useFileCursors` reactivity** — Preact re-renders on cursor
    move.
14. **`useFileConflicts` no spam** — re-renders only on conflict-set
    change, not on every cursor move within an existing conflict.

`jest-axe` against an editor fixture with 3 cursors and 1 conflict
zone.

## 8. Migration path

This is a green-field primitive — no current consumer to migrate.
First consumer is the editor (Stage 5 IdePlane). Until then:

1. Implementation PR includes a Storybook-style preview at
   `dashboard/design-system/preview/collaboration.html` to demo
   cursor + conflict rendering.
2. Editor (Iter 21) consumes the manager when CodeEditor lands.

## 9. Merge criteria

- [ ] `headless-core/src/collaboration.ts` lands
- [ ] All 12 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on editor fixture
- [ ] `headless-preact/src/use-collaboration.ts` lands
- [ ] Preview page demonstrates 3 cursors + 1 conflict
- [ ] CHANGELOG entry under v0.5
- [ ] RFC 0008 implementation merged first

## 10. Open questions

1. **Conflict radius default** — 1 (3 lines) is conservative.
   Operators viewing a 100-line function may want radius 5. Per-
   instance config covers this; default value confirmation needed.
2. **Latency tolerance** — should the manager debounce cursor
   subscriptions to avoid 60 fps re-renders during continuous typing?
   Current proposal: no debouncing in primitive — consumer wraps if
   needed. Confirm.
3. **Conflict "owner" semantics** — when only 2 agents overlap, can a
   priority order be derived (e.g. earlier `stateChangedAt` wins)?
   Useful for "who is *editing* vs who is *reading*". Defer until OT
   layer surfaces this signal.

These do not block draft acceptance but must close before the
implementation PR opens.
