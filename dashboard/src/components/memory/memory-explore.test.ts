// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { MemoryExplore } from './memory-explore'

describe('MemoryExplore', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders the surface header', () => {
    render(html`<${MemoryExplore} />`)
    const surface = screen.getByTestId('memory-explore-surface')
    expect(surface).not.toBeNull()
    expect(surface.classList.contains('ss-surface')).toBe(true)
    expect(surface.classList.contains('bg-surface-page')).toBe(true)
    expect(screen.getByText('Memory Linkage Explore')).not.toBeNull()
  })

  it('renders MemoryLens with the initial anchor node', () => {
    render(html`<${MemoryExplore} />`)
    const lens = screen.getByTestId('memory-explore-lens')
    expect(lens).not.toBeNull()
    expect(lens.closest('.ss-card')).not.toBeNull()
    expect(lens.textContent).toContain('compact()가 라운드 락 보유 중 호출돼 round-jitter 발생')
  })

  it('renders MemoryLineageRail steps', () => {
    render(html`<${MemoryExplore} />`)
    const lineage = screen.getByTestId('memory-explore-lineage')
    expect(lineage).not.toBeNull()
    expect(lineage.closest('.ss-card')).not.toBeNull()
    expect(lineage.textContent).toContain('13:49')
    expect(lineage.textContent).toContain('통찰 기록')
  })

  it('renders GoalDossier with goal title and progress', () => {
    render(html`<${MemoryExplore} />`)
    const dossier = screen.getByTestId('memory-explore-dossier')
    expect(dossier).not.toBeNull()
    expect(dossier.closest('.ss-card')).not.toBeNull()
    expect(dossier.textContent).toContain('scheduler p95 round-jitter < 50ms')
    expect(dossier.textContent).toContain('47%')
  })

  it('renders related task/issue/memory groups', () => {
    render(html`<${MemoryExplore} />`)
    expect(screen.getAllByText('compact() 호출부를 라운드 락 밖으로 격리').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('round-jitter p95 380ms 스파이크 (7회)')).not.toBeNull()
    expect(screen.getByText('compact()가 라운드 락 보유 중 호출 (insight)')).not.toBeNull()
  })
})
