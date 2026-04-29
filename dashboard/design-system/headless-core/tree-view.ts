/**
 * TreeView — framework-agnostic tree primitive (RFC 0014).
 *
 * Composes RovingTabindex (RFC 0003) for vertical arrow / Home / End
 * / typeahead, then layers tree-specific keys (→ expand-or-firstchild,
 * ← collapse-or-parent, * expand-all-siblings, Enter selection).
 *
 * MVP scope (RFC 0014 §3, §4, §5, §7):
 *   - Flat node list with parentId chain; manager builds child map
 *   - selectionMode: none / single / multi (with anchor for Shift+Click
 *     range select, Mod+Click toggle)
 *   - Lazy children via onLoadChildren async; aria-busy during load
 *   - getVisible() returns flattened expanded tree
 *   - getAriaLevel returns 1-indexed depth
 *   - * expands all siblings of focused node (W3C APG default)
 *
 * Out of scope (RFC 0014 §11):
 *   - Virtualization (consumer composes with useVirtualList)
 *   - Drag-to-reorder (read-mostly surfaces only for v1)
 *   - Multi-tree drag coordination
 */

import {
  createRovingTabindex,
  type RovingTabindexController,
  type RovingKeyEvent,
} from './roving-tabindex'

export interface TreeNode<T = unknown> {
  readonly id: string
  readonly label: string
  readonly parentId: string | null
  readonly hasChildren: boolean | 'lazy'
  readonly disabled?: boolean
  readonly data?: T
}

export type SelectionMode = 'none' | 'single' | 'multi'

export interface TreeViewOptions<T = unknown> {
  nodes: ReadonlyArray<TreeNode<T>>
  selectionMode: SelectionMode
  defaultExpanded?: ReadonlyArray<string>
  defaultSelected?: ReadonlyArray<string>
  onLoadChildren?: (id: string) => Promise<ReadonlyArray<TreeNode<T>>>
  onSelectionChange?: (ids: ReadonlyArray<string>) => void
  onExpansionChange?: (ids: ReadonlyArray<string>) => void
}

export interface TreeKeyEvent {
  readonly key: string
  readonly shiftKey?: boolean
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface TreeRootProps {
  readonly role: 'tree'
  readonly 'aria-multiselectable'?: true
  readonly tabIndex: -1
  readonly onKeyDown: (e: TreeKeyEvent) => void
}

export interface TreeNodeProps {
  readonly id: string
  readonly role: 'treeitem'
  readonly 'aria-level': number
  readonly 'aria-expanded'?: boolean
  readonly 'aria-selected'?: boolean
  readonly 'aria-busy'?: true
  readonly 'aria-disabled'?: true
  readonly tabIndex: 0 | -1
  readonly 'data-active': '' | undefined
  readonly onClick: (e: { metaKey?: boolean; ctrlKey?: boolean; shiftKey?: boolean }) => void
}

export interface TreeViewSnapshot<T = unknown> {
  readonly nodes: ReadonlyArray<TreeNode<T>>
  readonly visible: ReadonlyArray<TreeNode<T>>
  readonly expanded: ReadonlySet<string>
  readonly selected: ReadonlySet<string>
  readonly activeId: string | null
}

export interface TreeViewController<T = unknown> {
  readonly nodes: ReadonlyArray<TreeNode<T>>
  readonly expanded: ReadonlySet<string>
  readonly selected: ReadonlySet<string>
  readonly activeId: string | null

  expand(id: string): Promise<void>
  collapse(id: string): void
  toggleExpand(id: string): Promise<void>
  select(
    id: string,
    opts?: { readonly extend?: boolean; readonly toggle?: boolean },
  ): void
  clearSelection(): void
  expandAllSiblings(id: string): void

  getVisible(): ReadonlyArray<TreeNode<T>>
  getDescendants(id: string): ReadonlyArray<TreeNode<T>>
  getAriaLevel(id: string): number

  getRootProps(): TreeRootProps
  getNodeProps(id: string): TreeNodeProps

