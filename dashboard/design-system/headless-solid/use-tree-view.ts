/**
 * useTreeView — SolidJS adapter over headless-core/TreeView
 * (RFC 0014 §3.2, RFC 0017 PR #2.9).
 *
 * Multi-field reactive accessors (visible/nodes/expanded/selected/activeId).
 * expand/toggleExpand return Promise to forward async onLoadChildren.
 */

import { createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  createTreeView,
  type TreeNode,
  type TreeNodeProps,
  type TreeRootProps,
  type TreeViewController,
  type TreeViewOptions,
} from '../headless-core/tree-view'

export interface UseTreeViewResult<T = unknown> {
  readonly visible: Accessor<ReadonlyArray<TreeNode<T>>>
  readonly nodes: Accessor<ReadonlyArray<TreeNode<T>>>
  readonly expanded: Accessor<ReadonlySet<string>>
  readonly selected: Accessor<ReadonlySet<string>>
  readonly activeId: Accessor<string | null>
  readonly controller: TreeViewController<T>
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
  const controller = createTreeView<T>(opts)

  const [visible, setVisible] = createSignal<ReadonlyArray<TreeNode<T>>>(
    controller.getVisible(),
  )
  const [nodes, setNodes] = createSignal<ReadonlyArray<TreeNode<T>>>(controller.nodes)
  const [expanded, setExpanded] = createSignal<ReadonlySet<string>>(controller.expanded)
  const [selected, setSelected] = createSignal<ReadonlySet<string>>(controller.selected)
  const [activeId, setActiveId] = createSignal<string | null>(controller.activeId)

  const dispose = controller.subscribe(() => {
    setVisible(controller.getVisible())
    setNodes(controller.nodes)
    setExpanded(controller.expanded)
    setSelected(controller.selected)
    setActiveId(controller.activeId)
  })
  onCleanup(dispose)

  return {
    visible,
    nodes,
    expanded,
    selected,
    activeId,
    controller,
    getRootProps: () => controller.getRootProps(),
    getNodeProps: (id) => controller.getNodeProps(id),
    expand: (id) => controller.expand(id),
    collapse: (id) => controller.collapse(id),
    toggleExpand: (id) => controller.toggleExpand(id),
    select: (id, o) => controller.select(id, o),
    clearSelection: () => controller.clearSelection(),
    getAriaLevel: (id) => controller.getAriaLevel(id),
  }
}
