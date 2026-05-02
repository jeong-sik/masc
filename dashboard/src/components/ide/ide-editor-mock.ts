import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import {
  createKeeperLineOwnershipStore,
  type KeeperEdit,
  type LineOwnership,
} from './keeper-line-ownership-store'

// PR-5 precursor: the editor remains a read-only mock fixture, but its
// blame-by-keeper gutter now consumes RFC 0019's ownership store instead of
// hardcoding keeper labels per row. Replacing the text renderer with Shiki can
// keep the same LineOwnership contract.

interface MockLine {
  readonly num: number
  readonly text: string
}

const EDITOR_FILE = 'runtime/cascade/router.ts'

const MOCK_LINES: ReadonlyArray<MockLine> = [
  { num: 1, text: "import { Provider, ProviderKind } from './provider'" },
  { num: 2, text: "import { Turn, TurnId } from './turn'" },
  { num: 3, text: "import { FsmEvent } from '../fsm/state'" },
  { num: 4, text: "import { log } from '../log'" },
  { num: 5, text: "import type { ToolSpec } from './tools'" },
  { num: 6, text: "import { TokenRegistry } from '../tokens/registry'" },
  { num: 7, text: '' },
  { num: 8, text: 'export type CascadeReq = {' },
  { num: 9, text: '  model: string' },
  { num: 10, text: '  messages: Array<{ role: string; content: string }>' },
  { num: 11, text: '  tools?: ToolSpec[]' },
  { num: 12, text: "  tool_choice?: 'auto' | 'none'" },
  { num: 13, text: '  max_tokens?: number' },
  { num: 14, text: '}' },
  { num: 15, text: '' },
  { num: 16, text: 'export function normalizeTools(req: CascadeReq): CascadeReq {' },
  { num: 17, text: '  // strip empty tools array' },
  { num: 18, text: '  if (req.tools && req.tools.length === 0) {' },
  { num: 19, text: '    const { tools, tool_choice, ...rest } = req' },
  { num: 20, text: '    return rest as CascadeReq' },
  { num: 21, text: '  }' },
  { num: 22, text: '  return req' },
  { num: 23, text: '}' },
]

const MOCK_OWNERSHIP_EVENTS: ReadonlyArray<KeeperEdit> = [
  {
    file_path: EDITOR_FILE,
    line_start: 1,
    line_end: 6,
    keeper_id: 'nick0cave',
    timestamp_ms: 1_774_960_000_000,
    kind: 'create',
  },
  {
    file_path: EDITOR_FILE,
    line_start: 8,
    line_end: 14,
    keeper_id: 'sangsu',
    timestamp_ms: 1_774_960_180_000,
    kind: 'edit',
  },
  {
    file_path: EDITOR_FILE,
    line_start: 16,
    line_end: 23,
    keeper_id: 'masc-improver',
    timestamp_ms: 1_774_960_420_000,
    kind: 'refactor',
  },
]

export function IdeEditorMock() {
  // View tabs and LAYERS toggle moved to IdeToolbar (PR-3); the editor
  // mock now only shows the breadcrumb header for the open file.
  const ownershipStore = useMemo(() => {
    const store = createKeeperLineOwnershipStore(EDITOR_FILE)
    for (const event of MOCK_OWNERSHIP_EVENTS) store.ingest(event)
    return store
  }, [])
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()

  return html`
    <div
      role="region"
      aria-label="에디터 (RFC 0019 line ownership mock)"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr',
        background: 'var(--color-bg-page)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-3)',
          padding: 'var(--sp-2) var(--sp-3)',
          borderBottom: '1px solid var(--color-border-divider)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
        }}
      >
        <span>runtime / cascade / router.ts</span>
        <span style=${{ marginLeft: 'auto' }}>ownership · ${keepers.length} keepers</span>
      </div>
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2) 0',
          margin: 0,
          overflow: 'auto',
          fontFamily: 'var(--font-mono)',
          font: 'var(--fs-13)',
          lineHeight: 1.6,
        }}
      >
        ${MOCK_LINES.map(line => MockEditorRow(line, ownership.get(line.num)))}
      </ol>
    </div>
  `
}

function keeperColor(owner: LineOwnership | undefined): string {
  return owner
    ? `var(--color-keeper-${owner.hue_index}-glow, var(--k-${owner.hue_index}))`
    : 'var(--color-fg-disabled)'
}

function MockEditorRow(line: MockLine, owner: LineOwnership | undefined) {
  const color = keeperColor(owner)
  const dot = owner
    ? color
    : 'transparent'
  return html`
    <li
      style=${{
        display: 'grid',
        gridTemplateColumns: '88px 16px auto 1fr',
        gap: 'var(--sp-2)',
        alignItems: 'center',
        padding: '0 var(--sp-3)',
      }}
    >
      <span
        title=${owner ? `${owner.keeper_id} · ${owner.last_edit_kind}` : undefined}
        style=${{
          color,
          font: 'var(--fs-11)',
          textAlign: 'right',
        }}
      >${owner?.keeper_id ?? '—'}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, justifySelf: 'center' }} />
      <span style=${{ color: 'var(--color-fg-disabled)', font: 'var(--fs-11)', minWidth: '24px', textAlign: 'right' }}>${line.num}</span>
      <span style=${{ color: 'var(--color-fg-secondary)', whiteSpace: 'pre' }}>${line.text}</span>
    </li>
  `
}