  subscribe(listener: (snapshot: TreeViewSnapshot<T>) => void): () => void
}

export function createTreeView<T = unknown>(
  opts: TreeViewOptions<T>,
): TreeViewController<T> {
  let nodes: ReadonlyArray<TreeNode<T>> = opts.nodes
  let expanded: Set<string> = new Set(opts.defaultExpanded ?? [])
  let selected: Set<string> = new Set(opts.defaultSelected ?? [])
  let busy: Set<string> = new Set()
  let selectionAnchor: string | null = null

  const listeners = new Set<(s: TreeViewSnapshot<T>) => void>()

  function buildChildrenMap(): Map<string | null, TreeNode<T>[]> {
    const map = new Map<string | null, TreeNode<T>[]>()
    for (const n of nodes) {
      const arr = map.get(n.parentId) ?? []
      arr.push(n)
      map.set(n.parentId, arr)
    }
    return map
  }

  function getVisible(): ReadonlyArray<TreeNode<T>> {
    const childrenMap = buildChildrenMap()
    const out: TreeNode<T>[] = []
    function walk(parentId: string | null): void {
      const kids = childrenMap.get(parentId) ?? []
      for (const k of kids) {
        out.push(k)
        if (k.hasChildren && expanded.has(k.id)) walk(k.id)
      }
    }
    walk(null)
    return Object.freeze(out)
  }

  function getAriaLevel(id: string): number {
    let lvl = 1
    let cursor = nodes.find((n) => n.id === id)
    while (cursor !== undefined && cursor.parentId !== null) {
      lvl += 1
      cursor = nodes.find((n) => n.id === cursor!.parentId)
    }
    return lvl
  }

  function getDescendants(id: string): ReadonlyArray<TreeNode<T>> {
    const childrenMap = buildChildrenMap()
    const out: TreeNode<T>[] = []
    function walk(parentId: string): void {
      for (const k of childrenMap.get(parentId) ?? []) {
        out.push(k)
        walk(k.id)
      }
    }
    walk(id)
    return Object.freeze(out)
  }

  function visibleItems() {
    return getVisible().map((n) => ({
      id: n.id,
      disabled: n.disabled,
      text: n.label,
    }))
  }

  const rover: RovingTabindexController = createRovingTabindex({
    orientation: 'vertical',
    items: visibleItems(),
    activateOnFocus: true,
  })

  function syncRover(): void {
    rover.setItems(visibleItems())
  }

  function emit(): void {
    const snap: TreeViewSnapshot<T> = Object.freeze({
      nodes,
      visible: getVisible(),
      expanded: new Set(expanded),
      selected: new Set(selected),
      activeId: rover.activeId,
    })
    for (const l of listeners) l(snap)
  }

  function fireExpansion(): void {
    if (opts.onExpansionChange !== undefined) {
      opts.onExpansionChange(Object.freeze([...expanded]))
    }
  }

  function fireSelection(): void {
    if (opts.onSelectionChange !== undefined) {
      opts.onSelectionChange(Object.freeze([...selected]))
    }
  }

  async function expand(id: string): Promise<void> {
    const node = nodes.find((n) => n.id === id)
    if (node === undefined) return
    if (!node.hasChildren) return
    if (expanded.has(id)) return
    if (node.hasChildren === 'lazy' && opts.onLoadChildren !== undefined) {
      busy.add(id)
      emit()
      try {
        const newKids = await opts.onLoadChildren(id)
        const dedup = new Map<string, TreeNode<T>>()
        for (const n of nodes) dedup.set(n.id, n)
        for (const n of newKids) dedup.set(n.id, n)
        nodes = Object.freeze([...dedup.values()])
      } catch {
        busy.delete(id)
        emit()
        return
      }
      busy.delete(id)
    }
    expanded.add(id)
    syncRover()
    fireExpansion()
    emit()
  }

  function collapse(id: string): void {
    if (!expanded.has(id)) return
    expanded.delete(id)
    syncRover()
    fireExpansion()
    emit()
  }

  async function toggleExpand(id: string): Promise<void> {
    if (expanded.has(id)) collapse(id)
    else await expand(id)
  }

  function selectImpl(
    id: string,
    extend?: boolean,
    toggle?: boolean,
  ): void {
    if (opts.selectionMode === 'none') return
    if (opts.selectionMode === 'single') {
      selected = new Set([id])
      selectionAnchor = id
      fireSelection()
      emit()
      return
    }
    // multi
    if (extend === true && selectionAnchor !== null) {
      const visible = getVisible()
      const start = visible.findIndex((n) => n.id === selectionAnchor)
      const end = visible.findIndex((n) => n.id === id)
      if (start < 0 || end < 0) return
      const lo = Math.min(start, end)
      const hi = Math.max(start, end)
      selected = new Set()
      for (let i = lo; i <= hi; i += 1) {
        const n = visible[i]
        if (n !== undefined && n.disabled !== true) selected.add(n.id)
      }
      fireSelection()
      emit()
      return
    }
    if (toggle === true) {
      if (selected.has(id)) selected.delete(id)
      else selected.add(id)
      selectionAnchor = id
      fireSelection()
      emit()
      return
    }
    // plain click — replace
    selected = new Set([id])
    selectionAnchor = id
    fireSelection()
    emit()
  }

  function expandAllSiblings(id: string): void {
    const node = nodes.find((n) => n.id === id)
    if (node === undefined) return
    const childrenMap = buildChildrenMap()
    const siblings = childrenMap.get(node.parentId) ?? []
    let changed = false
    for (const s of siblings) {
      if (s.hasChildren && !expanded.has(s.id)) {
        expanded.add(s.id)
        changed = true
      }
    }
    if (changed) {
      syncRover()
      fireExpansion()
      emit()
    }
  }

  function focusedNode(): TreeNode<T> | undefined {
    if (rover.activeId === null) return undefined
    return nodes.find((n) => n.id === rover.activeId)
  }

  function handleKeyDown(e: TreeKeyEvent): void {
    const focused = focusedNode()
    if (focused === undefined) return
    if (e.key === 'ArrowRight') {
      e.preventDefault()
      if (focused.hasChildren && !expanded.has(focused.id)) {
        void expand(focused.id)
      } else if (focused.hasChildren && expanded.has(focused.id)) {
        // focus first child
        const childrenMap = buildChildrenMap()
        const first = (childrenMap.get(focused.id) ?? []).find(
          (n) => n.disabled !== true,
        )
        if (first !== undefined) rover.setActive(first.id)
      }
      return
    }
    if (e.key === 'ArrowLeft') {
      e.preventDefault()
      if (focused.hasChildren && expanded.has(focused.id)) {
        collapse(focused.id)
      } else if (focused.parentId !== null) {
        rover.setActive(focused.parentId)
      }
      return
    }
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      if (opts.selectionMode !== 'none') {
        selectImpl(focused.id)
      }
      return
    }
    if (e.key === '*') {
      e.preventDefault()
      expandAllSiblings(focused.id)
      return
    }
    // Forward to rover for ArrowUp / ArrowDown / Home / End / typeahead.
    const adapted: RovingKeyEvent = {
      key: e.key,
      shiftKey: e.shiftKey,
      metaKey: e.metaKey,
      ctrlKey: e.ctrlKey,
      altKey: e.altKey,
      preventDefault: () => e.preventDefault(),
    }
    rover.handleKeyDown(adapted)
  }

