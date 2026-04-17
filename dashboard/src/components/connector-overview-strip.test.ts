// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorOverviewStrip,
  _testResetBulkInflight,
  _testResetStripMemory,
  _testSetStripMemory,
  countConnectedSidecars,
  formatConnectorUptime,
  updateStripMemory,
  detectRecentDrops,
  summarizeConnectorStrip,
  tilePrimaryActionView,
} from './connector-overview-strip'
import type { GateConnectorInfo } from '../api/gate'

const mkConnector = (overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo => ({
  connector_id: overrides.connector_id ?? 'discord',
  display_name: overrides.display_name ?? 'Discord',
  channel: overrides.channel ?? 'discord',
  available: overrides.available ?? true,
  gate_healthy: overrides.gate_healthy ?? true,
  configured_bindings: overrides.configured_bindings ?? [],
  capabilities: overrides.capabilities ?? ['bindings'],
  ...(overrides as object),
}) as GateConnectorInfo

describe('ConnectorOverviewStrip', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('always renders one tile per known sidecar (4 tiles)', () => {
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const tiles = container.querySelectorAll('[data-overview-tile]')
    expect(tiles.length).toBe(4)
    const ids = Array.from(tiles).map(t => t.getAttribute('data-overview-tile'))
    expect(ids).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('marks running connector as 🟢 connected and offline ones as ⊘ offline', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true })]}
        keeperCount=${0}
      />`,
      container,
    )
    const discordTile = container.querySelector('[data-overview-tile="discord"]')!
    const imessageTile = container.querySelector('[data-overview-tile="imessage"]')!
    expect(discordTile.textContent).toContain('connected')
    expect(imessageTile.textContent).toContain('offline')
  })

  it('Start All button counts only sidecars currently down', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true }),
          mkConnector({ connector_id: 'slack', available: true }),
        ]}
        keeperCount=${0}
      />`,
      container,
    )
    const startBtn = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    const stopBtn = container.querySelector('[data-bulk-action="stop"]') as HTMLButtonElement
    // 2 of 4 are up → 2 down → Start All shows (2). 2 up → Stop All (2).
    expect(startBtn.textContent).toContain('(2)')
    expect(stopBtn.textContent).toContain('(2)')
  })

  it('Start All disabled when all sidecars are already up', () => {
    _testResetBulkInflight()
    const allUp = ['discord', 'imessage', 'slack', 'telegram'].map(id =>
      mkConnector({ connector_id: id, available: true }),
    )
    render(
      html`<${ConnectorOverviewStrip} connectors=${allUp} keeperCount=${0} />`,
      container,
    )
    const startBtn = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    expect(startBtn.disabled).toBe(true)
    expect(startBtn.title).toContain('이미 실행')
  })

  it('Stop All disabled when nothing is up', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const stopBtn = container.querySelector('[data-bulk-action="stop"]') as HTMLButtonElement
    expect(stopBtn.disabled).toBe(true)
    expect(stopBtn.title).toContain('실행 중인 sidecar 없음')
  })

  it('renders 4 readiness pills inside each tile', () => {
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const discordTile = container.querySelector('[data-overview-tile="discord"]')!
    const pills = discordTile.querySelectorAll('[data-rail-pill]')
    expect(pills.length).toBe(4)
  })

  it('strip root has sticky positioning so it stays visible while scrolling', () => {
    render(html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`, container)
    const root = container.querySelector('[data-overview-strip-root]') as HTMLElement
    expect(root).toBeTruthy()
    expect(root.className).toContain('sticky')
    expect(root.className).toContain('top-0')
  })

  it('shows incident banner for ids that dropped within the last 5 minutes', () => {
    _testResetStripMemory()
    _testSetStripMemory({ lastSeenUp: { discord: Date.now() - 60_000 } })
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: false })]}
        keeperCount=${0}
      />`,
      container,
    )
    const banner = container.querySelector('[data-incident-banner]')
    expect(banner).toBeTruthy()
    expect(banner?.textContent).toContain('Discord')
    expect(banner?.textContent).toContain('최근 5분')
  })

  it('hides incident banner when no sidecar has dropped (baseline offline)', () => {
    _testResetStripMemory()
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    expect(container.querySelector('[data-incident-banner]')).toBeNull()
  })

  it('celebration banner hidden when fewer than 4 sidecars are up', () => {
    _testResetBulkInflight()
    const threeUp = ['discord', 'imessage', 'slack'].map(id => mkConnector({ connector_id: id, available: true }))
    render(html`<${ConnectorOverviewStrip} connectors=${threeUp} keeperCount=${0} />`, container)
    expect(container.querySelector('[data-celebration]')).toBeNull()
  })

  it('celebration banner shows when all 4 sidecars are up', () => {
    _testResetBulkInflight()
    const allUp = ['discord', 'imessage', 'slack', 'telegram'].map(id => mkConnector({ connector_id: id, available: true }))
    render(html`<${ConnectorOverviewStrip} connectors=${allUp} keeperCount=${0} />`, container)
    const banner = container.querySelector('[data-celebration="all-connected"]')
    expect(banner).toBeTruthy()
    expect(banner?.textContent).toContain('4/4')
  })

  it('uptime chip renders inside tile when sidecar is up and last_ready_at is recent', () => {
    _testResetBulkInflight()
    const readyAt = new Date(Date.now() - 65 * 1000).toISOString()
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true, last_ready_at: readyAt })]}
        keeperCount=${0}
      />`,
      container,
    )
    const tile = container.querySelector('[data-overview-tile="discord"]')!
    const chip = tile.querySelector('[data-uptime-chip]')
    expect(chip).toBeTruthy()
    expect(chip?.textContent).toMatch(/^up 1m/)
  })

  it('uptime chip absent when sidecar is down, even with a stale last_ready_at', () => {
    _testResetBulkInflight()
    const readyAt = new Date(Date.now() - 60 * 1000).toISOString()
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: false, last_ready_at: readyAt })]}
        keeperCount=${0}
      />`,
      container,
    )
    const tile = container.querySelector('[data-overview-tile="discord"]')!
    expect(tile.querySelector('[data-uptime-chip]')).toBeNull()
  })

  it('uptime chip absent when last_ready_at is missing/empty', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true, last_ready_at: '' })]}
        keeperCount=${0}
      />`,
      container,
    )
    const tile = container.querySelector('[data-overview-tile="discord"]')!
    expect(tile.querySelector('[data-uptime-chip]')).toBeNull()
  })
})

describe('formatConnectorUptime', () => {
  const NOW = Date.UTC(2026, 3, 17, 12, 0, 0) // deterministic fixed "now"

  it('returns null for null/undefined/empty input', () => {
    expect(formatConnectorUptime(null, NOW)).toBeNull()
    expect(formatConnectorUptime(undefined, NOW)).toBeNull()
    expect(formatConnectorUptime('', NOW)).toBeNull()
    expect(formatConnectorUptime('   ', NOW)).toBeNull()
  })

  it('returns null for unparseable date strings', () => {
    expect(formatConnectorUptime('not-a-date', NOW)).toBeNull()
    expect(formatConnectorUptime('garbage 🦖', NOW)).toBeNull()
  })

  it('returns null when last_ready_at is in the future (clock skew)', () => {
    const future = new Date(NOW + 10 * 60 * 1000).toISOString()
    expect(formatConnectorUptime(future, NOW)).toBeNull()
  })

  it('formats seconds, minutes+seconds, and hours+minutes', () => {
    const sec30 = new Date(NOW - 30 * 1000).toISOString()
    expect(formatConnectorUptime(sec30, NOW)).toBe('up 30s')

    const min5 = new Date(NOW - (5 * 60 + 12) * 1000).toISOString()
    expect(formatConnectorUptime(min5, NOW)).toBe('up 5m 12s')

    const hr3 = new Date(NOW - (3 * 3600 + 22 * 60) * 1000).toISOString()
    expect(formatConnectorUptime(hr3, NOW)).toBe('up 3h 22m')
  })
})

describe('summarizeConnectorStrip', () => {
  it('returns zeros for empty input', () => {
    expect(summarizeConnectorStrip([], 0)).toEqual({
      sidecarUp: 0,
      sidecarTotal: 4,
      bindingCount: 0,
      keeperCount: 0,
    })
  })

  it('sums bindings only across KNOWN connectors (unknown bridges excluded)', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true, configured_bindings: ['a', 'b'] as any }),
      mkConnector({ connector_id: 'slack', available: true, configured_bindings: ['c'] as any }),
      mkConnector({ connector_id: 'unknown-bridge', available: true, configured_bindings: ['x', 'y', 'z'] as any }),
    ]
    const s = summarizeConnectorStrip(list, 5)
    expect(s.sidecarUp).toBe(2)
    expect(s.sidecarTotal).toBe(4)
    expect(s.bindingCount).toBe(3) // unknown-bridge's 3 excluded
    expect(s.keeperCount).toBe(5)
  })

  it('treats missing configured_bindings as 0', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true }), // default configured_bindings = []
    ]
    const s = summarizeConnectorStrip(list, 0)
    expect(s.bindingCount).toBe(0)
  })
})

describe('countConnectedSidecars', () => {
  it('returns 0 for empty list', () => {
    expect(countConnectedSidecars([])).toBe(0)
  })

  it('counts only available=true known sidecars', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true }),
      mkConnector({ connector_id: 'slack', available: false }),
      mkConnector({ connector_id: 'unknown-bridge', available: true }),
    ]
    expect(countConnectedSidecars(list)).toBe(1)
  })
})

describe('stripMemory pure helpers', () => {
  const NOW = 1_700_000_000_000

  it('updateStripMemory records timestamp for each up sidecar, leaves down ones untouched', () => {
    const prev = { lastSeenUp: { discord: NOW - 10_000 } }
    const next = updateStripMemory(prev, [
      mkConnector({ connector_id: 'discord', available: true }),
      mkConnector({ connector_id: 'slack', available: false }),
    ], NOW)
    expect(next.lastSeenUp.discord).toBe(NOW)
    expect(next.lastSeenUp.slack).toBeUndefined()
  })

  it('detectRecentDrops flags down ids whose last-up is inside the window', () => {
    const memory = {
      lastSeenUp: {
        discord: NOW - 60_000,
        slack: NOW - 10 * 60_000,
        telegram: null,
      },
    }
    const dropped = detectRecentDrops(memory, [
      mkConnector({ connector_id: 'discord', available: false }),
      mkConnector({ connector_id: 'slack', available: false }),
      mkConnector({ connector_id: 'telegram', available: false }),
      mkConnector({ connector_id: 'imessage', available: true }),
    ], NOW)
    expect(dropped).toEqual(['discord'])
  })

  it('detectRecentDrops excludes ids currently up even if they were recently up', () => {
    const memory = { lastSeenUp: { discord: NOW - 30_000 } }
    const dropped = detectRecentDrops(memory, [
      mkConnector({ connector_id: 'discord', available: true }),
    ], NOW)
    expect(dropped).toEqual([])
  })

  it('detectRecentDrops respects custom window', () => {
    const memory = { lastSeenUp: { discord: NOW - 2 * 60_000 } }
    const dropped = detectRecentDrops(
      memory,
      [mkConnector({ connector_id: 'discord', available: false })],
      NOW,
      60_000,
    )
    expect(dropped).toEqual([])
  })
})

describe('tilePrimaryActionView (pure)', () => {
  it('sidecar down, not inflight → Start (emerald), not busy', () => {
    expect(tilePrimaryActionView(false, false)).toEqual({
      label: '▶ Start', tone: 'start', busy: false,
    })
  })

  it('sidecar down, inflight → 시작 중... (start tone, busy)', () => {
    expect(tilePrimaryActionView(false, true)).toEqual({
      label: '시작 중...', tone: 'start', busy: true,
    })
  })

  it('sidecar up, not inflight → Stop (rose), not busy', () => {
    expect(tilePrimaryActionView(true, false)).toEqual({
      label: '■ Stop', tone: 'stop', busy: false,
    })
  })

  it('sidecar up, inflight → 정지 중... (stop tone, busy)', () => {
    expect(tilePrimaryActionView(true, true)).toEqual({
      label: '정지 중...', tone: 'stop', busy: true,
    })
  })
})

describe('TilePrimaryAction component (rendered inside ConnectorOverviewStrip)', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetBulkInflight()
    _testResetStripMemory()
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a Start button (emerald) for a down sidecar', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: false })]}
        keeperCount=${0}
      />`,
      container,
    )
    const btn = container.querySelector('[data-tile-primary-action="discord"]') as HTMLButtonElement
    expect(btn).toBeTruthy()
    expect(btn.getAttribute('data-tile-primary-action-tone')).toBe('start')
    expect(btn.textContent?.trim()).toBe('▶ Start')
    expect(btn.className).toContain('emerald')
  })

  it('renders a Stop button (rose) for an up sidecar', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true })]}
        keeperCount=${0}
      />`,
      container,
    )
    const btn = container.querySelector('[data-tile-primary-action="discord"]') as HTMLButtonElement
    expect(btn.getAttribute('data-tile-primary-action-tone')).toBe('stop')
    expect(btn.textContent?.trim()).toBe('■ Stop')
    expect(btn.className).toContain('rose')
  })

  it('aria-label names the connector + action (screen-reader parity)', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'slack', available: false })]}
        keeperCount=${0}
      />`,
      container,
    )
    const btn = container.querySelector('[data-tile-primary-action="slack"]')!
    expect(btn.getAttribute('aria-label')).toBe('slack sidecar 시작')
  })

  it('every known tile gets a primary action button (no missing rows)', () => {
    // Regression guard: adding a 5th bridge must not leave three tiles
    // with buttons and one tile without (asymmetric view that would
    // be hard to spot visually).
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[]}
        keeperCount=${0}
      />`,
      container,
    )
    expect(container.querySelectorAll('[data-tile-primary-action]').length).toBeGreaterThanOrEqual(4)
  })
})
