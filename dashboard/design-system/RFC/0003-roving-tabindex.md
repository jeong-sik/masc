# RFC 0003 — Roving Tabindex Primitive

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation)
- **Blocks**: Tabs, TreeView, Toolbar, RadioGroup, Menu, ContextMenu

---

## 1. Motivation

Multiple ARIA composite-widget patterns share the same focus-management
contract: exactly one descendant within the container holds
`tabindex="0"` while siblings hold `tabindex="-1"`, and arrow keys
shift the rover between siblings while `Tab` exits the container.
The pattern applies to:

- `role="tablist"` (editor tab strip, deck tabs)
- `role="toolbar"` (action button row, formatting bar)
- `role="tree"` (file explorer, agent task tree)
- `role="radiogroup"` (branch selector, channel chooser)
- `role="menu"` (context menu, action menu — partial overlap)

Today every consumer reimplements this contract inline: each component
binds its own keydown listener, computes its own enabled-set, and tracks
its own active index. The duplication produces three concrete defects:

1. **Drift**: `Home`/`End` semantics differ across consumers — some wrap,
   some clamp, some no-op.
2. **A11y gaps**: `aria-orientation` is set inconsistently, and disabled
   items are not always skipped.
3. **Coupling**: Tabs, TreeView, Toolbar all block on the same primitive
   that has not been built — Stage 2 of the design-system roadmap
   cannot start without this RFC settled.

This RFC specifies a single `createRovingTabindex` primitive in
`headless-core/` and a Preact adapter `useRovingTabindex` in
`headless-preact/`. Bonsai/OCaml adapter follows the same contract via
`headless-bonsai/` once Iter 6 lands.

## 2. Non-Goals

- Render any DOM. Headless primitive. The consumer owns markup.
- Manage selection. Selection is a separate concern handled by the
  composite widget (Tabs `aria-selected`, Tree `aria-selected`, etc.).
- Persist focus across unmount. The primitive restores focus only
  within a single mount lifecycle; `FocusScope` (RFC 0001) handles
  cross-mount restoration.

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/roving-tabindex.ts
export type Orientation = "horizontal" | "vertical" | "both";

export interface RovingTabindexOptions {
  /** ARIA orientation; controls which arrow keys move the rover. */
  orientation: Orientation;
  /** Wrap from last → first / first → last. Default: true. */
  loop?: boolean;
  /** Activate on focus (ARIA "automatic"). Default: false. */
  activateOnFocus?: boolean;
  /** Initial active item id; falls back to first enabled item. */
  defaultActiveId?: string;
}

export interface RovingItemDescriptor {
  readonly id: string;
  readonly disabled?: boolean;
  /** Optional label for typeahead matching (Tree, Menu). */
  readonly text?: string;
}

export interface RovingTabindexState {
  readonly activeId: string | null;
  readonly itemProps: (id: string) => {
    readonly tabIndex: 0 | -1;
    readonly "data-active": "" | undefined;
  };
  readonly containerProps: {
    readonly role?: undefined; // consumer assigns role=tablist/toolbar/etc.
    readonly "aria-orientation"?: "horizontal" | "vertical";
    readonly onKeyDown: (e: KeyboardEvent) => void;
  };
}

export interface RovingTabindexController {
  readonly state: RovingTabindexState;
  setItems(items: ReadonlyArray<RovingItemDescriptor>): void;
  focus(id: string): void;
  next(): void;
  prev(): void;
  first(): void;
  last(): void;
  /** Subscribe to active-id changes. Returns unsubscribe. */
  subscribe(listener: (activeId: string | null) => void): () => void;
}

export function createRovingTabindex(
  opts: RovingTabindexOptions,
): RovingTabindexController;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-roving-tabindex.ts
export interface UseRovingTabindexArgs<T> extends RovingTabindexOptions {
  items: ReadonlyArray<T & RovingItemDescriptor>;
  /** Called when active item changes. */
  onActiveChange?: (id: string | null) => void;
}

export interface UseRovingTabindexResult<T> {
  activeId: string | null;
  getContainerProps: () => JSX.HTMLAttributes<HTMLElement>;
  getItemProps: (item: T) => JSX.HTMLAttributes<HTMLElement>;
  focus: (id: string) => void;
}

export function useRovingTabindex<T extends RovingItemDescriptor>(
  args: UseRovingTabindexArgs<T>,
): UseRovingTabindexResult<T>;
```

## 4. Keyboard contract

| Key | `orientation: horizontal` | `orientation: vertical` | `orientation: both` |
|---|---|---|---|
| `ArrowRight` | next | (no-op) | next (row major) |
| `ArrowLeft` | prev | (no-op) | prev (row major) |
| `ArrowDown` | (no-op) | next | next (column major) |
| `ArrowUp` | (no-op) | prev | prev (column major) |
| `Home` | first enabled | first enabled | first enabled |
| `End` | last enabled | last enabled | last enabled |
| `Tab` / `Shift+Tab` | container exits via FocusScope | same | same |
| Printable char | typeahead (when `text` provided) | same | same |

`loop: true` wraps `last → first` on `next` and `first → last` on
`prev`. `loop: false` clamps. Disabled items are skipped (the rover
moves over them).

`activateOnFocus: true` (ARIA "automatic" tablist) emits the
`onActiveChange` callback as the rover moves. `activateOnFocus: false`
defers activation to the consumer (Tabs requires `Enter`/`Space`).

## 5. Interaction with FocusScope (RFC 0001)

Roving Tabindex is an **inner** focus contract. `FocusScope` is the
**outer** trap (Dialog, Drawer, Popover). They compose:

```
FocusScope (modal root)
  └── focusable A
  └── RovingTabindex (toolbar)
        ├── tabindex=0 button
        └── tabindex=-1 buttons …
  └── focusable B