  // Subscribe to rover so external active changes propagate
  rover.subscribe(() => emit())

  return {
    get nodes() {
      return nodes
    },
    get expanded() {
      return expanded as ReadonlySet<string>
    },
    get selected() {
      return selected as ReadonlySet<string>
    },
    get activeId() {
      return rover.activeId
    },

    expand,
    collapse,
    toggleExpand,

    select(id: string, options?: { extend?: boolean; toggle?: boolean }): void {
      selectImpl(id, options?.extend, options?.toggle)
    },

    clearSelection(): void {
      if (selected.size === 0) return
      selected = new Set()
      selectionAnchor = null
      fireSelection()
      emit()
    },

    expandAllSiblings,
    getVisible,
    getDescendants,
    getAriaLevel,

    getRootProps(): TreeRootProps {
      return Object.freeze({
        role: 'tree' as const,
        'aria-multiselectable': opts.selectionMode === 'multi' ? (true as const) : undefined,
        tabIndex: -1 as const,
        onKeyDown: handleKeyDown,
      })
    },

    getNodeProps(id: string): TreeNodeProps {
      const node = nodes.find((n) => n.id === id)
      const isActive = rover.activeId === id
      const isDis = node?.disabled === true
      const props: TreeNodeProps = {
        id,
        role: 'treeitem' as const,
        'aria-level': getAriaLevel(id),
        'aria-expanded':
          node !== undefined && node.hasChildren ? expanded.has(id) : undefined,
        'aria-selected':
          opts.selectionMode === 'none' ? undefined : selected.has(id),
        'aria-busy': busy.has(id) ? (true as const) : undefined,
        'aria-disabled': isDis ? (true as const) : undefined,
        tabIndex: isActive ? 0 : -1,
        'data-active': isActive ? '' : undefined,
        onClick: (e) => {
          if (e.shiftKey === true) selectImpl(id, true)
          else if (e.metaKey === true || e.ctrlKey === true) selectImpl(id, false, true)
          else selectImpl(id)
          rover.setActive(id)
        },
      }
      return Object.freeze(props)
    },

    subscribe(listener: (s: TreeViewSnapshot<T>) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
