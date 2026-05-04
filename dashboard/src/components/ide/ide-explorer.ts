import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { createFileTreeStore, type FileTreeNode } from './file-tree-store'
import { activeIdeFile } from './ide-shell'

// Phase 2 PR-4: real EXPLORER backed by file-tree-store. Replaces the
// PR-2 ide-explorer-mock placeholder. The fixture below is the same
// 14-node tree the mock rendered; it now flows through the store so
// future PRs can swap in keeper-artifact / repo-fs sources without
// changing the component.
//
// The store handles expansion semantics; this component is a thin
// renderer that subscribes to visibleNodes and dispatches toggle
// clicks. Headless tree-view (RFC 0014) keyboard navigation lands
// in a follow-up; for now click-to-expand is enough to validate the
// store wiring.
//
// Audit reference:
//   dashboard/design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md

const FALLBACK_SEED: ReadonlyArray<FileTreeNode> = [
  { path: 'dune-project', label: 'dune-project', depth: 0, parent: null, hasChildren: false, diff: null, keeperId: null, hueIndex: null },
  { path: 'README.md', label: 'README.md', depth: 0, parent: null, hasChildren: false, diff: null, keeperId: null, hueIndex: null },
]

async function fetchTree(depth = 3): Promise<ReadonlyArray<FileTreeNode>> {
  try {
    const res = await fetch(`/api/v1/workspace/tree?depth=${depth}`)
    if (!res.ok) return FALLBACK_SEED
    const data = await res.json()
    if (!Array.isArray(data) || data.length === 0) return FALLBACK_SEED
    return data as ReadonlyArray<FileTreeNode>
  } catch { return FALLBACK_SEED }
}

export function IdeExplorer() {
  const store = useMemo(() => {
    const s = createFileTreeStore()
    s.seed(FALLBACK_SEED)
    return s
  }, [])

  useEffect(() => {
    let cancelled = false
    fetchTree().then(nodes => { if (!cancelled) store.seed(nodes) })
    return () => { cancelled = true }
  }, [store])

  const [tick, setTick] = useState(0)
  useEffect(() => {
    const dispose = store.subscribe(() => setTick(n => n + 1))
    return dispose
  }, [store])

  // useMemo over `tick` so the visibleNodes call re-runs when the
  // store's expansion state changes; tick reference is intentional.
  const visible = useMemo(() => store.visibleNodes(), [store, tick])
  const fileCount = visible.filter(n => n.diff !== null).length

  return html`
    <div
      role="region"
      aria-label="EXPLORER"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-3)',
        background: 'var(--color-bg-surface)',
        borderRight: '1px solid var(--color-border-default)',
        minHeight: 0,
        overflow: 'auto',
      }}
    >
      <header
        style=${{
          display: 'flex',
          justifyContent: 'space-between',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
          paddingBottom: 'var(--sp-2)',
          borderBottom: '1px solid var(--color-border-divider)',
        }}
      >
        <span>EXPLORER</span>
        <span>${fileCount} FILES</span>
      </header>
      <ul
        role="tree"
        aria-label="File tree"
        style=${{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: '2px' }}
      >
        ${visible.map(node => TreeRow(node, store.isExpanded(node.path), () => {
          if (node.hasChildren) store.toggle(node.path)
          else activeIdeFile.value = node.path
        }))}
      </ul>
    </div>
  `
}

function TreeRow(node: FileTreeNode, expanded: boolean, onClick: () => void) {
  const indent = node.depth * 12
  const dotColor = node.hueIndex !== null
    ? `var(--color-keeper-${node.hueIndex}-glow, var(--k-${node.hueIndex}))`
    : 'transparent'
  const chevron = node.hasChildren ? (expanded ? '▾' : '▸') : ''
  const onKeyDown = (e: KeyboardEvent): void => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      onClick()
    }
  }
  return html`
    <li
      role="treeitem"
      aria-expanded=${node.hasChildren ? (expanded ? 'true' : 'false') : undefined}
      tabIndex=${node.hasChildren ? 0 : -1}
      onClick=${onClick}
      onKeyDown=${onKeyDown}
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto auto 1fr auto',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        padding: '2px 4px',
        paddingLeft: `${4 + indent}px`,
        font: 'var(--type-body)',
        color: 'var(--color-fg-secondary)',
        cursor: node.hasChildren ? 'pointer' : 'default',
        userSelect: 'none',
      }}
    >
      <span aria-hidden="true" style=${{ color: 'var(--color-fg-muted)', width: '12px', textAlign: 'center' }}>${chevron}</span>
      <span
        aria-hidden="true"
        style=${{
          width: '8px',
          height: '8px',
          borderRadius: '50%',
          background: dotColor,
          opacity: node.hueIndex !== null ? 0.85 : 0,
        }}
      />
      <span>${node.label}</span>
      ${node.diff !== null
        ? html`<span style=${{ color: 'var(--color-fg-muted)', font: 'var(--fs-11)' }}>${node.diff}</span>`
        : null}
    </li>
  `
}
