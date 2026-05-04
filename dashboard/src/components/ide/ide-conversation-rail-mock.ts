import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createAnchoredThreadRailStore,
  type AnchoredThread,
  type ThreadKind,
} from './anchored-thread-rail-store'
import {
  IDE_MOCK_FILE_PATH,
  IDE_MOCK_RELATED_LINE,
  IDE_MOCK_THREADS,
} from './ide-mock-data'

const KIND_LABEL: Record<ThreadKind, string> = {
  flag: 'FLAG',
  question: 'QUESTION',
  approve: 'APPROVE',
  note: 'NOTE',
  suggest: 'SUGGEST',
}

const KIND_TOKEN: Record<ThreadKind, string> = {
  flag: 'var(--color-status-err)',
  question: 'var(--color-status-info)',
  approve: 'var(--color-status-ok)',
  note: 'var(--color-fg-muted)',
  suggest: 'var(--color-status-warn)',
}

export function IdeConversationRailMock() {
  const railStore = useMemo(() => {
    const store = createAnchoredThreadRailStore(IDE_MOCK_FILE_PATH)
    store.seed(IDE_MOCK_THREADS)
    return store
  }, [])
  const [, forceRender] = useState(0)

  useEffect(() => railStore.subscribe(() => forceRender(tick => tick + 1)), [railStore])

  const threads = railStore.visibleThreads()
  const focusedId = railStore.focusedThreadId()
  const relatedThreads = railStore.threadsForLine(IDE_MOCK_RELATED_LINE)
  const relatedFile = IDE_MOCK_FILE_PATH.split('/').at(-1) ?? IDE_MOCK_FILE_PATH

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
        <span>${relatedFile}:${IDE_MOCK_RELATED_LINE}</span>
        <span>·</span>
        <span>${relatedThreads.length} related</span>
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
