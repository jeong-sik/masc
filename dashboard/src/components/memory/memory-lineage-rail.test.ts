import { describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { MemoryLineageRail } from './memory-lineage-rail'

const nodeTypes = {
  memory: { kr: '기억', g: '◆', c: '#e0b057' },
}

const nodes = {
  mem2: { type: 'memory', title: 'origin commit', kp: 'nick0cave', meta: 'origin', ns: 'core/scheduler' },
  mem: { type: 'memory', title: 'insight checkpoint', kp: 'nick0cave', meta: 'insight', ns: 'core/scheduler' },
  goal: { type: 'memory', title: 'jitter goal', kp: 'nick0cave', meta: 'goal', ns: 'core/scheduler' },
}

const steps = [
  { id: 'mem2', t: '13:18', rel: '기원' },
  { id: 'mem', t: '13:49', rel: '통찰 기록', anchor: true },
  { id: 'goal', t: '13:50', rel: '골 진단 갱신' },
]

describe('MemoryLineageRail', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders empty state when no steps are provided', () => {
    render(html`<${MemoryLineageRail} steps=${[]} nodes=${{}} nodeTypes=${nodeTypes} testId="rail-empty" />`)
    expect(screen.getByTestId('rail-empty').textContent).toContain('인과 단계가 없습니다')
  })

  it('renders step times, relations, and node titles', () => {
    render(html`<${MemoryLineageRail} steps=${steps} nodes=${nodes} nodeTypes=${nodeTypes} testId="rail" />`)
    const rail = screen.getByTestId('rail')
    expect(rail.textContent).toContain('13:18')
    expect(rail.textContent).toContain('13:49')
    expect(rail.textContent).toContain('13:50')
    expect(rail.textContent).toContain('기원')
    expect(rail.textContent).toContain('통찰 기록')
    expect(rail.textContent).toContain('insight checkpoint')
    expect(rail.textContent).toContain('jitter goal')
  })

  it('marks the anchor step with an entry tag', () => {
    render(html`<${MemoryLineageRail} steps=${steps} nodes=${nodes} nodeTypes=${nodeTypes} testId="rail" />`)
    expect(screen.getByText('진입 지점')).not.toBeNull()
  })

  it('renders a legend from node types', () => {
    render(html`<${MemoryLineageRail} steps=${steps} nodes=${nodes} nodeTypes=${nodeTypes} testId="rail" />`)
    expect(screen.getAllByText('기억').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('엣지 = 관계')).not.toBeNull()
  })

  it('skips steps whose node is missing', () => {
    const missingSteps = [
      { id: 'mem', t: '13:49', rel: '통찰 기록' },
      { id: 'unknown', t: '14:00', rel: 'missing' },
    ]
    render(html`<${MemoryLineageRail} steps=${missingSteps} nodes=${nodes} nodeTypes=${nodeTypes} testId="rail" />`)
    expect(screen.getByTestId('rail').textContent).toContain('통찰 기록')
    expect(screen.getByTestId('rail').textContent).not.toContain('missing')
  })
})
