import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import {
  createCodeDocumentStore,
  type CodeDocumentLine,
} from './code-document-store'
import {
  createKeeperLineOwnershipStore,
  type KeeperEdit,
  type LineOwnership,
} from './keeper-line-ownership-store'

// PR-5 precursor: the editor remains a read-only fixture, but both source
// document rows and blame-by-keeper ownership now flow through typed stores.
// Replacing the row text renderer with Shiki/CodeMirror can keep these same
// CodeDocumentLine + LineOwnership contracts.

const EDITOR_FILE = 'runtime/cascade/router.ts'

const MOCK_SOURCE = [
  "import { Provider, ProviderKind } from './provider'",
  "import { Turn, TurnId } from './turn'",
  "import { FsmEvent } from '../fsm/state'",
  "import { log } from '../log'",
  "import type { ToolSpec } from './tools'",
  "import { TokenRegistry } from '../tokens/registry'",
  '',
  'export type CascadeReq = {',
  '  model: string',
  '  messages: Array<{ role: string; content: string }>',
  '  tools?: ToolSpec[]',
  "  tool_choice?: 'auto' | 'none'",
  '  max_tokens?: number',
  '}',
  '',
  'export function normalizeTools(req: CascadeReq): CascadeReq {',
  '  // strip empty tools array',
  '  if (req.tools && req.tools.length === 0) {',
  '    const { tools, tool_choice, ...rest } = req',
  '    return rest as CascadeReq',
  '  }',
  '  return req',
  '}',
].join('\n')

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
  const documentStore = useMemo(() =>
    createCodeDocumentStore({
      file_path: EDITOR_FILE,
      language: 'typescript',
      content: MOCK_SOURCE,
    }), [])
  const ownershipStore = useMemo(() => {
    const store = createKeeperLineOwnershipStore(EDITOR_FILE)
    for (const event of MOCK_OWNERSHIP_EVENTS) store.ingest(event)
    return store
  }, [])
  const document = documentStore.document()
  const lines = documentStore.lines()
  const ownership = ownershipStore.ownership()
  const keepers = ownershipStore.knownKeepers()

  return html`
    <div
      role="region"
      aria-label="에디터 (code document store + RFC 0019 ownership mock)"
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
        <span>${document.file_path}</span>
        <span style=${{ color: 'var(--color-fg-disabled)' }}>${document.language}</span>
        <span style=${{ marginLeft: 'auto' }}>${lines.length} lines · ownership · ${keepers.length} keepers</span>
      </div>
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2) 0',
          margin: 0,
          overflow: 'auto',
          fontFamily: 'var(--font-mono)',
          fontSize: 'var(--fs-13)',
          lineHeight: 1.6,
        }}
      >
        ${lines.map(line => MockEditorRow(line, ownership.get(line.num)))}
      </ol>
    </div>
  `
}

function keeperColor(owner: LineOwnership | undefined): string {
  return owner
    ? `var(--color-keeper-${owner.hue_index}-glow, var(--k-${owner.hue_index}))`
    : 'var(--color-fg-disabled)'
}

function MockEditorRow(line: CodeDocumentLine, owner: LineOwnership | undefined) {
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
          fontSize: 'var(--fs-11)',
          textAlign: 'right',
        }}
      >${owner?.keeper_id ?? '—'}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, justifySelf: 'center' }} />
      <span style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-11)', minWidth: '24px', textAlign: 'right' }}>${line.num}</span>
      <span style=${{ color: 'var(--color-fg-secondary)', whiteSpace: 'pre' }}>${line.text}</span>
    </li>
  `
}
