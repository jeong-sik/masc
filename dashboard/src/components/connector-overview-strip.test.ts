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
  summarizeOverviewTile,
  tilePrimaryActionView,
  formatTileIdentityLine,
  offlineConnectorNames,
  formatOfflineConnectorLabel,
  deriveTileNotice,
} from './connector-overview-strip'
import type { GateConnectorInfo } from '../api/gate'

const mkConnector = (overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo => ({
  connector_id: overrides.connector_id ?? 'discord',
  display_name: overrides.display_name ?? 'Discord',
  channel: overrides.channel ?? 'discord',
  status: overrides.status ?? ((overrides.available ?? true) ? 'connected' : 'offline'),
  available: overrides.available ?? true,
  connected: overrides.connected ?? (overrides.available ?? true),
  stale: overrides.stale ?? false,
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

  it('shows visible summary copy for healthy and offline tiles', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({ connector_id: 'discord', available: true, configured_bindings: ['room-1'] as any })]}
        keeperCount=${0}
      />`,
      container,
    )
    const discordTile = container.querySelector('[data-overview-tile="discord"]')!
    const imessageTile = container.querySelector('[data-overview-tile="imessage"]')!
    expect(discordTile.textContent).toContain('정상')
    expect(discordTile.textContent).toContain('binding active')
    expect(imessageTile.textContent).toContain('설정 필요')
    expect(imessageTile.textContent).toContain('Config와 Start')
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
    const startBtn = container.querySelector('[data-testid="bulk-action-start"]') as HTMLButtonElement
    const stopBtn = container.querySelector('[data-testid="bulk-action-stop"]') as HTMLButtonElement
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
    const startBtn = container.querySelector('[data-testid="bulk-action-start"]') as HTMLButtonElement
    expect(startBtn.disabled).toBe(true)
    expect(startBtn.title).toContain('이미 실행')
  })

  it('Stop All disabled when nothing is up', () => {
    _testResetBulkInflight()
    render(
      html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`,
      container,
    )
    const stopBtn = container.querySelector('[data-testid="bulk-action-stop"]') as HTMLButtonElement
    expect(stopBtn.disabled).toBe(true)
    expect(stopBtn.title).toContain('실행 중인 sidecar 없음')
  })

  it('marks the selected tile and exposes a detail CTA', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[]}
        keeperCount=${0}
        selectedConnectorId="slack"
      />`,
      container,
    )
    const slackTile = container.querySelector('[data-overview-tile="slack"]') as HTMLElement
    const discordTile = container.querySelector('[data-overview-tile="discord"]') as HTMLElement
    expect(slackTile.dataset.overviewSelected).toBe('true')
    expect(slackTile.textContent).toContain('Selected')
    expect(discordTile.textContent).toContain('View Details')
  })

  it('strip root is a regular surface, not a sticky header', () => {
    render(html`<${ConnectorOverviewStrip} connectors=${[]} keeperCount=${0} />`, container)
    const root = container.querySelector('[data-overview-strip-root]') as HTMLElement
    expect(root).toBeTruthy()
    expect(root.className).toContain('rounded')
    expect(root.className).not.toContain('sticky')
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

  it('does not render the old celebration banner even when all 4 sidecars are up', () => {
    _testResetBulkInflight()
    const allUp = ['discord', 'imessage', 'slack', 'telegram'].map(id => mkConnector({ connector_id: id, available: true }))
    render(html`<${ConnectorOverviewStrip} connectors=${allUp} keeperCount=${0} />`, container)
    expect(container.querySelector('[data-celebration]')).toBeNull()
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
      runningCount: 0,
      healthyCount: 0,
      connectorTotal: 4,
      bindingCount: 0,
    })
  })

  it('sums bindings only across KNOWN connectors (unknown bridges excluded)', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true, configured_bindings: ['a', 'b'] as any }),
      mkConnector({ connector_id: 'slack', available: true, configured_bindings: ['c'] as any }),
      mkConnector({ connector_id: 'unknown-bridge', available: true, configured_bindings: ['x', 'y', 'z'] as any }),
    ]
    const s = summarizeConnectorStrip(list, 5)
    expect(s.runningCount).toBe(2)
    expect(s.healthyCount).toBe(2)
    expect(s.connectorTotal).toBe(4)
    expect(s.bindingCount).toBe(3) // unknown-bridge's 3 excluded
  })

  it('treats missing configured_bindings as 0', () => {
    const list = [
      mkConnector({ connector_id: 'discord', available: true }), // default configured_bindings = []
    ]
    const s = summarizeConnectorStrip(list, 0)
    expect(s.bindingCount).toBe(0)
  })
})

describe('summarizeOverviewTile', () => {
  it('treats missing connectors as setup-needed', () => {
    expect(summarizeOverviewTile(null, 0)).toEqual(expect.objectContaining({
      badge: '설정 필요',
    }))
  })

  it('treats stale connectors as attention-needed', () => {
    expect(summarizeOverviewTile(
      mkConnector({ connector_id: 'discord', available: true, stale: true, status: 'stale' }),
      0,
    )).toEqual(expect.objectContaining({
      badge: '주의',
    }))
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
    expect(btn.className).toContain('var(--color-status-ok)')
  })

  it('renders a Stop button (bad) for an up sidecar', () => {
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
    expect(btn.className).toContain('var(--bad-light)')
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

describe('formatTileIdentityLine (pure)', () => {
  it('null connector → null (no row rendered)', () => {
    expect(formatTileIdentityLine(null)).toBeNull()
  })

  it('bot only → \"as @bot\"', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: 'claude-bot',
      guild_count: 0,
    }))).toBe('as @claude-bot')
  })

  it('guilds only → \"N guilds\" (plural)', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: '',
      guild_count: 3,
    }))).toBe('3 guilds')
  })

  it('singular guild → \"1 guild\" (no plural suffix)', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: '',
      guild_count: 1,
    }))).toBe('1 guild')
  })

  it('bot + guilds → joined with bullet separator', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: 'claude-bot',
      guild_count: 4,
    }))).toBe('as @claude-bot · 4 guilds')
  })

  it('whitespace-only bot is ignored (no \"as @\" ghost)', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: '   ',
      guild_count: 0,
    }))).toBeNull()
  })

  it('both empty → null (no clutter row when nothing to show)', () => {
    expect(formatTileIdentityLine(mkConnector({
      bot_user_name: '',
      guild_count: 0,
    }))).toBeNull()
  })
})

describe('Tile identity line (rendered inside ConnectorOverviewStrip)', () => {
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

  it('renders identity line when bot_user_name is set', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({
          connector_id: 'discord',
          bot_user_name: 'claude-bot',
          guild_count: 2,
        })]}
        keeperCount=${0}
      />`,
      container,
    )
    const line = container.querySelector('[data-tile-identity="discord"]')!
    expect(line.textContent).toBe('as @claude-bot · 2 guilds')
    expect(line.getAttribute('title')).toBe('as @claude-bot · 2 guilds')
  })

  it('omits identity line when both fields are empty', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({
          connector_id: 'discord',
          bot_user_name: '',
          guild_count: 0,
        })]}
        keeperCount=${0}
      />`,
      container,
    )
    expect(container.querySelector('[data-tile-identity="discord"]')).toBeNull()
  })
})

describe('offlineConnectorNames (pure)', () => {
  it('empty connectors → []', () => {
    expect(offlineConnectorNames([])).toEqual([])
  })

  it('all up → [] (no offline to annotate)', () => {
    expect(offlineConnectorNames([
      mkConnector({ connector_id: 'discord', available: true }),
      mkConnector({ connector_id: 'slack', available: true }),
    ])).toEqual([])
  })

  it('marks observed-but-offline connectors by display name', () => {
    expect(offlineConnectorNames([
      mkConnector({ connector_id: 'discord', available: true }),
      mkConnector({ connector_id: 'slack', available: false }),
    ])).toEqual(['Slack'])
  })

  it('multiple offline returned in canonical tile order (not input order)', () => {
    // Input order: [slack, discord] (reversed from KNOWN_CONNECTOR_IDS).
    // Expected output: canonical order [Discord, Slack] — matches the
    // visual scan path below the summary line.
    expect(offlineConnectorNames([
      mkConnector({ connector_id: 'slack', available: false }),
      mkConnector({ connector_id: 'discord', available: false }),
    ])).toEqual(['Discord', 'Slack'])
  })

  it('connector not yet observed (absent from array) is not marked offline', () => {
    // Regression guard: \"missing\" is ambiguous — could be bootstrapping.
    // Only mark offline when we've actually seen available=false.
    expect(offlineConnectorNames([])).toEqual([])
  })
})

describe('formatOfflineConnectorLabel (pure)', () => {
  it('empty → null (no annotation when all are up)', () => {
    expect(formatOfflineConnectorLabel([])).toBeNull()
  })

  it('single → \"Name offline\"', () => {
    expect(formatOfflineConnectorLabel(['Slack'])).toBe('Slack offline')
  })

  it('two → \"A · B offline\" (both listed)', () => {
    expect(formatOfflineConnectorLabel(['Discord', 'Slack'])).toBe('Discord · Slack offline')
  })

  it('three+ → first two listed + \"+N offline\" overflow (Statuspage convention)', () => {
    expect(formatOfflineConnectorLabel(['Discord', 'Slack', 'Telegram']))
      .toBe('Discord · Slack · +1 offline')
    expect(formatOfflineConnectorLabel(['Discord', 'Slack', 'Telegram', 'iMessage']))
      .toBe('Discord · Slack · +2 offline')
  })
})

describe('StatusSummaryLine offline annotation (rendered inside ConnectorOverviewStrip)', () => {
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

  it('omits the annotation when all connectors are up', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true }),
          mkConnector({ connector_id: 'slack', available: true }),
          mkConnector({ connector_id: 'telegram', available: true }),
          mkConnector({ connector_id: 'imessage', available: true }),
        ]}
        keeperCount=${0}
      />`,
      container,
    )
    expect(container.querySelector('[data-strip-summary-offline-names]')).toBeNull()
  })

  it('annotates offline connector by name', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[
          mkConnector({ connector_id: 'discord', available: true }),
          mkConnector({ connector_id: 'slack', available: false }),
        ]}
        keeperCount=${0}
      />`,
      container,
    )
    const annotation = container.querySelector('[data-strip-summary-offline-names]') as HTMLElement
    expect(annotation).toBeTruthy()
    expect(annotation.textContent).toContain('Slack offline')
    // #8273 swapped the raw rose utility for the --bad-light semantic token
    // on this annotation (start/stop buttons and error notices still carry
    // the border/bg rose classes, only the bare text class changed here).
    expect(annotation.className).toContain('--bad')
  })
})

describe('deriveTileNotice (pure)', () => {
  it('null connector → null notice (empty grid cell, no ribbon)', () => {
    expect(deriveTileNotice(null)).toBeNull()
  })

  it('clean connector (no error, not stale) → null', () => {
    expect(deriveTileNotice(mkConnector({ error: '', stale: false }))).toBeNull()
  })

  it('non-empty error → rose notice with the error text', () => {
    const notice = deriveTileNotice(mkConnector({
      error: 'Discord gateway timeout',
      stale: false,
    }))
    expect(notice).toEqual({
      tone: 'error',
      label: '오류',
      detail: 'Discord gateway timeout',
    })
  })

  it('whitespace-only error is ignored (no false positives)', () => {
    expect(deriveTileNotice(mkConnector({ error: '   ' }))).toBeNull()
  })

  it('stale without error → amber notice with threshold hint', () => {
    const notice = deriveTileNotice(mkConnector({
      error: '',
      stale: true,
      stale_after_sec: 60,
    }))
    expect(notice).toEqual({
      tone: 'stale',
      label: '오래됨',
      detail: '데이터 오래됨 (60s threshold)',
    })
  })

  it('stale without threshold → amber notice, no (Xs threshold) suffix', () => {
    const notice = deriveTileNotice(mkConnector({
      error: '',
      stale: true,
      stale_after_sec: 0,
    }))
    expect(notice?.detail).toBe('데이터 오래됨')
  })

  it('error beats stale when both truthy (explicit error is more diagnostic)', () => {
    // Regression guard: an explicit error message is strictly more
    // diagnostic than a generic \"data is old\" flag. If both fire, the
    // operator sees the error first.
    const notice = deriveTileNotice(mkConnector({
      error: 'auth failed',
      stale: true,
    }))
    expect(notice?.tone).toBe('error')
    expect(notice?.detail).toBe('auth failed')
  })
})

describe('TileErrorNotice component (rendered inside ConnectorOverviewStrip)', () => {
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

  it('renders a rose notice ribbon when the connector reports an error', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({
          connector_id: 'discord',
          available: true,
          error: 'WebSocket closed 4004',
        })]}
        keeperCount=${0}
      />`,
      container,
    )
    const notice = container.querySelector('[data-tile-notice="error"]') as HTMLElement
    expect(notice).toBeTruthy()
    expect(notice.textContent).toContain('오류')
    expect(notice.textContent).toContain('WebSocket closed 4004')
    expect(notice.className).toContain('var(--bad-light)')
    expect(notice.getAttribute('role')).toBe('alert')
  })

  it('renders a warn notice ribbon when the connector is stale without error', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({
          connector_id: 'discord',
          available: true,
          error: '',
          stale: true,
          stale_after_sec: 30,
        })]}
        keeperCount=${0}
      />`,
      container,
    )
    const notice = container.querySelector('[data-tile-notice="stale"]') as HTMLElement
    expect(notice.textContent).toContain('오래됨')
    expect(notice.className).toContain('var(--color-status-warn)')
  })

  it('renders nothing when connector is clean (no ribbon clutter)', () => {
    render(
      html`<${ConnectorOverviewStrip}
        connectors=${[mkConnector({
          connector_id: 'discord',
          available: true,
          error: '',
          stale: false,
        })]}
        keeperCount=${0}
      />`,
      container,
    )
    expect(container.querySelector('[data-tile-notice]')).toBeNull()
  })
})
