import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createRunActivityStore,
  type RunActivityEvent,
} from './run-activity-store'

const RUN_ID = 'run-47'

const MOCK_ACTIVITY: ReadonlyArray<RunActivityEvent> = [
  { id: 'a13', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 41, 18), keeper_id: 'nick0cave', verb: 'flagged', target: 'router.ts:34', detail: 'if:moonshot-tool-choice · blocker' },
  { id: 'a12', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 40, 2), keeper_id: 'nick0cave', verb: 'edited', target: 'router.ts:35', detail: '+ next.tool_choice = "auto"' },
  { id: 'a11', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 39, 2), keeper_id: 'operator', verb: 'commented on', target: 'router.ts:26', detail: 'question · resolveCascade' },
  { id: 'a10', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 37, 11), keeper_id: 'masc-improver', verb: 'edited', target: 'registry.ts:10', detail: '+8 -2 · budgetFor' },
  { id: 'a09', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 35, 22), keeper_id: 'masc-improver', verb: 'committed', target: 'improver/wt-47', detail: 'fix: init budget map lazily' },
  { id: 'a08', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 32, 8), keeper_id: 'masc-improver', verb: 'refactored', target: 'registry.ts', detail: 'extracted budgetFor' },
  { id: 'a07', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 28, 15), keeper_id: 'operator', verb: 'commented on', target: 'registry.ts:10', detail: 'note · log.warn naming' },
  { id: 'a06', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 22, 41), keeper_id: 'operator', verb: 'approved', target: 'router.ts:60', detail: 'nextStep · budget guard' },
  { id: 'a05', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 18, 4), keeper_id: 'operator', verb: 'noted', target: 'router.ts:35', detail: 'flag · race on Map init' },
  { id: 'a04', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 14, 52), keeper_id: 'masc-improver', verb: 'suggested on', target: 'router.ts:16', detail: 'suggest · extract helper' },
  { id: 'a03', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 9, 11), keeper_id: 'nick0cave', verb: 'edited', target: 'router.ts:34', detail: '+1 -0 · tool_choice guard' },
  { id: 'a02', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 1, 2, 11), keeper_id: 'operator', verb: 'flagged', target: 'registry.ts:10', detail: 'race condition' },
  { id: 'a01', run_id: RUN_ID, timestamp_ms: Date.UTC(2026, 4, 2, 0, 58, 32), keeper_id: 'operator', verb: 'asked on', target: 'router.ts:26', detail: 'question · resolveCascade' },
]

export function IdeActivityMock() {
  const activityStore = useMemo(() => {
    const store = createRunActivityStore(RUN_ID)
    store.seed(MOCK_ACTIVITY)
    return store
  }, [])
  const [, forceRender] = useState(0)

  useEffect(() => activityStore.subscribe(() => forceRender(tick => tick + 1)), [activityStore])

  const events = activityStore.events()
  const keepers = activityStore.knownKeepers()

  return html`
    <div
      role="region"
      aria-label="ACTIVITY THIS RUN (run activity store mock)"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        borderTop: '1px solid var(--color-border-divider)',
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
        <span>ACTIVITY</span>
        <span>${events.length} events · ${keepers.length} keepers</span>
      </div>
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
        ${events.map(item => MockActivityRow(item))}
      </ol>
    </div>
  `
}

function MockActivityRow(item: RunActivityEvent) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
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
      <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${formatActivityTime(item.timestamp_ms)}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, alignSelf: 'center' }} />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
        <span style=${{ fontSize: 'var(--fs-11)' }}>
          <strong style=${{ color: dot }}>${item.keeper_id}</strong> ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
        </span>
        ${item.detail ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.detail}</span>` : null}
      </div>
    </li>
  `
}

function formatActivityTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
