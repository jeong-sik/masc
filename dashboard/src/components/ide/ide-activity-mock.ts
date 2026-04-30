import { html } from 'htm/preact'

// PR-2 placeholder for the ACTIVITY THIS RUN pane. The real activity
// stream (sse-store.ts pattern, virtual-list, sustained 16-keeper
// bench) lands in Phase 2 PR-6 alongside the conversation rail.

interface MockActivity {
  readonly time: string
  readonly keeper: string
  readonly verb: 'flagged' | 'edited' | 'commented on' | 'approved' | 'noted' | 'suggested on' | 'committed' | 'refactored' | 'asked on'
  readonly target: string
  readonly hue: number
  readonly hint?: string
}

const MOCK_ACTIVITY: ReadonlyArray<MockActivity> = [
  { time: '01:41:18', keeper: 'nick0cave', hue: 1, verb: 'flagged', target: 'router.ts:34', hint: 'if:moonshot-tool-choice · blocker' },
  { time: '01:40:02', keeper: 'nick0cave', hue: 1, verb: 'edited', target: 'router.ts:35', hint: '+ next.tool_choice = "auto"' },
  { time: '01:39:02', keeper: 'operator', hue: 9, verb: 'commented on', target: 'router.ts:26', hint: 'question · resolveCascade' },
  { time: '01:37:11', keeper: 'masc-improver', hue: 3, verb: 'edited', target: 'registry.ts:10', hint: '+8 -2 · budgetFor' },
  { time: '01:35:22', keeper: 'masc-improver', hue: 3, verb: 'committed', target: 'improver/wt-47', hint: 'fix: init budget map lazily' },
  { time: '01:32:08', keeper: 'masc-improver', hue: 3, verb: 'refactored', target: 'registry.ts', hint: 'extracted budgetFor' },
  { time: '01:28:15', keeper: 'operator', hue: 9, verb: 'commented on', target: 'registry.ts:10', hint: 'note · log.warn naming' },
  { time: '01:22:41', keeper: 'operator', hue: 9, verb: 'approved', target: 'router.ts:60', hint: 'nextStep · budget guard' },
  { time: '01:18:04', keeper: 'operator', hue: 9, verb: 'noted', target: 'router.ts:35', hint: 'flag · race on Map init' },
  { time: '01:14:52', keeper: 'masc-improver', hue: 3, verb: 'suggested on', target: 'router.ts:16', hint: 'suggest · extract helper' },
  { time: '01:09:11', keeper: 'nick0cave', hue: 1, verb: 'edited', target: 'router.ts:34', hint: '+1 -0 · tool_choice guard' },
  { time: '01:02:11', keeper: 'operator', hue: 9, verb: 'flagged', target: 'registry.ts:10', hint: 'race condition' },
  { time: '00:58:32', keeper: 'operator', hue: 9, verb: 'asked on', target: 'router.ts:26', hint: 'question · resolveCascade' },
]

export function IdeActivityMock() {
  return html`
    <div
      role="region"
      aria-label="ACTIVITY THIS RUN (mock — PR-6 replaces with sse-store-backed stream)"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        borderTop: '1px solid var(--color-border-divider)',
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
        <span>ACTIVITY</span>
        <span>THIS RUN</span>
      </header>
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2)',
          margin: 0,
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-1)',
          overflow: 'auto',
        }}
      >
        ${MOCK_ACTIVITY.map(item => MockActivityRow(item))}
      </ol>
    </div>
  `
}

function MockActivityRow(item: MockActivity) {
  const dot = `var(--color-keeper-${item.hue}-glow, var(--k-${item.hue}))`
  return html`
    <li
      style=${{
        display: 'grid',
        gridTemplateColumns: '52px 8px 1fr',
        gap: 'var(--sp-2)',
        alignItems: 'baseline',
        padding: '4px 6px',
        font: 'var(--type-body)',
        color: 'var(--color-fg-secondary)',
      }}
    >
      <span style=${{ font: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.time}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, alignSelf: 'center' }} />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
        <span style=${{ font: 'var(--fs-11)' }}>
          <strong style=${{ color: dot }}>${item.keeper}</strong> ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
        </span>
        ${item.hint ? html`<span style=${{ font: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.hint}</span>` : null}
      </div>
    </li>
  `
}
