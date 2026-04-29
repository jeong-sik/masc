# RFC 0014 — TreeView

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**:
  - RFC 0001 (Headless Foundation — `IdGenerator`)
  - RFC 0003 (Roving Tabindex — `vertical` orientation, typeahead)
- **Consumes**: `--sidebar-*`, `--tree-*` tokens (IDE Chrome, #11948).
- **Blocks**: file explorer (Stage 5 IdePlane), GoalTree visualization,
  Cascade Inspector hierarchy.

---

## 1. Motivation

The dashboard has three places where a hierarchy is rendered today:

1. **Goal verifier rail** — flat list, but goals have parent/child
   structure that's collapsed into indentation only.
2. **Cascade Inspector** — expands a single layer at a time, no
   keyboard navigation, no SR announcements.
3. **Composer mention popover** — flat. Would benefit from grouping
   by team/role.

None implements the W3C ARIA `tree` pattern. None supports keyboard
navigation. The Stage 5 IDE plane needs a fourth: the file
explorer, where keyboard parity with VS Code (`↑↓←→`, `Enter`,
typeahead, `*` to expand all siblings) is non-negotiable.

This RFC defines `createTree` — a single headless tree primitive
covering all four use cases. Selection, expansion, virtualization,
and async children are first-class concerns; rendering is consumer's.

## 2. Non-Goals

- Render markup. Headless. Consumer owns the `<ul>` / `<li>` /
  chevron / icon DOM.
- Provide a tree data fetcher. The consumer supplies a flat node
  array (or async loader) — primitive does not call APIs.
- Drag-to-reorder. The MASC tree surfaces are read-mostly; reorder
  is a follow-up RFC if a write-tree surface emerges.
- Multi-tree coordination (drag between trees). Out of scope.

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/tree-view.ts
export interface TreeNode<T = unknown> {
  readonly id: string;
  readonly label: string;
  readonly parentId: string | null;
  /** "lazy" = not yet loaded; consumer fills on expand. */
  readonly hasChildren: boolean | "lazy";
  readonly disabled?: boolean;
  /** Application payload — opaque to the primitive. */
  readonly data?: T;
}

export type SelectionMode = "none" | "single" | "multi";

export interface TreeViewOptions<T = unknown> {
  /** Flat node list. Manager builds the parent→child map internally. */
  nodes: ReadonlyArray<TreeNode<T>>;
  selectionMode: SelectionMode;
  /** Initial expanded ids. Default: [] (collapsed). */
  defaultExpanded?: ReadonlyArray<string>;
  /** Initial selected ids (1+ for multi). */
  defaultSelected?: ReadonlyArray<string>;
  /** When provided, lazy-loads children on expand. Returns array. */
  onLoadChildren?: (id: string) => Promise<ReadonlyArray<TreeNode<T>>>;
  onSelectionChange?: (ids: ReadonlyArray<string>) => void;
  onExpansionChange?: (ids: ReadonlyArray<string>) => void;
}

export interface TreeViewController<T = unknown> {
  // State
  readonly nodes: ReadonlyArray<TreeNode<T>>;
  readonly expanded: ReadonlySet<string>;
  readonly selected: ReadonlySet<string>;
  readonly activeId: string | null;  // rover position

  // Mutations
  expand(id: string): Promise<void>;  // resolves after lazy load
  collapse(id: string): void;
  toggleExpand(id: string): Promise<void>;
  select(id: string, opts?: { readonly extend?: boolean; readonly toggle?: boolean }): void;
  clearSelection(): void;
  expandAllSiblings(id: string): void;  // "*" key behavior

  // Queries
  getVisible(): ReadonlyArray<TreeNode<T>>;  // expanded tree flattened
  getDescendants(id: string): ReadonlyArray<TreeNode<T>>;
  getAriaLevel(id: string): number;  // 1-indexed depth

  // ARIA prop bundles
  getRootProps(): {
    readonly role: "tree";
    readonly "aria-multiselectable"?: true;
    readonly tabIndex: -1;
    readonly onKeyDown: (e: KeyboardEvent) => void;
  };

  getNodeProps(id: string): {
    readonly id: string;
    readonly role: "treeitem";
    readonly "aria-level": number;
    readonly "aria-expanded"?: boolean;     // set only when hasChildren
    readonly "aria-selected": boolean | undefined;  // selectionMode!="none"
    readonly "aria-disabled"?: true;
    readonly tabIndex: 0 | -1;
    readonly "data-active": "" | undefined;
    readonly onClick: (e: MouseEvent) => void;
  };

  // Subscriptions
  subscribe(listener: (snapshot: TreeViewSnapshot<T>) => void): () => void;
}

export interface TreeViewSnapshot<T = unknown> {
  readonly nodes: ReadonlyArray<TreeNode<T>>;
  readonly visible: ReadonlyArray<TreeNode<T>>;
  readonly expanded: ReadonlySet<string>;
  readonly selected: ReadonlySet<string>;
  readonly activeId: string | null;
}

export function createTreeView<T = unknown>(
  opts: TreeViewOptions<T>,
): TreeViewController<T>;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-tree-view.ts
export function useTreeView<T = unknown>(
  opts: TreeViewOptions<T>,
): {
  visible: ReadonlyArray<TreeNode<T>>;
  rootProps: JSX.HTMLAttributes<HTMLElement>;
  getNodeProps: (id: string) => JSX.HTMLAttributes<HTMLElement>;
  expand: (id: string) => Promise<void>;
  collapse: (id: string) => void;
  toggleExpand: (id: string) => Promise<void>;
  select: TreeViewController<T>["select"];
  expanded: ReadonlySet<string>;
  selected: ReadonlySet<string>;
};
```

## 4. Keyboard contract

Delegates to RFC 0003 Roving Tabindex (orientation: `vertical`,
typeahead enabled). Plus tree-specific keys:

| Key | Effect |
|---|---|
| `ArrowDown` | next visible node |
| `ArrowUp` | prev visible node |
| `ArrowRight` | if collapsed → expand; else → focus first child |
| `ArrowLeft` | if expanded → collapse; else → focus parent |
| `Enter` / `Space` | toggle selection (or select if `selectionMode != "none"`) |
| `Home` | first visible node |
| `End` | last visible node |
| `*` | expand all sibling subtrees of the focused node |
| Printable char | typeahead (RFC 0003) |
| `Shift+Click` | range-select (multi mode) |
| `Mod+Click` | toggle-add (multi mode) |

`*` is the W3C ARIA APG default; it expands every sibling at the
focused node's level. Useful for "expand the whole goal tree at this
depth".

## 5. Lazy children

When `node.hasChildren === "lazy"` and the user expands the node:

1. `expand(id)` calls `onLoadChildren(id)`.
2. While the promise pends, the node carries `aria-busy="true"`.
3. On resolve, manager merges the returned children into `nodes` and
   fires the expansion subscriber.
4. On reject, manager logs and *does not* expand. The caller's promise
   rejects.

`hasChildren: true` (non-lazy) renders the chevron immediately; the
manager assumes children are already in `nodes`.

## 6. Virtualization

For ≤ 1,000 visible nodes the consumer can render the full
`getVisible()` array directly. For larger trees (e.g. monorepo file
tree), the consumer reuses the existing `useVirtualList` (lives at
`dashboard/src/components/common/collection.ts`) to windowed-render.

The primitive does not implement virtualization itself. It exposes
`getVisible()` and `getNodeProps(id)` which produce the right
`aria-level` / `aria-posinset` / `aria-setsize` per node, regardless
of whether the node is currently in the viewport. SR navigation
remains correct.

## 7. Multi-selection

`selectionMode: "multi"` enables `aria-multiselectable="true"` on the
root and `aria-selected` on every node. Selection commands:

| Action | Effect |
|---|---|
| `Click` on node | `select(id)` — replaces selection |
| `Mod+Click` | `select(id, { toggle: true })` |
| `Shift+Click` | `select(id, { extend: true })` — range |
| `Enter` / `Space` | toggle current selected (rover position) |

Range select (`Shift+Click`) needs an "anchor" — the last clicked
non-extend node. Manager tracks this internally.

## 8. Test plan

`headless-core/src/tree-view.test.ts`:

1. **Flat→nested build** — flat input list → `getVisible()` returns
   only roots when nothing expanded.
2. **`expand` + `getVisible`** — expanding a node makes its children
   visible; `aria-level` of children = parent + 1.
3. **`collapse` removes descendants** — `getVisible` no longer
   contains descendants of collapsed node.
4. **Keyboard down/up** — rover advances on visible-list order.
5. **Right expands collapsed, focuses first child if expanded** —
   two-step semantics.
6. **Left collapses expanded, focuses parent if collapsed** — same.
7. **`*` expands siblings** — focus on node A, all of A's parent's
   children with `hasChildren` expand.
8. **Lazy load** — `onLoadChildren` resolves with new children; tree
   updates; `aria-busy` cleared.
9. **Lazy reject** — promise rejects → no expand; subscriber gets
   no expansion event.
10. **Multi-select range** — Shift+Click from A to E selects A..E
    inclusive across visible order.
11. **Multi-select toggle** — Mod+Click on selected → deselected.
12. **Disabled skip** — rover skips disabled nodes; click on disabled
    is no-op.
13. **`getAriaLevel`** — root nodes return 1; nested return depth+1.
14. **`getNodeProps` ARIA** — `aria-expanded` only set when
    `hasChildren`; `aria-selected` only set when
    `selectionMode != "none"`.

`headless-preact/src/use-tree-view.test.tsx`:

15. **Hook reactivity** — Preact re-renders on expand / select.
16. **`onSelectionChange` callback** — fires once per change.

`jest-axe` against fixtures: 1) flat 5-node single-select tree,
2) 3-level 12-node multi-select tree, 3) lazy-load tree with
`aria-busy`.

## 9. Migration path

Consumer migrations (separate PRs):

1. **File explorer** (Stage 5 IdePlane) — first consumer when editor
   lands.
2. **Goal verifier rail** — flat → tree with parent/child surfaced.
3. **Cascade Inspector** — replaces single-layer expand with full
   tree.
4. **Composer mention popover** — group-by-team/role.

## 10. Merge criteria

- [ ] `headless-core/src/tree-view.ts` lands
- [ ] All 14 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on 3 fixtures
- [ ] `headless-preact/src/use-tree-view.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Goal verifier rail
      recommended — fewest unknowns)
- [ ] CHANGELOG entry under v0.5
- [ ] RFC 0003 implementation merged first (rover dependency)
- [ ] `--tree-*` token additions land in same PR or prior
      (`--tree-item-hover-bg`, `--tree-item-selected-bg`,
      `--tree-chevron-fg`, `--tree-indent-guide`) — note: spec §5.1.2
      groups these under `--tree-*`; PR #11948 deferred to follow-up.
      Open question §11.3 below.

## 11. Open questions

1. **`*` semantics scope** — does it expand siblings *recursively*
   (whole subtree) or only one level? W3C APG says single level;
   VS Code goes one level. Confirm.
2. **Range-select anchor reset** — when does the range anchor reset?
   Proposal: any non-extend selection resets it. Confirm.
3. **`--tree-*` tokens** — IDE Chrome PR (#11948) added `--sidebar-*`
   but not `--tree-*` (chevron fg, indent guide, item-hover-bg). Two
   options: (a) tree-specific tokens, (b) reuse `--sidebar-*`. Spec
   §5.1.2 lists tree separately; recommendation is (a) if there's a
   visual distinction between sidebar-level rows and tree-level rows
   nested inside them. Defer to consumer-side review.

These do not block draft acceptance but must close before the
implementation PR opens.
