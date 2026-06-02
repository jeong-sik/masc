// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render, h } from 'preact'
import { PipelineStageBadge } from './keeper-pipeline-stage'

describe('PipelineStageBadge', () => {
  it('renders label for known stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: 'compacting' }), container)
    expect(container.textContent).toContain('compact')
    const badge = container.querySelector('.pipeline-stage-badge')
    expect(badge).not.toBeNull()
    expect(badge!.classList.contains('stage-compacting')).toBe(true)
  })

  it('renders unknown for null stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: null }), container)
    expect(container.textContent).toContain('unknown')
    const badge = container.querySelector('.pipeline-stage-badge')
    expect(badge!.classList.contains('stage-unknown')).toBe(true)
  })

  it('renders raw value for unknown stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: 'unknown_stage' as any }), container)
    expect(container.textContent).toContain('unknown_stage')
  })
})
