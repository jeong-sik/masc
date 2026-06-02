# RFC 0016 — Toolbar

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**:
  - RFC 0001 (Headless Foundation — `IdGenerator`, `PortalManager`)
  - RFC 0003 (Roving Tabindex — orientation horizontal/vertical)
  - RFC 0005 (Menu — overflow menu host)
- **Independent of**: RFC 0004 / 0008–0014.
- **Blocks**: composer toolbar, formatting bar, panel header action
  groups, editor toolbar (Stage 5 IdePlane).

---

## 1. Motivation

Action button groups appear in at least five places today:

- **Composer** — send / attach / mention / shortcut hint.
- **Keeper card** — tag / restart / kill / inspect.
- **Panel headers** — collapse / pin / refresh / settings.
- **Goal rail** — filter / sort / new-goal.
- **Editor** (Stage 5) — undo / redo / format / find / split.

All five reimplement keyboard navigation inline (or omit it). None
exposes `role="toolbar"` so SR users skip past the entire group
silently. None handles overflow when window is narrow — buttons
either wrap (broken layout) or clip (lost actions).

This RFC defines `createToolbar` — Roving Tabindex consumer with:

- Toggle button support (`aria-pressed`).
- Radio button group support (`role="radiogroup"` inside).
- Separator / divider support (`role="separator"`).
- Overflow menu via RFC 0005 Menu when container shrinks.

## 2. Non-Goals

- Render markup. Headless. Consumer owns the `<button>` / `<hr>`
  DOM.
- Provide a default action set. Consumer registers the buttons.
- Disable focus when no items. Empty toolbar still has the
  container; no degradation logic.

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/toolbar.ts
export type ToolbarItemKind =
  | "button"           // plain action button
  | "toggle"           // aria-pressed
  | "radio"            // aria-checked, single selection within group
  | "separator"        // visual divider, no rover stop
  | "group-start"      // begin role=group
  | "group-end";       // end role=group

export interface ToolbarItem {
  readonly id: string;
  readonly kind: ToolbarItemKind;
  readonly label: string;
  readonly disabled?: boolean;
  /** For "toggle": current pressed state. */
  readonly pressed?: boolean;
  /** For "radio": id of the radio's group. Manager enforces that
   *  exactly one radio per group is `checked`. */
  readonly radioGroup?: string;
  readonly checked?: boolean;
  /** For "group-start": ARIA label of the role=group container. */
  readonly groupLabel?: string;
  /** Keyboard shortcut display (forwarded to aria-keyshortcuts). */
  readonly shortcut?: string;
  readonly action?: () => void;
}

export type Orientation = "horizontal" | "vertical";

export interface ToolbarOptions {
  items: ReadonlyArray<ToolbarItem>;
  orientation?: Orientation;            // default "horizontal"
  ariaLabel: string;                    // required — toolbar must be labeled
  /** Container ref; manager observes width to compute overflow. */
  containerSize?: number;               // px (consumer measures)
  /** Optional manual override — items at index ≥ overflowAt go to menu. */
  overflowAt?: number;
  onItemActivate?: (id: string) => void;
  onToggle?: (id: string, nextPressed: boolean) => void;
  onRadioSelect?: (groupId: string, selectedId: string) => void;
}

export interface ToolbarController {
  // Visible vs overflow split (computed from containerSize)
  readonly visibleItems: ReadonlyArray<ToolbarItem>;
  readonly overflowItems: ReadonlyArray<ToolbarItem>;
  readonly hasOverflow: boolean;

  setContainerSize(px: number): void;
  setItems(items: ReadonlyArray<ToolbarItem>): void;
  toggle(id: string): void;
  selectRadio(id: string): void;
  activate(id: string): void;

  // ARIA prop bundles
  getRootProps(): {
    readonly role: "toolbar";
    readonly "aria-label": string;
    readonly "aria-orientation": Orientation;
    readonly tabIndex: -1;
    readonly onKeyDown: (e: KeyboardEvent) => void;
  };

