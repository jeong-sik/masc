// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render, h } from 'preact'
import { PipelineStageBadge } from './keeper-pipeline-stage'

describe('PipelineStageBadge', () => {
  it('renders label for known stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: 'thinking' }), container)
    expect(container.textContent).toContain('think')
    const badge = container.querySelector('.pipeline-stage-badge')
    expect(badge).not.toBeNull()
    expect(badge!.classList.contains('stage-thinking')).toBe(true)
  })

  it('renders offline for null stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: null }), container)
    expect(container.textContent).toContain('offline')
    const badge = container.querySelector('.pipeline-stage-badge')
    expect(badge!.classList.contains('stage-offline')).toBe(true)
  })

  it('renders raw value for unknown stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBadge, { stage: 'unknown_stage' as any }), container)
    expect(container.textContent).toContain('unknown_stage')
  })
})
