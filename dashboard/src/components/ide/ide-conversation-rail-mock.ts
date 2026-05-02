import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createAnchoredThreadRailStore,
  type AnchoredThread,
  type ThreadKind,
} from './anchored-thread-rail-store'

const EDITOR_FILE = 'runtime/cascade/router.ts'

const KIND_LABEL: Record<ThreadKind, string> = {
  flag: 'FLAG',
  question: 'QUESTION',
  approve: 'APPROVE',
  note: 'NOTE',
  suggest: 'SUGGEST',
}

const KIND_TOKEN: Record<ThreadKind, string> = {
  flag: 'var(--color-status-err, var(--err))',
  question: 'var(--color-status-info, var(--info))',
  approve: 'var(--color-status-ok, var(--ok))',
  note: 'var(--color-fg-muted)',
  suggest: 'var(--color-status-warn, var(--warn))',
}

const MOCK_THREADS: ReadonlyArray<AnchoredThread> = [
  {
    id: 'thread-schema-tools',
    kind: 'flag',
    author_keeper_id: 'nick0cave',
    anchor: { file_path: EDITOR_FILE, line_start: 34, line_end: 35, symbol_hint: 'if:moonshot-tool-choice' },
    created_ms: Date.UTC(2026, 4, 2, 1, 41, 18),
    body: "This is exactly the schema error we're seeing in prod — confirmed 3× on kimi_cli with non-empty tools[].",
    reply_count: 2,
    resolved: false,
  },
  {
    id: 'thread-normalize-tool-choice',
    kind: 'question',
    author_keeper_id: 'operator',
    anchor: { file_path: EDITOR_FILE, line_start: 26, line_end: 26, symbol_hint: 'fn:resolveCascade' },
    created_ms: Date.UTC(2026, 4, 2, 1, 39, 2),
    body: 'Should normalizeTools also handle tool_choice=none? feels like an edge case.',
    reply_count: 1,
    resolved: false,
  },
  {
    id: 'thread-budget-approve',
    kind: 'approve',
    author_keeper_id: 'operator',
    anchor: { file_path: EDITOR_FILE, line_start: 60, line_end: 60, symbol_hint: 'fn:nextStep' },
    created_ms: Date.UTC(2026, 4, 2, 1, 22, 41),
    body: 'Budget guard reads well. Ship it when tests pass.',
    reply_count: 0,
    resolved: false,
  },
  {
    id: 'thread-telemetry-token',
    kind: 'note',
    author_keeper_id: 'operator',
    anchor: { file_path: EDITOR_FILE, line_start: 35, line_end: 35, symbol_hint: 'token:log.warn' },
    created_ms: Date.UTC(2026, 4, 2, 1, 18, 4),
    body: 'telemetry event name needs to match the lifeline schema — will rename later.',
    reply_count: 0,
    resolved: false,
  },
  {
    id: 'thread-rest-helper',
    kind: 'suggest',
    author_keeper_id: 'masc-improver',
    anchor: { file_path: EDITOR_FILE, line_start: 16, line_end: 16, symbol_hint: 'fn:normalizeTools' },
    created_ms: Date.UTC(2026, 4, 2, 1, 14, 52),
    body: 'Could you collapse the rest-spread into a small helper? Same pattern appears in provider.ts.',
    reply_count: 3,
    resolved: false,
  },
]

export function IdeConversationRailMock() {
  const railStore = useMemo(() => {
    const store = createAnchoredThreadRailStore(EDITOR_FILE)
    store.seed(MOCK_THREADS)
    return store
  }, [])
  const [, forceRender] = useState(0)

  useEffect(() => railStore.subscribe(() => forceRender(tick => tick + 1)), [railStore])

  const threads = railStore.visibleThreads()
  const focusedId = railStore.focusedThreadId()
  const relatedLine35 = railStore.threadsForLine(35)

  return html`
    <div
      role="region"
      aria-label="CONVERSATION (RFC 0021 anchored thread rail mock)"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          justifyContent: 'space-between',
          padding: 'var(--sp-2) var(--sp-3)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
          borderBottom: '1px solid var(--color-border-divider)',
        }}
      >
        <span>CONVERSATION</span>
        <span>${threads.length}</span>
      </div>
      <div
        style=${{
          display: 'flex',
          gap: 'var(--sp-2)',
          padding: 'var(--sp-2) var(--sp-3) 0',
          color: 'var(--color-fg-muted)',
          fontSize: 'var(--fs-11)',
        }}
      >
        <span>router.ts:35</span>
        <span>·</span>
        <span>${relatedLine35.length} related</span>
      </div>
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2)',
          margin: 0,
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-2)',
          overflow: 'auto',
        }}
      >
        ${threads.map(thread => MockThreadCard(
          thread,
          focusedId === thread.id,
          () => railStore.focusThread(thread.id),
        ))}
      </ol>
    </div>
  `
}

function MockThreadCard(thread: AnchoredThread, focused: boolean, onFocus: () => void) {
  const kindColor = KIND_TOKEN[thread.kind]
  const keeperSlot = keeperHueIndex(thread.author_keeper_id)
  const keeperColor = `var(--color-keeper-${keeperSlot}-glow, var(--k-${keeperSlot}))`
  return html`
    <li
      style=${{
        display: 'block',
      }}
    >
      <button
        type="button"
        aria-current=${focused ? 'true' : undefined}
        onClick=${onFocus}
        style=${{
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-1)',
          width: '100%',
          padding: 'var(--sp-2)',
          background: focused ? 'var(--color-bg-muted)' : 'var(--color-bg-elevated)',
          border: '1px solid var(--color-border-default)',
          borderLeft: `2px solid ${keeperColor}`,
          borderRadius: 'var(--r-2)',
          color: 'inherit',
          textAlign: 'left',
          cursor: 'pointer',
        }}
      >
        <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)' }}>
          <span style=${{ fontSize: 'var(--fs-11)', color: kindColor, letterSpacing: '0.05em' }}>${KIND_LABEL[thread.kind]}</span>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${thread.author_keeper_id}</span>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)', marginLeft: 'auto' }}>${formatThreadTime(thread.created_ms)}</span>
        </div>
        <div style=${{ display: 'flex', gap: 'var(--sp-2)', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
          <span>${anchorLabel(thread)}</span>
          ${thread.anchor.symbol_hint
            ? html`<span>·</span><span>${thread.anchor.symbol_hint}</span>`
            : null}
        </div>
        <p style=${{ font: 'var(--type-body)', color: 'var(--color-fg-secondary)', margin: 0 }}>${thread.body}</p>
        <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
          ${thread.reply_count > 0 ? `${thread.reply_count} replies · ` : ''}${thread.resolved ? 'resolved' : 'open'}
        </div>
      </button>
    </li>
  `
}

function anchorLabel(thread: AnchoredThread): string {
  const fileName = thread.anchor.file_path.split('/').at(-1) ?? thread.anchor.file_path
  const start = thread.anchor.line_start
  const end = thread.anchor.line_end
  if (start === null || end === null) return fileName
  if (start === end) return `${fileName}:${start}`
  return `${fileName}:${start}-${end}`
}

function formatThreadTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
