// Tree — ARIA 1.3 tree view with expandable/collapsible nodes
//
// Keyboard: ArrowDown/Up navigates visible nodes, ArrowRight expands,
// ArrowLeft collapses, Enter selects.

import { html } from 'htm/preact'
import { useCallback, useState } from 'preact/hooks'

export interface TreeNode {
  id: string
  label: string
  children?: TreeNode[]
}

interface TreeProps {
  nodes: TreeNode[]
  selectedId?: string
  onSelect?: (id: string) => void
  testId?: string
  /** Accessible name for the tree. */
  'aria-label'?: string
}

interface FlatNode {
  id: string
  label: string
  depth: number
  hasChildren: boolean
  parentId: string | null
}

function flatten(
  nodes: TreeNode[],
  expanded: Set<string>,
  depth = 0,
  parentId: string | null = null,
): FlatNode[] {
  const out: FlatNode[] = []
  for (const n of nodes) {
    out.push({
      id: n.id,
      label: n.label,
      depth,
      hasChildren: !!n.children?.length,
      parentId,
    })
    if (n.children?.length && expanded.has(n.id)) {
      out.push(...flatten(n.children, expanded, depth + 1, n.id))
    }
  }
  return out
}

const TREEITEM_BASE =
  'flex items-center gap-1 px-2 py-1 text-sm rounded-[var(--r-1)] cursor-pointer select-none '

function treeItemCls(selected: boolean): string {
  return selected
    ? TREEITEM_BASE + 'bg-[var(--color-accent-fg)] text-[var(--color-bg-page)]'
    : TREEITEM_BASE +
        'text-[var(--color-fg-primary)] hover:bg-[var(--white-6)]'
}

const EXPANDER_CLS =
  'inline-flex items-center justify-center w-4 h-4 text-[var(--color-fg-muted)]'

export function Tree({
  nodes,
  selectedId,
  onSelect,
  testId,
  'aria-label': ariaLabel,
}: TreeProps) {
  const [expanded, setExpanded] = useState<Set<string>>(new Set())

  const visible = flatten(nodes, expanded)

  const toggleExpand = useCallback(
    (nodeId: string) => {
      setExpanded((prev) => {
        const next = new Set(prev)
        if (next.has(nodeId)) next.delete(nodeId)
        else next.add(nodeId)
        return next
      })
    },
    [setExpanded],
  )

  const findIndex = (nodeId: string | undefined) => {
    if (!nodeId) return -1
    return visible.findIndex((n) => n.id === nodeId)
  }

  const activeIndex = Math.max(0, findIndex(selectedId))

  const handleKeyDown = (e: KeyboardEvent) => {
    if (visible.length === 0) return
    let nextIndex = activeIndex

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      nextIndex = Math.min(visible.length - 1, activeIndex + 1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      nextIndex = Math.max(0, activeIndex - 1)
    } else if (e.key === 'ArrowRight') {
      e.preventDefault()
      const node = visible[activeIndex]
      if (node?.hasChildren && !expanded.has(node.id)) {
        toggleExpand(node.id)
        return
      }
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault()
      const node = visible[activeIndex]
      if (node?.hasChildren && expanded.has(node.id)) {
        toggleExpand(node.id)
        return
      }
      // Collapse: jump to parent if any
      if (node?.parentId) {
        const parentIdx = visible.findIndex((n) => n.id === node.parentId)
        const parent = visible[parentIdx]
        if (parent) onSelect?.(parent.id)
        return
      }
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const node = visible[activeIndex]
      if (node) {
        if (node.hasChildren) toggleExpand(node.id)
        onSelect?.(node.id)
      }
      return
    } else if (e.key === 'Home') {
      e.preventDefault()
      nextIndex = 0
    } else if (e.key === 'End') {
      e.preventDefault()
      nextIndex = visible.length - 1
    }

    const next = visible[nextIndex]
    if (nextIndex !== activeIndex && next) {
      onSelect?.(next.id)
    }
  }

  return html`
    <ul
      role="tree"
      aria-label=${ariaLabel}
      data-testid=${testId}
      tabindex=${0}
      class="outline-none"
      onKeyDown=${handleKeyDown}
    >
      ${visible.map(
        (node) => html`
          <li
            key=${node.id}
            role="treeitem"
            aria-selected=${node.id === selectedId}
            aria-expanded=${node.hasChildren
              ? expanded.has(node.id)
              : undefined}
            aria-level=${node.depth + 1}
            class=${treeItemCls(node.id === selectedId)}
            style=${`padding-left: ${node.depth * 16 + 8}px`}
            onClick=${() => {
              if (node.hasChildren) toggleExpand(node.id)
              onSelect?.(node.id)
            }}
          >
            ${node.hasChildren
              ? html`<span class=${EXPANDER_CLS}>
                  ${expanded.has(node.id) ? '▼' : '▶'}
                </span>`
              : html`<span class=${EXPANDER_CLS}> </span>`}
            <span>${node.label}</span>
          </li>
        `,
      )}
    </ul>
  `
}
