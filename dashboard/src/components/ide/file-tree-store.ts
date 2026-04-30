/**
 * file-tree-store — IDE EXPLORER signal store (Phase 2 PR-4).
 *
 * Mirrors the keeper-state.ts module-level signal pattern. Keeps a
 * flat array of nodes plus an expansion set, derives the visible
 * subset on demand. Seed data is supplied by the consumer (PR-2's
 * mock fixture initially; real keeper artifacts in a follow-up).
 *
 * Headless-friendly: the store has zero DOM/render dependencies and
 * its public API is consumable by both Preact (signal.value reads)
 * and Solid adapters (signal.peek + subscribe).
 *
 * Out of scope (RFC 0014 §2):
 *   - Async children loaders. v1 expects a flat node array up front.
 *   - Drag-to-reorder.
 *   - Multi-select.
 */

import { signal, computed } from '@preact/signals'

export interface FileTreeNode {
  readonly path: string         // 'runtime/cascade/router.ts'
  readonly label: string        // 'router.ts' (display, last segment)
  readonly depth: number        // 0 = root
  readonly parent: string | null
  readonly hasChildren: boolean
  readonly diff: string | null  // '+12', '-2', etc; null = no diff this run
  readonly keeperId: string | null
  readonly hueIndex: number | null  // 1..12 (matches RFC 0019 mapping)
}

export interface FileTreeStore {
  readonly seed: (nodes: ReadonlyArray<FileTreeNode>) => void
  readonly visibleNodes: () => ReadonlyArray<FileTreeNode>
  readonly subscribe: (listener: () => void) => () => void
  readonly expand: (path: string) => void
  readonly collapse: (path: string) => void
  readonly toggle: (path: string) => void
  readonly isExpanded: (path: string) => boolean
  readonly expandAll: () => void
  readonly collapseAll: () => void
  readonly knownKeepers: () => ReadonlyArray<string>
  readonly nodeCount: () => number
}

export function createFileTreeStore(): FileTreeStore {
  const allNodes = signal<ReadonlyArray<FileTreeNode>>([])
  const expanded = signal<ReadonlySet<string>>(new Set())
  // Default-expand depth-0 directories so the initial render is not a
  // wall of root entries with no children visible.
  const seed = (nodes: ReadonlyArray<FileTreeNode>): void => {
    allNodes.value = nodes
    const initiallyExpanded = new Set<string>()
    for (const n of nodes) {
      if (n.depth === 0 && n.hasChildren) initiallyExpanded.add(n.path)
    }
    expanded.value = initiallyExpanded
  }

  const visibleNodesSignal = computed<ReadonlyArray<FileTreeNode>>(() => {
    const nodes = allNodes.value
    const open = expanded.value
    if (nodes.length === 0) return []

    const byPath = new Map<string, FileTreeNode>()
    for (const n of nodes) byPath.set(n.path, n)

    const visible: FileTreeNode[] = []
    for (const n of nodes) {
      let cur: string | null = n.parent
      let chainOpen = true
      while (cur !== null) {
        if (!open.has(cur)) {
          chainOpen = false
          break
        }
        const parent = byPath.get(cur)
        cur = parent ? parent.parent : null
      }
      if (chainOpen) visible.push(n)
    }
    return visible
  })

  const visibleNodes = (): ReadonlyArray<FileTreeNode> => visibleNodesSignal.value

  const subscribe = (listener: () => void): (() => void) => {
    const unsub = visibleNodesSignal.subscribe(() => listener())
    return unsub
  }

  const expand = (path: string): void => {
    if (expanded.value.has(path)) return
    const next = new Set(expanded.value)
    next.add(path)
    expanded.value = next
  }
  const collapse = (path: string): void => {
    if (!expanded.value.has(path)) return
    const next = new Set(expanded.value)
    next.delete(path)
    expanded.value = next
  }
  const toggle = (path: string): void => {
    if (expanded.value.has(path)) collapse(path)
    else expand(path)
  }
  const isExpanded = (path: string): boolean => expanded.value.has(path)

  const expandAll = (): void => {
    const all = new Set<string>()
    for (const n of allNodes.value) {
      if (n.hasChildren) all.add(n.path)
    }
    expanded.value = all
  }
  const collapseAll = (): void => {
    expanded.value = new Set()
  }

  const knownKeepers = (): ReadonlyArray<string> => {
    const seen = new Set<string>()
    for (const n of allNodes.value) {
      if (n.keeperId) seen.add(n.keeperId)
    }
    return [...seen].sort()
  }

  const nodeCount = (): number => allNodes.value.length

  return {
    seed,
    visibleNodes,
    subscribe,
    expand,
    collapse,
    toggle,
    isExpanded,
    expandAll,
    collapseAll,
    knownKeepers,
    nodeCount,
  }
}

