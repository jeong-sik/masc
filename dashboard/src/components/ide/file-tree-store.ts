/**
 * file-tree-store — IDE EXPLORER signal store (Phase 2 PR-4).
 *
 * Mirrors the keeper-state.ts module-level signal pattern. Keeps a
 * flat array of nodes plus an expansion set, derives the visible
 * subset on demand. Seed data is supplied by the IDE data workspace store
 * from the workspace tree route.
 *
 * Headless-friendly: the store has zero DOM/render dependencies and
 * its public API is consumable by both Preact (signal.value reads)
 * and Solid adapters (signal.peek + subscribe).
 *
 * Out of scope (RFC 0014 §2):
 *   - Drag-to-reorder.
 *   - Multi-select.
 *
 * RFC 0014 amendment (lazy children): the v1 "flat node array up front"
 * assumption cannot show a workspace deeper than the server's bounded scan,
 * and for the `project` workspace source the server returns root-only leaves
 * (all hasChildren=false), so no directory was ever expandable. The store now
 * supports on-expand children loading: `seed` records which directories
 * already have their children present, and `loadChildren` (via an injected
 * fetcher) fetches + merges the immediate children of a directory the first
 * time it is expanded. A directory whose children are already present is never
 * re-fetched.
 */

import { signal, computed } from '@preact/signals'

export interface FileTreeNode {
  readonly path: string         // 'runtime/runtime/router.ts'
  readonly label: string        // 'router.ts' (display, last segment)
  readonly depth: number        // 0 = root
  readonly parent: string | null
  readonly hasChildren: boolean
  readonly diff: string | null  // '+12', '-2', etc; null = no diff this run
  readonly keeperId: string | null
  readonly hueIndex: number | null  // 1..12 (matches RFC 0019 mapping)
}

export interface FileTreeDiffSummary {
  readonly changedFiles: number
  readonly additions: number
  readonly deletions: number
  readonly binaryFiles: number
}

/**
 * Fetch the immediate children of a directory (one level, not recursive).
 * Injected so the store stays free of any HTTP/endpoint knowledge and is unit
 * testable. Returning [] is valid (empty directory); rejecting leaves the
 * directory marked not-loaded so a later expand retries.
 */
export type FileTreeChildrenLoader = (
  path: string,
) => Promise<ReadonlyArray<FileTreeNode>>

export interface CreateFileTreeStoreOptions {
  readonly loadChildren?: FileTreeChildrenLoader
}

export interface FileTreeStore {
  readonly seed: (nodes: ReadonlyArray<FileTreeNode>) => void
  readonly visibleNodes: () => ReadonlyArray<FileTreeNode>
  readonly diffSummary: () => FileTreeDiffSummary
  readonly subscribe: (listener: () => void) => () => void
  readonly expand: (path: string) => void
  readonly collapse: (path: string) => void
  readonly toggle: (path: string) => void
  readonly isExpanded: (path: string) => boolean
  readonly expandAll: () => void
  readonly collapseAll: () => void
  readonly knownKeepers: () => ReadonlyArray<string>
  readonly nodeCount: () => number
  /** Fetch + merge a directory's children on first expand (no-op if already
   *  present, in flight, or no loader configured). Returns when settled. */
  readonly loadChildren: (path: string) => Promise<void>
  readonly isChildrenLoaded: (path: string) => boolean
  readonly isChildrenLoading: (path: string) => boolean
}

function normalizedParent(parent: string | null): string | null {
  return parent === '' ? null : parent
}

const EMPTY_DIFF_SUMMARY: FileTreeDiffSummary = {
  changedFiles: 0,
  additions: 0,
  deletions: 0,
  binaryFiles: 0,
}

export function summarizeFileTreeDiffs(
  nodes: ReadonlyArray<FileTreeNode>,
): FileTreeDiffSummary {
  let changedFiles = 0
  let additions = 0
  let deletions = 0
  let binaryFiles = 0

  for (const node of nodes) {
    if (node.hasChildren || node.diff === null) continue
    changedFiles += 1
    if (node.diff === 'bin') {
      binaryFiles += 1
      continue
    }

    for (const part of node.diff.split(/\s+/)) {
      if (part.startsWith('+')) additions += parseDiffCount(part)
      else if (part.startsWith('-')) deletions += parseDiffCount(part)
    }
  }

  return changedFiles === 0
    ? EMPTY_DIFF_SUMMARY
    : { changedFiles, additions, deletions, binaryFiles }
}

