import { describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { GoalDossier } from './goal-dossier'

const nodeTypes = {
  task: { kr: '태스크', g: '▣', c: '#22c55e' },
  issue: { kr: '이슈', g: '⚠', c: '#ef4444' },
  memory: { kr: '기억', g: '◆', c: '#e0b057' },
  snapshot: { kr: '스냅샷', g: '◷', c: '#5b9cf0' },
}

const goal = {
  title: 'scheduler p95 round-jitter < 50ms',
  kp: 'nick0cave',
  ns: 'core/scheduler',
  pct: 47,
  deadline: 'D-3 마감',
}

const snaps = [
  { t: '06-08', pct: 12, note: 'baseline' },
  { t: '06-11', pct: 47, note: 'current', now: true },
]

const related = {
  task: [
    { title: 'isolate compact() call', kp: 'sangsu', meta: 'open · handoff', state: 'open' as const },
    { title: 'add regression test', kp: 'nick0cave', meta: 'done · 84/84', state: 'done' as const },
  ],
  issue: [
    { title: 'round-jitter spike', kp: 'nick0cave', meta: 'root cause found', state: 'open' as const },
  ],
  memory: [
    { title: 'compact() lock insight', kp: 'nick0cave', meta: '13:49 checkpoint', state: 'ctx' as const },
  ],
}

const ledger = [
  ['누적 trace', '287'],
  ['활성 시간', '6h 12m'],
  ['태스크', '2 · ✓1'],
  ['이슈', '1'],
] as const

describe('GoalDossier', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders goal header, progress ring, and deadline', () => {
    render(html`<${GoalDossier}
      goal=${goal}
      nodeTypes=${nodeTypes}
      snaps=${snaps}
      related=${related}
      ledger=${ledger}
      testId="dossier"
    />`)
    const dossier = screen.getByTestId('dossier')
    expect(dossier.textContent).toContain('scheduler p95 round-jitter < 50ms')
    expect(dossier.textContent).toContain('47%')
    expect(dossier.textContent).toContain('D-3 마감')
    expect(dossier.textContent).toContain('core/scheduler')
  })

  it('renders snapshot trend', () => {
    render(html`<${GoalDossier}
      goal=${goal}
      nodeTypes=${nodeTypes}
      snaps=${snaps}
      related=${related}
      ledger=${ledger}
      testId="dossier"
    />`)
    expect(screen.getByText('baseline')).not.toBeNull()
    expect(screen.getByText('current')).not.toBeNull()
    expect(screen.getByText('12%')).not.toBeNull()
    expect(screen.getAllByText('47%').length).toBeGreaterThanOrEqual(2)
  })

  it('renders ledger cells', () => {
    render(html`<${GoalDossier}
      goal=${goal}
      nodeTypes=${nodeTypes}
      snaps=${snaps}
      related=${related}
      ledger=${ledger}
      testId="dossier"
    />`)
    expect(screen.getByText('287')).not.toBeNull()
    expect(screen.getByText('6h 12m')).not.toBeNull()
    expect(screen.getByText('누적 trace')).not.toBeNull()
    expect(screen.getByText('활성 시간')).not.toBeNull()
  })

  it('renders related groups with state labels', () => {
    render(html`<${GoalDossier}
      goal=${goal}
      nodeTypes=${nodeTypes}
      snaps=${snaps}
      related=${related}
      ledger=${ledger}
      testId="dossier"
    />`)
    expect(screen.getByText('isolate compact() call')).not.toBeNull()
    expect(screen.getByText('add regression test')).not.toBeNull()
    expect(screen.getByText('round-jitter spike')).not.toBeNull()
    expect(screen.getByText('compact() lock insight')).not.toBeNull()
    expect(screen.getByText('완료')).not.toBeNull()
    expect(screen.getAllByText('진행').length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText('맥락')).not.toBeNull()
  })

  it('renders nothing for empty related groups', () => {
    render(html`<${GoalDossier}
      goal=${goal}
      nodeTypes=${nodeTypes}
      snaps=${snaps}
      related=${{} as typeof related}
      ledger=${ledger}
      testId="dossier-empty"
    />`)
    expect(screen.queryByText('isolate compact() call')).toBeNull()
    expect(screen.queryByText('round-jitter spike')).toBeNull()
    expect(screen.queryByText('compact() lock insight')).toBeNull()
  })
})
