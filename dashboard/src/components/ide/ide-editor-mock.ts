import { html } from 'htm/preact'

// PR-2 placeholder for the editor pane. The real Shiki-backed read-
// only viewer + blame-by-keeper overlay lands in Phase 2 PR-5 (cites
// RFC 0019). The 'attribution' label echoes the cockpit IdePlane
// prototype's IxEditAttrib (Planes.jsx:155).

interface MockLine {
  readonly num: number
  readonly text: string
  readonly keeper: 'nick0cave' | 'sangsu' | 'masc-improver' | null
  readonly hue: number | null
}

const MOCK_LINES: ReadonlyArray<MockLine> = [
  { num: 1, text: "import { Provider, ProviderKind } from './provider'", keeper: 'nick0cave', hue: 1 },
  { num: 2, text: "import { Turn, TurnId } from './turn'", keeper: 'nick0cave', hue: 1 },
  { num: 3, text: "import { FsmEvent } from '../fsm/state'", keeper: 'nick0cave', hue: 1 },
  { num: 4, text: "import { log } from '../log'", keeper: 'nick0cave', hue: 1 },
  { num: 5, text: "import type { ToolSpec } from './tools'", keeper: 'nick0cave', hue: 1 },
  { num: 6, text: "import { TokenRegistry } from '../tokens/registry'", keeper: 'nick0cave', hue: 1 },
  { num: 7, text: '', keeper: null, hue: null },
  { num: 8, text: 'export type CascadeReq = {', keeper: 'sangsu', hue: 5 },
  { num: 9, text: '  model: string', keeper: 'sangsu', hue: 5 },
  { num: 10, text: '  messages: Array<{ role: string; content: string }>', keeper: 'sangsu', hue: 5 },
  { num: 11, text: '  tools?: ToolSpec[]', keeper: 'sangsu', hue: 5 },
  { num: 12, text: "  tool_choice?: 'auto' | 'none'", keeper: 'sangsu', hue: 5 },
  { num: 13, text: '  max_tokens?: number', keeper: 'sangsu', hue: 5 },
  { num: 14, text: '}', keeper: 'sangsu', hue: 5 },
  { num: 15, text: '', keeper: null, hue: null },
  { num: 16, text: 'export function normalizeTools(req: CascadeReq): CascadeReq {', keeper: 'masc-improver', hue: 3 },
  { num: 17, text: '  // strip empty tools array', keeper: 'masc-improver', hue: 3 },
  { num: 18, text: '  if (req.tools && req.tools.length === 0) {', keeper: 'masc-improver', hue: 3 },
  { num: 19, text: '    const { tools, tool_choice, ...rest } = req', keeper: 'masc-improver', hue: 3 },
  { num: 20, text: '    return rest as CascadeReq', keeper: 'masc-improver', hue: 3 },
  { num: 21, text: '  }', keeper: 'masc-improver', hue: 3 },
  { num: 22, text: '  return req', keeper: 'masc-improver', hue: 3 },
  { num: 23, text: '}', keeper: 'masc-improver', hue: 3 },
]

export function IdeEditorMock() {
  // View tabs and LAYERS toggle moved to IdeToolbar (PR-3); the editor
  // mock now only shows the breadcrumb header for the open file.
  return html`
    <div
      role="region"
      aria-label="에디터 (mock — PR-5 replaces with Shiki + blame-by-keeper)"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr',
        background: 'var(--color-bg-page)',
        minHeight: 0,
      }}
    >
      <header
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
      </header>
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
        ${MOCK_LINES.map(line => MockEditorRow(line))}
      </ol>
    </div>
  `
}

function MockEditorRow(line: MockLine) {
  const dot = line.hue !== null
    ? `var(--color-keeper-${line.hue}-glow, var(--k-${line.hue}))`
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
        style=${{
          color: line.keeper ? `var(--color-keeper-${line.hue}-glow, var(--k-${line.hue}))` : 'var(--color-fg-disabled)',
          font: 'var(--fs-11)',
          textAlign: 'right',
        }}
      >${line.keeper ?? '—'}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, justifySelf: 'center' }} />
      <span style=${{ color: 'var(--color-fg-disabled)', font: 'var(--fs-11)', minWidth: '24px', textAlign: 'right' }}>${line.num}</span>
      <span style=${{ color: 'var(--color-fg-secondary)', whiteSpace: 'pre' }}>${line.text}</span>
    </li>
  `
}