function parseDiffCount(token: string): number {
  const parsed = Number.parseInt(token.slice(1), 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

export function createFileTreeStore(
  options: CreateFileTreeStoreOptions = {},
): FileTreeStore {
  const allNodes = signal<ReadonlyArray<FileTreeNode>>([])
  const expanded = signal<ReadonlySet<string>>(new Set())
  // Directories whose children are already present in `allNodes` — either from
  // the initial seed or a completed loadChildren. A directory in this set is
  // never re-fetched on expand. The root sentinel ('') is always loaded.
  const loaded = signal<ReadonlySet<string>>(new Set(['']))
  // Directories with an in-flight children fetch (drives a spinner and guards
  // against duplicate concurrent fetches).
  const loading = signal<ReadonlySet<string>>(new Set())

  // Default-expand depth-0 directories so the initial render is not a
  // wall of root entries with no children visible.
  const seed = (nodes: ReadonlyArray<FileTreeNode>): void => {
    allNodes.value = nodes
    // A directory has its children present iff some seeded node names it as
    // parent. This distinguishes an eagerly-fetched subtree (expand shows the
    // already-present children) from a lazy boundary directory (expand must
    // fetch). Recomputed from scratch on every seed so a repo/keeper switch
    // does not leak stale load state.
    const initiallyLoaded = new Set<string>([''])
    const initiallyExpanded = new Set<string>()
    for (const n of nodes) {
      const parent = normalizedParent(n.parent)
      if (parent !== null) initiallyLoaded.add(parent)
    }
    // Auto-expand a depth-0 directory only when its children are already
    // present (loaded). A root-only source (e.g. the `project` workspace)
    // returns depth-0 directories with hasChildren=true but no children in the
    // seed; auto-expanding those would show an open-but-empty row. They stay
    // collapsed and fetch on demand via loadChildren.
    for (const n of nodes) {
      if (n.depth === 0 && n.hasChildren && initiallyLoaded.has(n.path)) {
        initiallyExpanded.add(n.path)
      }
    }
    loaded.value = initiallyLoaded
    loading.value = new Set()
    expanded.value = initiallyExpanded
  }

  const mergeChildren = (
    parentPath: string,
    children: ReadonlyArray<FileTreeNode>,
  ): void => {
    const existing = new Set(allNodes.value.map(n => n.path))
    const additions = children.filter(child => !existing.has(child.path))
    if (additions.length > 0) {
      allNodes.value = [...allNodes.value, ...additions]
    }
    const nextLoaded = new Set(loaded.value)
    nextLoaded.add(parentPath)
    loaded.value = nextLoaded
  }

  const isChildrenLoaded = (path: string): boolean => loaded.value.has(path)
  const isChildrenLoading = (path: string): boolean => loading.value.has(path)

  const loadChildren = async (path: string): Promise<void> => {
    const fetchChildren = options.loadChildren
    if (!fetchChildren) return
    if (loaded.value.has(path) || loading.value.has(path)) return

    const nextLoading = new Set(loading.value)
    nextLoading.add(path)
    loading.value = nextLoading

    try {
      const children = await fetchChildren(path)
      mergeChildren(path, children)
    } catch {
      // Leave `path` out of `loaded` so a later expand retries. Swallow like
      // the sibling workspace fetches (network errors surface as an empty /
      // unchanged subtree, not a thrown render).
    } finally {
      const done = new Set(loading.value)
      done.delete(path)
      loading.value = done
    }
  }

  const visibleNodesSignal = computed<ReadonlyArray<FileTreeNode>>(() => {
    const nodes = allNodes.value
    const open = expanded.value
    if (nodes.length === 0) return []

    const byPath = new Map<string, FileTreeNode>()
    for (const n of nodes) byPath.set(n.path, n)

    const visible: FileTreeNode[] = []
    for (const n of nodes) {
      let cur: string | null = normalizedParent(n.parent)
      let chainOpen = true
      while (cur !== null) {
        if (!open.has(cur)) {
          chainOpen = false
          break
        }
        const parent = byPath.get(cur)
        cur = parent ? normalizedParent(parent.parent) : null
      }
      if (chainOpen) visible.push(n)
    }
    return visible
  })

  const visibleNodes = (): ReadonlyArray<FileTreeNode> => visibleNodesSignal.value
  const diffSummary = (): FileTreeDiffSummary => summarizeFileTreeDiffs(allNodes.value)

  const subscribe = (listener: () => void): (() => void) => {
    // @preact/signals fires subscribers once synchronously on subscribe; skip
    // that initial snapshot per signal so callers only react to real changes.
    let sawInitialNodes = false
    let sawInitialLoading = false
    const unsubNodes = visibleNodesSignal.subscribe(() => {
      if (!sawInitialNodes) {
        sawInitialNodes = true
        return
      }
      listener()
    })
    // Loading transitions do not change visibleNodes, so subscribe separately
    // to drive the per-directory spinner.
    const unsubLoading = loading.subscribe(() => {
      if (!sawInitialLoading) {
        sawInitialLoading = true
        return
      }
      listener()
    })
    return () => {
      unsubNodes()
      unsubLoading()
    }
  }

  const expand = (path: string): void => {
    // Fetch children on first expand even if the row is already expanded-state
    // (loadChildren self-guards on loaded/loading), so a boundary directory
    // that was toggled before its loader was ready still populates.
    void loadChildren(path)
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
    diffSummary,
    subscribe,
    expand,
    collapse,
    toggle,
    isExpanded,
    expandAll,
    collapseAll,
    knownKeepers,
    nodeCount,
    loadChildren,
    isChildrenLoaded,
    isChildrenLoading,
  }
}