  getItemProps(id: string): {
    readonly id: string;
    readonly type?: "button";  // for buttons / toggles / radios
    readonly role?: "separator";  // for separators
    readonly "aria-pressed"?: boolean;
    readonly "aria-checked"?: boolean;
    readonly "aria-disabled"?: true;
    readonly "aria-keyshortcuts"?: string;
    readonly tabIndex: 0 | -1;
    readonly "data-active": "" | undefined;
    readonly "data-pressed"?: "";
    readonly "data-checked"?: "";
    readonly onClick?: (e: MouseEvent) => void;
  };

  getOverflowMenuTriggerProps(): {
    readonly type: "button";
    readonly "aria-label": "More actions";
    readonly "aria-haspopup": "menu";
    readonly tabIndex: 0;
    readonly onClick: () => void;
  };

  // Subscriptions
  subscribe(listener: (snapshot: ToolbarSnapshot) => void): () => void;
}

export interface ToolbarSnapshot {
  readonly visibleItems: ReadonlyArray<ToolbarItem>;
  readonly overflowItems: ReadonlyArray<ToolbarItem>;
  readonly activeId: string | null;
  readonly overflowMenuOpen: boolean;
}

export function createToolbar(opts: ToolbarOptions): ToolbarController;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-toolbar.ts
export function useToolbar(args: ToolbarOptions & {
  containerRef: RefObject<HTMLElement>;
}): {
  visibleItems: ReadonlyArray<ToolbarItem>;
  overflowItems: ReadonlyArray<ToolbarItem>;
  hasOverflow: boolean;
  rootProps: JSX.HTMLAttributes<HTMLElement>;
  getItemProps: (id: string) => JSX.HTMLAttributes<HTMLElement>;
  overflowMenuTriggerProps: JSX.HTMLAttributes<HTMLButtonElement>;
  /** A pre-wired Menu controller for the overflow items, ready to
   *  use with `useMenu` from RFC 0005. */
  overflowMenuItems: ReadonlyArray<MenuItemDescriptor>;
};
```

## 4. Keyboard contract

Delegates to RFC 0003 Roving Tabindex. Toolbar-specific:

| Key | Effect |
|---|---|
| `ArrowRight` (horizontal) / `ArrowDown` (vertical) | next non-separator |
| `ArrowLeft` (horizontal) / `ArrowUp` (vertical) | prev non-separator |
| `Home` / `End` | first / last enabled non-separator |
| `Enter` / `Space` | activate focused item (button/toggle/radio) |
| `Tab` | exit toolbar (FocusScope outer flow) |

Activation semantics by kind:

- **`button`** → fires `onItemActivate(id)` and the item's
  `action()` (if provided).
- **`toggle`** → flips `pressed`, fires `onToggle(id, nextPressed)`.
- **`radio`** → sets `checked: true` on this item, `false` on
  siblings in same `radioGroup`, fires `onRadioSelect(groupId, id)`.

## 5. Overflow

`ResizeObserver` on `containerRef` reports `containerSize` to the
manager. The manager compares it against the cumulative width of
visible items (consumer reports per-item width via
`setItemWidth(id, px)` — exposed but not shown in the API summary
above for brevity). When overflow:

1. Items beyond the visible boundary move to `overflowItems`.
2. Consumer renders the overflow trigger button (`getOverflowMenuTriggerProps`)
   right of the last visible item.
3. The trigger opens a Menu (RFC 0005) showing the overflow items.

`ResizeObserver` notifications are **throttled to 60 fps** at the
hook level so dragging the window edge doesn't cause O(N) ARIA
recomputation per frame.

If the consumer wants explicit control instead of dynamic measurement,
they pass `overflowAt: 4` to force items 4+ into the overflow menu
unconditionally.

## 6. Toggle and radio semantics

**Toggle**:

- `pressed: true` ↔ `aria-pressed="true"` ↔ `data-pressed=""`.
- Manager flips internally; consumer receives `onToggle` and may
  reflect external state changes via `setItems`.

**Radio**:

- All items with the same `radioGroup` form a group. Manager enforces
  exactly-one selection within the group.
- Selecting a radio fires `onRadioSelect(groupId, id)`.
- Manager wraps the radio cluster in `role="radiogroup"` if a
  `group-start` / `group-end` boundary surrounds them; otherwise the
  radios sit directly under the toolbar with `role="radiogroup"`
  emitted as a phantom container in the snapshot (consumer renders
  the wrapper div).

## 7. Test plan

`headless-core/src/toolbar.test.ts`:

1. **Roving navigation** — Right / Left advance, separator skipped.
2. **Toggle** — `Enter` flips `aria-pressed`; `onToggle` fires.
3. **Radio enforcement** — selecting radio B in group "x"
   deselects radio A; `onRadioSelect` fires once.
4. **Disabled skip** — rover skips disabled items.
5. **Activate fires `action`** — if `action` provided, called once
   per activation.
6. **Group boundary** — `getRootProps` does not collapse the group;
   snapshot includes `groupLabel`.
7. **`aria-keyshortcuts`** — `shortcut: "Mod+S"` → `getItemProps`
   has matching attribute.
8. **Overflow split** — set containerSize 200, sum of widths 400 →
   half items overflow.
9. **`overflowAt` manual** — `overflowAt: 3` → first 3 visible,
   rest overflow regardless of size.
10. **Resize collapses overflow** — increase containerSize → some
    overflow items return to visible.
11. **Overflow menu trigger props** — `aria-haspopup="menu"`,
    `aria-label="More actions"`.
12. **Throttled resize** — 100 rapid `setContainerSize` calls →
    snapshot subscriber fires < 7 times (60 fps over ~100 ms).

`headless-preact/src/use-toolbar.test.tsx`:

13. **Hook reactivity** — Preact re-renders on toggle / overflow.
14. **Overflow menu integration** — `overflowMenuItems` round-trips
    through `useMenu` (RFC 0005) and selecting a menu item fires
    the original item's `action`.

`jest-axe` against fixtures: 1) horizontal toolbar with toggle +
radios + separator, 2) vertical toolbar with overflow open.

## 8. Migration path

Consumer migrations (separate PRs):

1. **Composer toolbar** — first; smallest button set.
2. **Keeper card action group** — second.
3. **Panel header actions** — third; introduces overflow.
4. **Editor toolbar** (Stage 5) — last; full feature set including
   manual `overflowAt`.

## 9. Merge criteria

- [ ] `headless-core/src/toolbar.ts` lands
- [ ] All 12 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on 2 fixtures
- [ ] `headless-preact/src/use-toolbar.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Composer toolbar
      recommended — smallest)
- [ ] CHANGELOG entry under v0.5
- [ ] RFC 0003 (Roving Tabindex) and RFC 0005 (Menu) implementations
      merged first (overflow menu host)
- [ ] No new tokens needed — overflow menu styles via
      `feature/ds-v2-menu-tooltip-toast-tokens` (#11965, merged)

## 10. Open questions

1. **Per-item width measurement** — `setItemWidth(id, px)` adds a
   call site burden. Alternative: `ResizeObserver` on each item
   (more autonomous but heavier). Proposal: explicit per-item width
   via `setItemWidth`. Confirm.
2. **Radio without group boundary** — when consumer omits
   `group-start` / `group-end` around radios, manager emits a
   phantom `role="radiogroup"` wrapper marker. Consumer must render
   it, or accept "radios with no `radiogroup` parent" (W3C ARIA
   permits but discourages). Proposal: require explicit group.
   Confirm.
3. **Vertical-orientation toolbar overflow** — does overflow split
   vertically (items that don't fit the height go to menu)?
   Proposal: yes, same logic, height instead of width. Confirm.

These do not block draft acceptance but must close before the
implementation PR opens.
