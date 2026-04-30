// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render, h } from 'preact'
import { PipelineStageBar, PipelineStageBadge } from './keeper-pipeline-stage'

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

describe('PipelineStageBar', () => {
  it('renders single offline node for null stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: null }), container)
    const nodes = container.querySelectorAll('.pipeline-stage-node')
    expect(nodes.length).toBe(1)
    expect(nodes[0]!.classList.contains('active')).toBe(true)
    expect(container.textContent).toContain('offline')
  })

  it('renders full bar for idle stage', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'idle' }), container)
    const nodes = container.querySelectorAll('.pipeline-stage-node')
    expect(nodes.length).toBe(6)
    expect(nodes[0]!.classList.contains('active')).toBe(true)
    expect(nodes[0]!.classList.contains('stage-idle')).toBe(true)
    expect(container.textContent).toContain('idle')
  })

  it('marks passed stages for thinking', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'thinking' }), container)
    const nodes = container.querySelectorAll('.pipeline-stage-node')
    expect(nodes[0]!.classList.contains('passed')).toBe(true)
    expect(nodes[1]!.classList.contains('active')).toBe(true)
    expect(nodes[1]!.classList.contains('passed')).toBe(false)
    expect(nodes[2]!.classList.contains('passed')).toBe(false)
  })

  it('renders connectors between nodes', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'idle' }), container)
    const connectors = container.querySelectorAll('.pipeline-stage-connector')
    expect(connectors.length).toBe(5)
  })

  it('shows no connectors for offline', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'offline' as any }), container)
    const connectors = container.querySelectorAll('.pipeline-stage-connector')
    expect(connectors.length).toBe(0)
  })

  it('shows label only on active node', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'tool_use' }), container)
    const labels = container.querySelectorAll('.pipeline-stage-label')
    expect(labels.length).toBe(1)
    expect(labels[0]!.textContent).toBe('tool')
  })

  it('handles unknown stage as offline fallback', () => {
    const container = document.createElement('div')
    render(h(PipelineStageBar, { stage: 'unknown' as any }), container)
    const nodes = container.querySelectorAll('.pipeline-stage-node')
    expect(nodes.length).toBe(1)
    expect(container.textContent).toContain('unknown')
  })
})
