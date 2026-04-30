import { html } from 'htm/preact'

// PR-2 placeholder for the EXPLORER pane. The real file tree (with
// keeper dots, diff counts, RFC 0014 tree-view + roving-tabindex,
// virtualization, and the file-tree-store) lands in Phase 2 PR-4.
//
// This mock matches the shape of the cockpit IdePlane prototype's
// IxTreeDiff (Planes.jsx:186) and the audit's mapping to the file
// explorer (RFC 0014 + file-tree-store).
//
// All values here are visual placeholders; do not parse them as a
// real source of truth — the PR-4 store will replace them wholesale.

interface MockTreeNode {
  readonly path: string
  readonly depth: number
  readonly diff: '+12' | '+3' | '-1' | '+8' | '+14' | '-2' | null
  readonly keeperHue: number | null
}

const MOCK_TREE: ReadonlyArray<MockTreeNode> = [
  { path: 'runtime/', depth: 0, diff: null, keeperHue: null },
  { path: 'cascade/', depth: 1, diff: null, keeperHue: null },
  { path: 'router.ts', depth: 2, diff: '+14', keeperHue: 1 },
  { path: 'provider.ts', depth: 2, diff: '+3', keeperHue: 1 },
  { path: 'turn.ts', depth: 2, diff: null, keeperHue: null },
  { path: 'index.ts', depth: 2, diff: null, keeperHue: null },
  { path: 'fsm/', depth: 1, diff: null, keeperHue: null },
  { path: 'lifeline.ts', depth: 2, diff: '+8', keeperHue: 5 },
  { path: 'state.ts', depth: 2, diff: null, keeperHue: null },
  { path: 'tokens/', depth: 1, diff: null, keeperHue: null },
  { path: 'registry.ts', depth: 2, diff: '+12', keeperHue: 3 },
  { path: 'format.ts', depth: 2, diff: '-2', keeperHue: 3 },
  { path: 'package.json', depth: 0, diff: null, keeperHue: null },
  { path: 'README.md', depth: 0, diff: null, keeperHue: null },
]

export function IdeExplorerMock() {
  return html`
    <div
      role="region"
      aria-label="EXPLORER (mock)"
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
        <span>${MOCK_TREE.filter(n => n.diff !== null).length} FILES</span>
      </header>
      <ul
        role="tree"
        aria-label="File tree (mock — PR-4 replaces with RFC 0014 tree-view)"
        style=${{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: '2px' }}
      >
        ${MOCK_TREE.map(node => MockTreeRow(node))}
      </ul>
    </div>
  `
}

function MockTreeRow(node: MockTreeNode) {
  const indent = node.depth * 12
  const dotColor = node.keeperHue !== null
    ? `var(--color-keeper-${node.keeperHue}-glow, var(--k-${node.keeperHue}))`
    : 'transparent'
  return html`
    <li
      role="treeitem"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto 1fr auto',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        padding: '2px 4px',
        paddingLeft: `${4 + indent}px`,
        font: 'var(--type-body)',
        color: 'var(--color-fg-secondary)',
      }}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '8px',
          height: '8px',
          borderRadius: '50%',
          background: dotColor,
          opacity: node.keeperHue !== null ? 0.85 : 0,
        }}
      />
      <span>${node.path}</span>
      ${node.diff !== null
        ? html`<span style=${{ color: 'var(--color-fg-muted)', font: 'var(--fs-11)' }}>${node.diff}</span>`
        : null}
    </li>
  `
}
