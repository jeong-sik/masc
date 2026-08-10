// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorFlowSection,
  channelStatsFor,
  bindingRowsFor,
  recentEventsFor,
} from './connector-flow'
import { parseGateStatusData } from '../api/schemas/gate-status'
import { parseGateConnectorsData } from '../api/schemas/gate-connectors'
import type { GateConnectorInfo } from '../api/gate'

// Fixtures go through the REAL boundary parsers so they cannot drift
// from the schema the production fetch path enforces.

function mkGate(overrides?: Partial<Record<string, unknown>>) {
  return parseGateStatusData({
    channels: [
      {
        channel: 'discord',
        message_count: 12,
        success_count: 10,
        error_count: 2,
        success_rate_pct: 91,
        avg_duration_ms: 1400,
        last_activity: '2026-06-11T00:00:00Z',
      },
    ],
    bindings: [
      {
        channel: 'discord',
        workspace_id: '149325',
        keeper: 'sangsu',
        message_count: 9,
        success_count: 8,
        error_count: 1,
        last_activity: '2026-06-11T00:00:00Z',
      },
      {
        channel: 'slack',
        workspace_id: 'C0123',
        keeper: 'luna',
        message_count: 3,
      },
    ],
    recent_events: [
      { seq: 1, timestamp: '2026-06-11T00:00:00Z', channel: 'discord', workspace_id: '149325', keeper: 'sangsu', outcome: 'success', duration_ms: 900 },
      { seq: 3, timestamp: '2026-06-11T00:02:00Z', channel: 'discord', workspace_id: '149325', keeper: 'sangsu', outcome: 'keeper_error', error: 'upstream timeout', duration_ms: 4800 },
      { seq: 2, timestamp: '2026-06-11T00:01:00Z', channel: 'slack', workspace_id: 'C0123', keeper: 'luna', outcome: 'success' },
    ],
    ...(overrides ?? {}),
  })
}

function mkConnector(overrides?: Partial<Record<string, unknown>>): GateConnectorInfo {
  const data = parseGateConnectorsData({
    generated_at: '2026-06-11T00:00:00Z',
    connectors: [
      {
        connector_id: 'discord',
        display_name: 'Discord',
        channel: 'discord',
        capabilities: ['bindings'],
        status: 'connected',
        available: true,
        connected: true,
        recent_audit: [
          {
            timestamp: '2026-06-11T00:00:00Z',
            action: 'bind',
            guild_id: 'g1',
            channel_id: '149325',
            keeper_name: 'sangsu',
            actor_id: 'dashboard',
            actor_name: 'dashboard',
          },
        ],
        ...(overrides ?? {}),
      },
    ],
  })
  const connector = data.connectors[0]
  if (!connector) throw new Error('fixture connector failed to parse')
  return connector
}

describe('connector-flow pure helpers', () => {
  it('channelStatsFor prefers the connector observed_channel aggregation', () => {
    const connector = mkConnector({
      observed_channel: { channel: 'discord', message_count: 99 },
    })
    const stats = channelStatsFor(connector, mkGate())
    expect(stats?.message_count).toBe(99)
  })

  it('channelStatsFor falls back to the gate channel row, null when absent', () => {
    const connector = mkConnector()
    expect(channelStatsFor(connector, mkGate())?.message_count).toBe(12)
    expect(channelStatsFor(connector, mkGate({ channels: [] }))).toBeNull()
    expect(channelStatsFor(connector, null)).toBeNull()
  })

  it('bindingRowsFor returns only this channel\'s rows', () => {
    const rows = bindingRowsFor(mkConnector(), mkGate())
    expect(rows.map(r => r.keeper)).toEqual(['sangsu'])
  })

  it('recentEventsFor sorts newest-first by seq and caps at the limit', () => {
    const events = recentEventsFor(mkConnector(), mkGate(), 1)
    expect(events.map(e => e.seq)).toEqual([3])
    const all = recentEventsFor(mkConnector(), mkGate())
    expect(all.map(e => e.seq)).toEqual([3, 1])
  })
})

describe('ConnectorFlowSection render', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders stats, binding rows, events, and audit history', () => {
    render(
      html`<${ConnectorFlowSection} connector=${mkConnector()} gate=${mkGate()} />`,
      container,
    )
    expect(container.querySelector('.v2-connector-flow')).not.toBeNull()
    const section = container.querySelector('[data-connector-flow="discord"]')!
    expect(section).toBeTruthy()
    expect(section.querySelector('[data-flow-stats]')?.textContent).toContain('12')
    expect(section.querySelector('[data-flow-bindings]')?.textContent).toContain('sangsu')
    expect(section.querySelector('[data-flow-bindings]')?.textContent).not.toContain('luna')
    expect(section.querySelector('[data-flow-events]')?.textContent).toContain('keeper_error')
    expect(section.querySelector('[data-flow-audit]')?.textContent).toContain('bind')
    expect(section.querySelector('[data-flow-audit]')?.textContent).toContain('149325')
  })

  it('renders nothing when there is no flow data at all', () => {
    const connector = mkConnector({ recent_audit: [] })
    const gate = mkGate({ channels: [], bindings: [], recent_events: [] })
    render(
      html`<${ConnectorFlowSection} connector=${connector} gate=${gate} />`,
      container,
    )
    expect(container.querySelector('[data-connector-flow]')).toBeNull()
  })

  it('shows the empty-stats message when only audit history exists', () => {
    const gate = mkGate({ channels: [], bindings: [], recent_events: [] })
    render(
      html`<${ConnectorFlowSection} connector=${mkConnector()} gate=${gate} />`,
      container,
    )
    const section = container.querySelector('[data-connector-flow="discord"]')!
    expect(section.querySelector('[data-flow-empty]')).toBeTruthy()
    expect(section.querySelector('[data-flow-audit]')).toBeTruthy()
  })
})
