# RFC 0011 — InlineSuggestion

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**:
  - RFC 0001 (Headless Foundation — `IdGenerator`)
  - RFC 0008 (AgentPresence — suggestion attribution color)
- **Independent of**: RFC 0003 / 0005 / 0009 / 0010.
- **Blocks**: spec §5.4.3 InlineSuggestion editor surface (Iter 22+).
- **References**: GitHub Copilot inline suggestions, JetBrains Smart
  Step Into. The visual model is well-established; this RFC adapts
  it to multi-agent attribution.

---

## 1. Motivation

Agents in MASC can propose code changes — a one-line refactor, a
type annotation, a missing import. Today these proposals surface as
diff blobs in a separate review pane that the user has to navigate
to. The cost: agents make small, high-confidence proposals that get
buried under bigger ones, and the round-trip from "agent suggests"
to "user accepts" is too slow.

The IDE plane (Stage 5) needs an inline mechanism: render the
suggestion **at the change site** with diff hue, accept on Tab,
reject on Esc. Multiple agents can propose against the same range,
in which case the user picks one (or rejects all) — solved by the
existing 12-slot keeper color carrying through to the suggestion
attribution stripe.

This RFC defines `createInlineSuggestionManager` to coordinate
suggestions across the editor surface, plus `createInlineSuggestion`
for individual proposal tracking.

## 2. Non-Goals

- Compute the diff. Consumer (or the LSP / agent layer) provides the
  resolved before/after text. Manager only stores it.
- Render the diff. Consumer handles per-line `+` / `-` markup.
- LLM streaming. Suggestions are atomic objects; partial-typing UI is
  consumer's concern.
- Persistent suggestion history. Once rejected or accepted, the
  suggestion is gone from manager memory.
- Suggestion *application* (writing to file). Manager fires
  `onAccept(suggestion)`; consumer writes.

## 3. Public API

### 3.1 Core types

```ts
// headless-core/src/inline-suggestion.ts
export interface SuggestionRange {
  readonly file: string;
  /** Inclusive start line, 1-indexed. */
  readonly fromLine: number;
  /** Exclusive end line; equal to fromLine+N for an N-line block. */
  readonly toLine: number;
}

export interface InlineSuggestion {
  readonly id: string;
  readonly agentId: string;            // RFC 0008 cross-ref
  readonly range: SuggestionRange;
  /** Original lines in the buffer. */
  readonly before: ReadonlyArray<string>;
  /** Proposed replacement lines. */
  readonly after: ReadonlyArray<string>;
  /** Optional rationale / commit message blurb. */
  readonly rationale?: string;
  /** Confidence 0..1. Higher = consumer should rank higher. */
  readonly confidence: number;
  readonly createdAt: string;  // ISO
}
```

### 3.2 Manager

```ts
export interface InlineSuggestionOptions {
  /** Fires when user accepts. */
  onAccept?: (suggestion: InlineSuggestion) => void;
  /** Fires when user rejects (Esc or explicit). */
  onReject?: (suggestion: InlineSuggestion) => void;
  /** Auto-reject after Nms with no interaction. 0 = persistent.
   *  Default 30000. */
  ttlMs?: number;
}

export interface InlineSuggestionManager {
  // Mutations
  propose(s: Omit<InlineSuggestion, "id" | "createdAt">): string;  // returns id
  retract(id: string): void;
  accept(id: string): void;
  reject(id: string): void;

  // Queries
  getAll(): ReadonlyArray<InlineSuggestion>;
  inFile(file: string): ReadonlyArray<InlineSuggestion>;
  /** All suggestions whose range overlaps the given line range. */
  inRange(file: string, fromLine: number, toLine: number): ReadonlyArray<InlineSuggestion>;
  /** Highest-confidence suggestion overlapping a given line, if any. */
  topAtLine(file: string, line: number): InlineSuggestion | undefined;

  // Subscriptions
  subscribeFile(
    file: string,
    listener: (suggestions: ReadonlyArray<InlineSuggestion>) => void,
  ): () => void;
}

export function createInlineSuggestionManager(
  opts?: InlineSuggestionOptions,
): InlineSuggestionManager;
```

### 3.3 Per-suggestion controller (DOM bind)

```ts
export interface SuggestionController {
  readonly suggestion: InlineSuggestion;

  /** Spread on the outer suggestion element. */
  getRootProps(): {
    readonly id: string;
    readonly role: "region";
    readonly "aria-label": string;
    readonly "aria-keyshortcuts": "Tab Escape";
    readonly "data-state": "suggested";
    readonly "data-agent-color": string;  // --k-N
    readonly tabIndex: 0;
    readonly onKeyDown: (e: KeyboardEvent) => void;
  };

  getAcceptButtonProps(): {
    readonly type: "button";
    readonly "aria-label": string;
    readonly "aria-keyshortcuts": "Tab";
    readonly onClick: () => void;
  };

  getRejectButtonProps(): {
    readonly type: "button";
    readonly "aria-label": string;
    readonly "aria-keyshortcuts": "Escape";
    readonly onClick: () => void;
  };

  /** TTL countdown helper for consumer animations. */
  readonly remainingMs: number;
}

export function createSuggestionController(
  manager: InlineSuggestionManager,
  suggestionId: string,
): SuggestionController;
```

### 3.4 Preact adapter

