# RFC 0004 — SplitPane (`useMove` primitive)

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation — `IdGenerator`, `FocusScope`)
- **Consumes**: `--panel-resize-handle`, `--panel-resize-handle-hover` (added in
  PR `feature/ds-v2-ide-chrome-tokens`)
- **Blocks**: IdePlane (Stage 5), v2 Iter 14 SplitPane consumer

---

## 1. Motivation

The IDE plane is a 3-pane layout: TreeView · Editor · AgentPresence,
optionally with a Terminal pane spanning the bottom. The `ide-v2-body`
CSS grid already declares the row/column tracks, but two needs remain
unmet:

1. **User-resizable panes**. The CSS grid tracks are static at 25% / 1fr /
   28%. Operators consistently want to widen the file tree when paths
   are long, or widen the agent pane when many keepers are active.
   Without a draggable splitter, MASC requires a code change for each
   layout preference.
2. **Persistence**. Once resized, the layout should survive reload —
   per-user, per-pane.

Both needs collapse into one primitive: a headless splitter whose
position controls a clamped ratio, persisted to `localStorage`, with
keyboard parity (`role="separator"` + `aria-valuenow`). Six other
candidate consumers exist (Drawer width-snap, Chat input height,
Composer height, Inspector width, KPI strip collapse, Modal corner
resize), so the primitive earns its place even before IdePlane lands.

The primitive's name in spec §3.2.5 / §3.3.1 is `useMove`; this RFC
names the public API `createSplitPane` for the controller and exposes
a thin `useMove` core for general drag-coordinate tracking.

## 2. Non-Goals

- Render markup. Headless. Consumer owns DOM, including the visible
  splitter graphic.
- 3-way splits as a single primitive. The 3-pane IDE layout is *two
  composed `SplitPane` instances*, not a special case.
- Touch / pen / mouse-button distinctions. The primitive consumes
  pointer events as a single stream; multi-touch is out.
- Panel mount/unmount semantics. A collapsed pane stays in DOM with
  `aria-hidden="true"` until the consumer chooses to unmount.

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/split-pane.ts
export interface SplitPaneOptions {
  /** Layout axis. horizontal = left/right split. */
  direction: "horizontal" | "vertical";
  /** Clamped to [minRatio, maxRatio]. Default 0.5. */
  defaultRatio?: number;
  /** Minimum size of the FIRST pane as a ratio. Default 0.1. */
  minRatio?: number;
  /** Maximum size of the FIRST pane as a ratio. Default 0.9. */
  maxRatio?: number;
  /** localStorage key. When set, getRatio reads on construct and
   *  setRatio writes after handlePointerUp / handleKeyDown / setRatio. */
  persistKey?: string;
  /** Fires on every ratio change (including drag in-progress). */
  onResize?: (ratio: number) => void;
  /** ARIA label for the splitter. Default: "Panel resize handle". */
  ariaLabel?: string;
}

export interface SplitPane {
  // State
  getRatio(): number;
  setRatio(ratio: number): void;
  isCollapsed(): boolean;
  collapse(side: "first" | "second"): void;
  expand(): void;

  // ARIA props for the splitter element
  getSplitterProps(): {
    readonly role: "separator";
    readonly "aria-label": string;
    readonly "aria-orientation": "horizontal" | "vertical";
    readonly "aria-valuenow": number;  // [0, 100]
    readonly "aria-valuemin": number;
    readonly "aria-valuemax": number;
    readonly tabIndex: 0;
  };

  // Container size injection (consumer measures with ResizeObserver)
  setContainerSize(px: number): void;

  // Pointer handlers (consumer wires these to DOM events)
  handlePointerDown(event: { clientX: number; clientY: number }): void;
  handlePointerMove(event: { clientX: number; clientY: number }): void;
  handlePointerUp(): void;