```

Tab from inside the toolbar exits the rover and lands on the next
focusable in the FocusScope (here: focusable B). `FocusScope` does not
need to know about the rover; the rover just leaves `tabindex=0` on
exactly one item so Tab traversal flows through naturally.

## 6. Data attributes (Tailwind v4 hook)

Item props expose `data-active=""` on the active rover position. The
attribute is empty (not `data-active="true"`) so it composes with
Tailwind v4 `data-[active]:bg-[var(--tab-bg-active)]` selectors
without value matching.

The active item also exposes `data-disabled=""` if `disabled: true`.

## 7. Test plan

`headless-core/src/roving-tabindex.test.ts` covers:

1. **single-direction movement** — horizontal / vertical / both each
   advance the rover in the documented direction; off-axis keys are
   no-ops.
2. **boundary wrap** — `loop: true` wraps last→first; `loop: false`
   clamps.
3. **Home/End** — both go to first/last *enabled* item, skipping
   disabled.
4. **disabled-skip** — `prev`/`next` skip disabled items in the
   middle.
5. **typeahead** — printable char matches the next item whose `text`
   starts with the character, case-insensitive. Multi-char typeahead
   buffers within 500 ms.
6. **defaultActiveId** — falls back to first enabled item if id
   not present or disabled.
7. **setItems re-anchor** — when active id is removed from the list,
   active falls back to nearest preceding enabled, else first.
8. **subscribe / unsubscribe** — listener fires on active change,
   no leak after unsubscribe.
9. **activateOnFocus** — `onActiveChange` fires immediately on rover
   move when true, deferred when false.
10. **container props integration** — `aria-orientation` set
    correctly; `onKeyDown` forwards unhandled keys.

`headless-preact/src/use-roving-tabindex.test.tsx` covers:

11. **Integration with Tabs** (tablist, automatic activation).
12. **Integration with Toolbar** (orientation horizontal, manual
    activation).
13. **Integration with Tree** (orientation vertical, typeahead, nested
    levels via parent-controlled item flattening).

`jest-axe` runs against the toolbar / tablist / tree / radiogroup
sample fixtures from `dashboard/design-system/patterns/a11y/` and
must pass with zero violations.

## 8. Migration path

Consumers migrate one composite widget at a time. The order matches
spec §5.2 staging:

1. **Tabs** (Iter 8) — `tablist` + `tab` ARIA, `automatic` activation.
2. **Tree** (Iter 9) — `tree` + `treeitem` with hierarchy via parent
   controlled flattening. `expand`/`collapse` keys handled by Tree
   primitive on top of the rover.
3. **Toolbar** (Iter 11) — `toolbar` + `button`, manual activation.
4. **RadioGroup** (Iter 12) — `radiogroup` + `radio`, automatic
   activation, `loop: true`.
5. **Menu** (Iter 13) — overlapping concern; Menu composes
   FocusScope (modal trap) + RovingTabindex (inner) + PortalManager
   (layering).

Consumer migration PRs replace inline keydown handlers with
`getItemProps` / `getContainerProps` and remove the per-component
focus state. Each consumer migration is a separate PR.

## 9. Merge criteria

- [ ] `headless-core/src/roving-tabindex.ts` implementation lands
- [ ] 13 test cases above pass under `vitest --run`
- [ ] `jest-axe` passes on toolbar/tablist/tree/radiogroup fixtures
- [ ] `headless-preact/src/use-roving-tabindex.ts` adapter lands
- [ ] One consumer (Tabs) migrates in the same PR as proof-of-pattern
- [ ] CHANGELOG entry under v0.5 lists the RFC and the Tabs migration
- [ ] No new hand-written CSS — all visible state hooks via
  `data-active=""` and existing IDE Chrome tokens (`--tab-bg-active`,
  `--tab-fg-active`, `--tab-indicator`)

## 10. Open questions

1. **Typeahead buffer timeout** — 500 ms is the W3C ARIA APG
   recommendation. Confirm before locking; some MASC consumers may
   prefer 300 ms (denser keyboard usage).
2. **Multi-rover within the same FocusScope** — e.g., a sidebar with
   a TreeView followed by a Toolbar. Each has its own rover. The
   FocusScope contains both. This RFC assumes that pattern works
   without coordination because each rover only manages its own
   children. Confirm with explicit test in §7.
3. **RTL flip** — `ArrowLeft`/`ArrowRight` should swap when the
   container is in RTL. Mark deferred to a follow-up RFC unless an
   RTL surface lands sooner.

These do not block draft acceptance but must resolve before the
implementation PR opens.
