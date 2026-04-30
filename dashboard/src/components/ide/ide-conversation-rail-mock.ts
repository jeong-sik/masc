import { html } from 'htm/preact'

// PR-2 placeholder for the CONVERSATION rail. The real rail (anchored
// to lines, controller-mediated scroll, RFC 0021 contract) lands in
// Phase 2 PR-6.

type ThreadKind = 'flag' | 'question' | 'approve' | 'note' | 'suggest'

interface MockThread {
  readonly kind: ThreadKind
  readonly author: string
  readonly anchor: string
  readonly hint: string
  readonly time: string
  readonly body: string
  readonly replies: number | null
  readonly resolved: boolean
}

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

const MOCK_THREADS: ReadonlyArray<MockThread> = [
  {
    kind: 'flag',
    author: 'nick0cave',
    anchor: 'router.ts:34',
    hint: 'if:moonshot-tool-choice',
    time: '01:41:18',
    body: "This is exactly the schema error we're seeing in prod — confirmed 3× on kimi_cli with non-empty tools[].",
    replies: 2,
    resolved: false,
  },
  {
    kind: 'question',
    author: 'operator',
    anchor: 'router.ts:26',
    hint: 'fn:resolveCascade',
    time: '01:39:02',
    body: 'Should normalizeTools also handle tool_choice=none? feels like an edge case.',
    replies: 1,
    resolved: false,
  },
  {
    kind: 'approve',
    author: 'operator',
    anchor: 'router.ts:60',
    hint: 'fn:nextStep',
    time: '01:22:41',
    body: 'Budget guard reads well. Ship it when tests pass.',
    replies: null,
    resolved: false,
  },
  {
    kind: 'note',
    author: 'operator',
    anchor: 'router.ts:35',
    hint: 'token:log.warn',
    time: '01:18:04',
    body: 'telemetry event name needs to match the lifeline schema — will rename later.',
    replies: null,
    resolved: false,
  },
  {
    kind: 'suggest',
    author: 'masc-improver',
    anchor: 'router.ts:16',
    hint: 'fn:normalizeTools',
    time: '01:14:52',
    body: 'Could you collapse the rest-spread into a small helper? Same pattern appears in provider.ts.',
    replies: 3,
    resolved: false,
  },
]

export function IdeConversationRailMock() {
  return html`
    <div
      role="region"
      aria-label="CONVERSATION (mock — PR-6 replaces with RFC 0021 anchored thread rail)"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        minHeight: 0,
      }}
    >
      <header
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
        <span>${MOCK_THREADS.length}</span>
      </header>
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
        ${MOCK_THREADS.map(thread => MockThreadCard(thread))}
      </ol>
    </div>
  `
}

function MockThreadCard(thread: MockThread) {
  const kindColor = KIND_TOKEN[thread.kind]
  return html`
    <li
      style=${{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--sp-1)',
        padding: 'var(--sp-2)',
        background: 'var(--color-bg-elevated)',
        border: '1px solid var(--color-border-default)',
        borderLeft: `2px solid ${kindColor}`,
        borderRadius: 'var(--r-2)',
      }}
    >
      <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)' }}>
        <span style=${{ font: 'var(--fs-11)', color: kindColor, letterSpacing: '0.05em' }}>${KIND_LABEL[thread.kind]}</span>
        <span style=${{ font: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${thread.author}</span>
        <span style=${{ font: 'var(--fs-11)', color: 'var(--color-fg-muted)', marginLeft: 'auto' }}>${thread.time}</span>
      </div>
      <div style=${{ display: 'flex', gap: 'var(--sp-2)', font: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
        <span>${thread.anchor}</span>
        <span>·</span>
        <span>${thread.hint}</span>
      </div>
      <p style=${{ font: 'var(--type-body)', color: 'var(--color-fg-secondary)', margin: 0 }}>${thread.body}</p>
      <div style=${{ font: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
        ${thread.replies !== null ? `${thread.replies} replies · ` : ''}${thread.resolved ? 'resolved' : 'open'}
      </div>
    </li>
  `
}
