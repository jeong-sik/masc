import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentTrust } from './agent-trust'

const baseMetrics = { score: 85, approvals: 10, rejections: 2, overrides: 1 }

describe('AgentTrust', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.querySelector('[data-agent-trust]')).not.toBeNull()
  })

  it('renders score', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.textContent).toContain('85')
  })

  it('clamps score to 100', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: { ...baseMetrics, score: 150 } }), container)
    expect(container.textContent).toContain('100')
  })

  it('clamps score to 0', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: { ...baseMetrics, score: -10 } }), container)
    expect(container.textContent).toContain('0')
  })

  it('renders approvals count', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.textContent).toContain('10')
  })

  it('renders rejections count', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.textContent).toContain('2')
  })

  it('renders overrides count', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.textContent).toContain('1')
  })

  it('renders approval rate', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.textContent).toContain('승인률')
    expect(container.textContent).toContain('76.9')
  })

  it('renders 0 approval rate when no evaluations', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: { score: 50, approvals: 0, rejections: 0, overrides: 0 } }), container)
    expect(container.textContent).toContain('0.0')
  })

  it('renders role meter', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    expect(container.querySelector('[role="meter"]')).not.toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics, testId: 'at-1' }), container)
    expect(container.querySelector('[data-testid="at-1"]')).not.toBeNull()
  })

  it('renders aria-label with score', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    const el = container.querySelector('[aria-label^="신뢰도"]')
    expect(el).not.toBeNull()
  })
})