  // Keyboard handler (Arrow / Home / End / Enter)
  handleKeyDown(event: { key: string; shiftKey: boolean; preventDefault(): void }): void;

  // Subscribe to ratio changes (controller-controlled re-render)
  subscribe(listener: (ratio: number, collapsed: boolean) => void): () => void;
}

export function createSplitPane(opts: SplitPaneOptions): SplitPane;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-split-pane.ts
export interface UseSplitPaneArgs extends SplitPaneOptions {
  containerRef: RefObject<HTMLElement>;
}

export interface UseSplitPaneResult {
  ratio: number;
  collapsed: boolean;
  setRatio: (ratio: number) => void;
  collapse: (side: "first" | "second") => void;
  expand: () => void;
  splitterProps: JSX.HTMLAttributes<HTMLElement>;
  /** Convenience: inline style for first pane (`flex-basis` or `width`). */
  firstPaneStyle: { readonly flexBasis: string };
  secondPaneStyle: { readonly flexBasis: string };
}

export function useSplitPane(args: UseSplitPaneArgs): UseSplitPaneResult;
```

The hook owns the `ResizeObserver` for `containerRef.current`,
forwards size into `setContainerSize`, and binds pointer/keyboard
handlers from `splitterProps`. Re-renders on ratio change via the
`subscribe` callback.

## 4. Keyboard contract

Step sizes follow the W3C ARIA APG separator pattern:

| Key | `direction: horizontal` | `direction: vertical` | Effect |
|---|---|---|---|
| `ArrowRight` | step | (no-op) | `ratio += step` (toward second pane) |
| `ArrowLeft`  | step | (no-op) | `ratio -= step` |
| `ArrowDown`  | (no-op) | step | `ratio -= step` (top pane shrinks) |
| `ArrowUp`    | (no-op) | step | `ratio += step` |
| `+ Shift` modifier | × | × | `step = 0.10` (default 0.02) |
| `Home` | clamp to `minRatio` | clamp to `minRatio` | "shrink first pane fully" |
| `End`  | clamp to `maxRatio` | clamp to `maxRatio` | "expand first pane fully" |
| `Enter` | toggle collapse | toggle collapse | collapse to whichever side is closer |

`Tab` and `Shift+Tab` exit the splitter via natural focus order — the
splitter does not trap.

## 5. Persistence

`persistKey` opts in. Convention: `masc.split-pane.<id>` (e.g.
`masc.split-pane.ide-tree`, `masc.split-pane.ide-terminal`).

Read order on construct:

1. `localStorage.getItem(persistKey)` parsed as float.
2. If parse succeeds AND value ∈ [`minRatio`, `maxRatio`], use it.
3. Else fall back to `defaultRatio`.

Write conditions: `setRatio`, end of drag (`handlePointerUp`),
`handleKeyDown` (after every step). Collapse / expand do **not**
persist the collapsed ratio — they preserve `prevRatio` so expand
restores the user's prior position.

`persistKey: undefined` makes the controller stateless across reloads.

## 6. Composition with `FocusScope`

`SplitPane` is content-focusable, not a focus trap. It does not call
`FocusScope`. Behavior in modal contexts:

```
DialogOverlay (FocusScope active)
  └── SplitPane (splitter has tabIndex=0)
        ├── first pane content (focusable normally)
        └── second pane content (focusable normally)
```

Tab visits the splitter as one of the focusable stops. Inside a
Dialog's `FocusScope`, the splitter is part of the trapped Tab cycle
naturally — no special integration code.

## 7. Three-way IDE layout (consumer pattern)

```ts
const outer = useSplitPane({
  direction: "horizontal",
  persistKey: "masc.split-pane.ide-tree",
  defaultRatio: 0.25,
  minRatio: 0.15,
  maxRatio: 0.5,
  containerRef: ideRootRef,
});

