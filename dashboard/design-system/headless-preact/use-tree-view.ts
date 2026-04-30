/**
 * useTreeView — Preact adapter over headless-core/TreeView (RFC 0014 §3.2).
 *
 * Cached controller via useRef, subscribe → bumpState for re-render.
 * expand returns a Promise so consumers can await async children load.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  createTreeView,
  type TreeNode,
  type TreeNodeProps,
  type TreeRootProps,
  type TreeViewController,
  type TreeViewOptions,
} from '../headless-core/tree-view'

export interface UseTreeViewResult<T = unknown> {
  readonly visible: ReadonlyArray<TreeNode<T>>
  readonly nodes: ReadonlyArray<TreeNode<T>>
  readonly expanded: ReadonlySet<string>
  readonly selected: ReadonlySet<string>
  readonly activeId: string | null
  getRootProps(): TreeRootProps
  getNodeProps(id: string): TreeNodeProps
  expand(id: string): Promise<void>
  collapse(id: string): void
  toggleExpand(id: string): Promise<void>
  select(
    id: string,
    opts?: { readonly extend?: boolean; readonly toggle?: boolean },
  ): void
  clearSelection(): void
  getAriaLevel(id: string): number
}

export function useTreeView<T = unknown>(
  opts: TreeViewOptions<T>,
): UseTreeViewResult<T> {
  const controllerRef = useRef<TreeViewController<T> | null>(null)
  const [, bump] = useState(0)

  if (controllerRef.current === null) {
    controllerRef.current = createTreeView(opts)
  }

  useEffect(() => {
    const c = controllerRef.current
    if (c === null) return undefined
    return c.subscribe(() => bump((n) => n + 1))
  }, [])

  return useMemo<UseTreeViewResult<T>>(() => {
    const c = controllerRef.current!
    return {
      get visible() {
        return c.getVisible()
      },
      get nodes() {
        return c.nodes
      },
      get expanded() {
        return c.expanded
      },
      get selected() {
        return c.selected
      },
      get activeId() {
        return c.activeId
      },
      getRootProps: () => c.getRootProps(),
      getNodeProps: (id) => c.getNodeProps(id),
      expand: (id) => c.expand(id),
      collapse: (id) => c.collapse(id),
      toggleExpand: (id) => c.toggleExpand(id),
      select: (id, o) => c.select(id, o),
      clearSelection: () => c.clearSelection(),
      getAriaLevel: (id) => c.getAriaLevel(id),
    }
  }, [])
}
