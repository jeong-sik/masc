// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render, h } from 'preact'
import { KeeperToolAccessSummary } from './keeper-tool-access'
import type { KeeperConfig } from '../types'

function makeConfig(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  return {
    execution: { selected_runtime_id: 'spark' },
    sandbox_profile: 'local',
    network_mode: 'host',
    handoff: { auto: true, threshold: 0.8 },
    proactive: { enabled: true, idle_sec: 300 },
    workspace: { mention_targets: ['alpha', 'beta'] },
    tools: { resolved_allowlist: ['tool1', 'tool2'], tool_denylist: ['bad1'] },
    ...overrides,
  } as KeeperConfig
}

describe('KeeperToolAccessSummary', () => {
  it('renders all summary fields', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig() }), container)
    expect(container.textContent).toContain('runtime')
    expect(container.textContent).toContain('spark')
    expect(container.textContent).toContain('sandbox')
    expect(container.textContent).toContain('network')
    expect(container.textContent).toContain('auto handoff')
    expect(container.textContent).toContain('proactive idle')
    expect(container.textContent).toContain('mention targets')
    expect(container.textContent).toContain('candidate / deny')
  })

  it('shows em dash for null runtime name', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig({ execution: { selected_runtime_id: null } }) }), container)
    const dds = container.querySelectorAll('dd')
    expect(dds[0]!.textContent).toBe('—')
  })

  it('shows em dash for empty sandbox_profile', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig({ sandbox_profile: '' }) }), container)
    const dds = container.querySelectorAll('dd')
    expect(dds[1]!.textContent).toBe('—')
  })

  it('formats mention targets with @ prefix', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig() }), container)
    expect(container.textContent).toContain('@alpha')
    expect(container.textContent).toContain('@beta')
  })

  it('shows em dash for empty mention targets', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig({ workspace: { mention_targets: [] } }) }), container)
    const dds = container.querySelectorAll('dd')
    expect(dds[5]!.textContent).toBe('—')
  })

  it('shows candidate/deny counts', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig() }), container)
    expect(container.textContent).toContain('2 candidate')
    expect(container.textContent).toContain('1 deny')
  })

  it('shows disabled when proactive is off', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig({ proactive: { enabled: false, idle_sec: 120 } }) }), container)
    expect(container.textContent).toContain('120s (disabled)')
  })

  it('shows off for auto handoff when false', () => {
    const container = document.createElement('div')
    render(h(KeeperToolAccessSummary, { config: makeConfig({ handoff: { auto: false, threshold: 0.5 } }) }), container)
    expect(container.textContent).toContain('off')
  })
})