```ts
// headless-preact/src/use-inline-suggestion.ts
export function useFileSuggestions(
  manager: InlineSuggestionManager,
  file: string,
): ReadonlyArray<InlineSuggestion>;

export function useSuggestionController(
  manager: InlineSuggestionManager,
  suggestionId: string,
): SuggestionController;
```

## 4. Keyboard contract

When focus is inside the suggestion region:

| Key | Effect |
|---|---|
| `Tab` | accept, fires `onAccept`, removes from manager |
| `Escape` | reject, fires `onReject`, removes from manager |
| `Ctrl/Cmd+Space` | (consumer-defined) — explicitly request next suggestion |

Tab behavior is **non-standard** — Tab usually moves focus, not
accepts. The override only applies when focus is in a `data-state="suggested"`
region; consumers must guard with `data-suggested-active` or similar
to prevent stealing Tab in the surrounding form context. The W3C
ARIA APG explicitly permits role-specific Tab semantics (combobox
picker, tree expand) so the precedent is solid.

`aria-keyshortcuts="Tab Escape"` is exposed so SR users can hear the
binding when the region focuses.

## 5. Multi-agent suggestions on the same range

- Manager allows multiple suggestions at overlapping ranges. They are
  all stored.
- `topAtLine(file, line)` returns the highest-confidence suggestion.
  Consumer's default render: only the top one inline; show a `+N`
  indicator for additional suggestions, expandable into a Menu (RFC
  0005) listing all.
- Accepting one suggestion at a range automatically rejects the
  others at the same range. Manager fires `onReject` for each.
- Rejection of one keeps others; user can step through.

## 6. Attribution

Each suggestion's outer region carries `data-agent-color="<--k-N>"`
where N is `agent.colorSlot` of the proposing agent. Tailwind v4
selector `data-[agent-color=--k-3]:border-l-[var(--k-3)]` (or
similar) colors the left border. The accept / reject buttons use
neutral chrome — not the agent color — to avoid misleading "accept
this color" affordances.

`aria-label` of the region includes agent attribution:

> "Suggestion from <agent.name>: replace lines 42–45. Press Tab to
> accept or Escape to reject."

## 7. TTL

Default 30 s. After expiry the suggestion is auto-rejected and removed.
Consumer animation hooks: `remainingMs` updates via subscription, so
a circular progress indicator can wind down.

`ttlMs: 0` disables auto-rejection — used for "manual review" flows
where the user wants to weigh several suggestions across files
before deciding.

## 8. Test plan

`headless-core/src/inline-suggestion.test.ts`:

1. **Propose returns id** — id is a stable string from IdGenerator.
2. **Accept fires callback** — `accept(id)` triggers `onAccept`,
   removes from `getAll()`.
3. **Reject fires callback** — same with `onReject`.
4. **TTL auto-reject** — set `ttlMs: 100`, wait → `onReject` fires
   automatically, suggestion removed.
5. **TTL 0 persistent** — never auto-rejects.
6. **`inRange` overlap** — two suggestions at lines 10-15 and 13-20
   both returned by `inRange(file, 12, 16)`.
7. **`topAtLine`** — multiple suggestions at line 12, highest
   `confidence` returned.
8. **Same-range mutual reject on accept** — two suggestions at
   lines 10-15: accepting one fires `onReject` for the other.
9. **`subscribeFile`** — listener fires on propose / retract / accept
    / reject in that file only.
10. **`retract` silent** — retraction doesn't fire `onReject`.
11. **Controller `aria-label`** — includes agent name + line range +
    keyboard hint.
12. **`data-agent-color` attribute** — matches `--k-<colorSlot>`.

`headless-preact/src/use-inline-suggestion.test.tsx`:

13. **Hook reactivity** — Preact re-renders on propose / retract.
14. **Tab accepts** — synthetic Tab keydown on root → `onAccept`
    fires. Esc → `onReject`.

`jest-axe` against suggestion fixture (1 region with accept + reject
buttons).

## 9. Migration path

Green-field primitive. First consumer is editor (Iter 22, after
CodeEditor mount in Iter 21). Until then:

1. Preview page at `dashboard/design-system/preview/inline-suggestion.html`
   demonstrates Tab-accept / Esc-reject + diff hue + agent color
   stripe. No editor required.
2. Editor consumer follows in Iter 22 PR.

## 10. Merge criteria

- [ ] `headless-core/src/inline-suggestion.ts` lands
- [ ] All 12 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on suggestion fixture
- [ ] `headless-preact/src/use-inline-suggestion.ts` lands
- [ ] Preview page demonstrates the primitive
- [ ] CHANGELOG entry under v0.5
- [ ] RFC 0008 implementation merged first
- [ ] Diff colors use existing `--diff-add` / `--diff-del` tokens (no
      new tokens needed)

## 11. Open questions

1. **Tab override scope** — exactly which DOM ancestor is the
   `data-suggested-active` boundary? Editor root, or the suggestion
   region itself? Affects whether typing inside an inline editable
   field steals Tab.
2. **Confidence threshold display** — should sub-threshold (< 0.3)
   suggestions render at all? Probably yes but with reduced
   prominence. Consumer detail; primitive is threshold-agnostic.
3. **Cross-file batched suggestions** — if one agent proposes a
   coordinated 3-file refactor, are those 3 separate suggestions or
   one bundle? Current proposal: 3 separate, each with the same
   `rationale`. Bundle UX is a follow-up.

These do not block draft acceptance but must close before the
implementation PR opens.
