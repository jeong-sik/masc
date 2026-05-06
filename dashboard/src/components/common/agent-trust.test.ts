import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentTrust,
  clampTrustScore,
  summarizeAgentTrust,
  trustScoreBand,
  trustToneConfig,
} from './agent-trust'

const baseMetrics = { score: 85, approvals: 10, rejections: 2, overrides: 1 }

describe('clampTrustScore', () => {
  it('rounds and clamps score values', () => {
    expect(clampTrustScore(84.6)).toBe(85)
    expect(clampTrustScore(150)).toBe(100)
    expect(clampTrustScore(-10)).toBe(0)
  })
})

describe('trustScoreBand', () => {
  it('maps score thresholds to high, medium, and low bands', () => {
    expect(trustScoreBand(80)).toBe('high')
    expect(trustScoreBand(79)).toBe('medium')
    expect(trustScoreBand(50)).toBe('medium')
    expect(trustScoreBand(49)).toBe('low')
  })
})

describe('trustToneConfig', () => {
  it('uses semantic status tokens for each band', () => {
    expect(trustToneConfig('high').scoreClass).toContain('var(--color-status-ok)')
    expect(trustToneConfig('medium').barClass).toContain('var(--color-status-warn)')
    expect(trustToneConfig('low').barTrackClass).toContain('var(--color-status-err)')
  })
})

describe('summarizeAgentTrust', () => {
  it('summarizes clamped score, totals, band, and approval rate label', () => {
    expect(summarizeAgentTrust(baseMetrics)).toEqual({
      rawScore: 85,
      score: 85,
      band: 'high',
      approvals: 10,
      rejections: 2,
      overrides: 1,
      total: 13,
      approvalRate: (10 / 13) * 100,
      approvalRateLabel: '76.9',
      hasEvaluations: true,
    })
  })

  it('summarizes empty evaluation state', () => {
    expect(summarizeAgentTrust({ score: 50, approvals: 0, rejections: 0, overrides: 0 })).toEqual({
      rawScore: 50,
      score: 50,
      band: 'medium',
      approvals: 0,
      rejections: 0,
      overrides: 0,
      total: 0,
      approvalRate: 0,
      approvalRateLabel: '0.0',
      hasEvaluations: false,
    })
  })
})

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

  it('exposes summary metadata on the root', () => {
    const container = document.createElement('div')
    render(h(AgentTrust, { metrics: baseMetrics }), container)
    const el = container.querySelector('[data-agent-trust]') as HTMLElement
    expect(el.dataset.trustRawScore).toBe('85')
    expect(el.dataset.trustScore).toBe('85')
    expect(el.dataset.trustBand).toBe('high')
    expect(el.dataset.trustApprovals).toBe('10')
    expect(el.dataset.trustRejections).toBe('2')
    expect(el.dataset.trustOverrides).toBe('1')
    expect(el.dataset.trustTotal).toBe('13')
    expect(el.dataset.trustApprovalRate).toBe('76.9')
    expect(el.dataset.trustHasEvaluations).toBe('true')
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
    const el = container.querySelector('[data-agent-trust]') as HTMLElement
    expect(el.dataset.trustHasEvaluations).toBe('false')
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