const inner = useSplitPane({
  direction: "horizontal",
  persistKey: "masc.split-pane.ide-agent",
  defaultRatio: 0.78,  // editor / agent within the right region
  minRatio: 0.5,
  maxRatio: 0.9,
  containerRef: ideRightRef,
});

const term = useSplitPane({
  direction: "vertical",
  persistKey: "masc.split-pane.ide-terminal",
  defaultRatio: 0.7,   // editor vs terminal
  minRatio: 0.3,
  maxRatio: 0.95,
  containerRef: ideMainRef,
});
```

Three controllers, three persisted keys, no shared state. Each
splitter emits one pointer/keyboard handler bundle.

## 8. Test plan

`headless-core/src/split-pane.test.ts`:

1. **Default ratio** — `getRatio()` returns `defaultRatio` on construct,
   no localStorage entry written.
2. **Persist round-trip** — write `0.42`, recreate with same
   `persistKey`, `getRatio()` returns `0.42`.
3. **Persist clamp** — corrupt `localStorage` value (`"NaN"`, `"-1"`,
   `"2"`) falls back to `defaultRatio`, no crash.
4. **Drag horizontal** — pointerDown at center, move +200px in 800px
   container, ratio increases by 0.25. clamp at `maxRatio`.
5. **Drag vertical** — same with Y axis, sign flipped.
6. **Pointer up persists** — drag end writes `localStorage`.
7. **Pointer up without down** — no-op, no write.
8. **Keyboard step** — `ArrowRight` on horizontal increments by
   `0.02`; `Shift+ArrowRight` increments by `0.10`.
9. **Home / End** — clamp to min / max, persist.
10. **Enter toggle collapse** — collapse → ratio at boundary,
    `isCollapsed()` true; expand → restored to `prevRatio`.
11. **ARIA props** — `aria-valuenow` rounds to integer percent,
    `aria-orientation` matches `direction`, `tabIndex: 0`.
12. **subscribe / unsubscribe** — listener fires on every ratio change,
    including drag in-progress; unsubscribe stops invocations.

`headless-preact/src/use-split-pane.test.tsx`:

13. **ResizeObserver wiring** — container size change updates
    pointer-move math.
14. **`firstPaneStyle.flexBasis`** — formatted as `<percent>%` with
    `Math.round`.
15. **Three-way composition** — outer + inner + term render
    independently, no key collision.

`jest-axe` runs against a 2-pane fixture and must pass with zero
violations.

## 9. Merge criteria

- [ ] `headless-core/src/split-pane.ts` lands with all 12 core tests
- [ ] `headless-preact/src/use-split-pane.ts` lands with all 3 hook tests
- [ ] `jest-axe` passes on 2-pane fixture
- [ ] One consumer migrates in the same PR — recommended:
      `dashboard/src/components/inspector/inspector-resize.ts` (current
      hand-rolled width drag handler)
- [ ] CHANGELOG entry under v0.5
- [ ] Visual splitter graphic uses `--panel-resize-handle` /
      `--panel-resize-handle-hover` (added in
      `feature/ds-v2-ide-chrome-tokens`)
- [ ] No new hand-written CSS — visible state via `data-dragging`,
      `data-collapsed`

## 10. Open questions

1. **`step` size default** — 0.02 (≈2%) per arrow press is the spec's
   "10px on 500px container" approximation. Some operators may prefer
   1% for finer control, with `Shift` for coarser. Confirm before
   freezing.
2. **`Enter` collapse direction** — "toggle collapse to whichever side
   is closer" requires defining "closer" deterministically. Proposal:
   if `ratio < (minRatio + maxRatio) / 2` collapse first; else
   collapse second. Document in test §10.
3. **3-pane keyboard navigation between splitters** — when two
   splitters share a parent, `Tab` order is DOM order. Does that match
   user expectation, or should the IDE wrap them in a `FocusScope`
   roving rover? Defer to consumer-side decision; no primitive change.

These do not block draft acceptance but must close before the
implementation PR opens.
