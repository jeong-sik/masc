// ConnectorOverviewStrip — top-of-page compact strip showing all 4 known
// sidecars at once. Each tile is a brand-colored mini card with the
// readiness rail underneath and one primary action (Start when down,
// Stop when up). Clicking the tile body smooth-scrolls to that
// connector's full panel below in the page.
//
// Rendered only on the all-connectors view (`section=connector-status`).
// Per-bridge sub-sections already filter to one panel and don't need an
// at-a-glance strip on top.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import type { GateConnectorInfo } from '../api/gate'
import { ConnectorReadinessRail, deriveRail, getRailInflight, withRailInflight } from './connector-readiness-rail'
import { CONNECTOR_DISPLAY_NAMES, KNOWN_CONNECTOR_IDS, channelIcon, connectorAccentStyle, connectorStateLabel, startSidecar, stopSidecar, type KnownConnectorId } from './connector-status'
import { openConnectorConfig } from './connector-config-form'
import { formatElapsedCompact } from '../lib/format-time'
import { HeartbeatStrip } from './common/heartbeat-strip'
import { HeartbeatStreakChip } from './common/heartbeat-streak-chip'
import { HeartbeatUptimeChip } from './common/heartbeat-uptime-chip'
import { LivePulseDot } from './common/live-pulse-dot'
import { Sparkline } from './common/sparkline'
import { recordHeartbeat, useHeartbeatHistory, lastHeartbeatTickMs, rollingUptimeSeries, type HeartbeatState } from '../lib/heartbeat-history'

/** Sampling cadence for the heartbeat ring buffer. Chosen so 45 bars
    cover ~22 minutes of history — matches Uptime Kuma's default
    "last 45 checks at 30s interval" visual rhythm. */
const HEARTBEAT_SAMPLE_MS = 30_000

/** Wall-clock tick for the live-pulse indicator — updates every second
    so the dot can flip from live to stale without needing a prop change.
    Kept module-scope so every StatusSummaryLine instance shares one
    timer instead of N. */
const livePulseNowMs = signal<number>(Date.now())
if (typeof window !== 'undefined') {
  window.setInterval(() => { livePulseNowMs.value = Date.now() }, 1000)
}

/** Pure: derive the heartbeat state for a connector from the gate info
    that the overview strip already polls. No extra network calls. */
function deriveHeartbeatState(
  connector: GateConnectorInfo | null,
): HeartbeatState {
  if (connector === null) return 'unknown'
  if (connector.available === true) return 'up'
  return 'down'
}

const bulkInflight = signal<{ start: boolean; stop: boolean }>({ start: false, stop: false })

/** Pure: derive a compact "up X" string from the sidecar's last_ready_at
    timestamp. Returns null when the timestamp is empty/invalid/in the
    future — the tile then hides the chip rather than rendering NaN. */
export function formatConnectorUptime(
  readyAtIso: string | null | undefined,
  now: number,
): string | null {
  if (readyAtIso === null || readyAtIso === undefined) return null
  const trimmed = readyAtIso.trim()
  if (trimmed === '') return null
  const then = Date.parse(trimmed)
  if (Number.isNaN(then)) return null
  const elapsedSec = Math.floor((now - then) / 1000)
  if (elapsedSec < 0) return null
  return `up ${formatElapsedCompact(elapsedSec)}`
}

interface StripMemory {
  lastSeenUp: Record<string, number | null>
}

const INCIDENT_WINDOW_MS = 5 * 60 * 1000

const stripMemory = signal<StripMemory>({ lastSeenUp: {} })

export function updateStripMemory(
  prev: StripMemory,
  connectors: GateConnectorInfo[],
  now: number,
): StripMemory {
  const lastSeenUp = { ...prev.lastSeenUp }
  for (const id of KNOWN_CONNECTOR_IDS) {
    const up = connectors.find(c => c.connector_id === id)?.available === true
    if (up) lastSeenUp[id] = now
  }
  return { lastSeenUp }
}

export function detectRecentDrops(
  memory: StripMemory,
  connectors: GateConnectorInfo[],
  now: number,
  windowMs: number = INCIDENT_WINDOW_MS,
): string[] {
  const dropped: string[] = []
  for (const id of KNOWN_CONNECTOR_IDS) {
    const up = connectors.find(c => c.connector_id === id)?.available === true
    if (up) continue
    const lastUp = memory.lastSeenUp[id]
    if (lastUp === undefined || lastUp === null) continue
    if (now - lastUp > windowMs) continue
    dropped.push(id)
  }
  return dropped
}

async function runBulk(
  kind: 'start' | 'stop',
  predicate: (c: GateConnectorInfo | null) => boolean,
  connectors: GateConnectorInfo[],
) {
  if (bulkInflight.value[kind]) return
  bulkInflight.value = { ...bulkInflight.value, [kind]: true }
  try {
    const targets = KNOWN_CONNECTOR_IDS.filter(id => predicate(findConnector(connectors, id)))
    // Per-connector pulse (the same withRailInflight that single-pill uses) so
    // each tile's Process pill shows progress; runs in parallel.
    await Promise.allSettled(
      targets.map(id =>
        withRailInflight(id, 'process', () => kind === 'start' ? startSidecar(id) : stopSidecar(id)),
      ),
    )
  } finally {
    bulkInflight.value = { ...bulkInflight.value, [kind]: false }
  }
}

interface OverviewProps {
  connectors: GateConnectorInfo[]
  keeperCount: number
  selectedConnectorId?: KnownConnectorId | null
  onSelectConnector?: (connectorId: KnownConnectorId) => void
  detailTargetId?: string
}

function findConnector(connectors: GateConnectorInfo[], id: string): GateConnectorInfo | null {
  return connectors.find(c => c.connector_id === id) ?? null
}

function scrollToDetail(targetId: string) {
  const el = document.getElementById(targetId)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

interface OverviewTileSummary {
  badge: string
  badgeClass: string
  detail: string
}

export function summarizeOverviewTile(
  connector: GateConnectorInfo | null,
  keeperCount: number,
): OverviewTileSummary {
  if (connector === null || connector.available !== true) {
    return {
      badge: '설정 필요',
      badgeClass: 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]',
      detail: keeperCount > 0
        ? '아직 시작되지 않음 · 시작 후 keeper를 바인딩하세요'
        : '아직 시작되지 않음 · 먼저 Config와 Start가 필요합니다',
    }
  }

  const bindingCount = connector.configured_bindings?.length ?? 0
  const stateLabel = connectorStateLabel(connector)
  if (stateLabel === 'stale' || stateLabel === 'disconnected' || connector.gate_healthy === false) {
    return {
      badge: '주의',
      badgeClass: 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]',
      detail: stateLabel === 'stale'
        ? 'heartbeat가 stale 상태입니다 · 로그와 gate 상태를 확인하세요'
        : stateLabel === 'disconnected'
          ? 'sidecar는 실행 중이지만 채널 연결이 비정상입니다'
          : 'gate health가 비정상입니다 · 상세 카드에서 원인을 확인하세요',
    }
  }

  if (bindingCount === 0) {
    return {
      badge: '바인딩 필요',
      badgeClass: 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]',
      detail: keeperCount > 0
        ? '실행 중 · 아직 channel binding이 없습니다'
        : '실행 중 · keeper 디렉토리가 비어 있습니다',
    }
  }

  return {
    badge: '정상',
    badgeClass: 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok)]',
    detail: `실행 중 · ${bindingCount} ${bindingCount === 1 ? 'binding' : 'bindings'} active`,
  }
}

function OverviewTile({ id, connector, keeperCount, selected, onSelectConnector, detailTargetId }: {
  id: KnownConnectorId
  connector: GateConnectorInfo | null
  keeperCount: number
  selected: boolean
  onSelectConnector?: (connectorId: KnownConnectorId) => void
  detailTargetId: string
}) {
  const sidecarUp = connector?.available === true
  const uptimeLabel = sidecarUp ? formatConnectorUptime(connector?.last_ready_at, Date.now()) : null
  const selectConnector = (scroll: boolean = true) => {
    onSelectConnector?.(id)
    if (scroll) scrollToDetail(detailTargetId)
  }
  const pills = deriveRail(
    {
      sidecarUp,
      gateHealthy: connector?.gate_healthy ?? null,
      bindingCount: connector?.configured_bindings?.length ?? 0,
      keeperCount,
    },
    {
      openConfig: () => openConnectorConfig(id),
      toggleProcess: () => {
        void withRailInflight(id, 'process', () =>
          sidecarUp ? stopSidecar(id) : startSidecar(id),
        )
      },
      expandHeader: () => selectConnector(true),
      scrollToBindings: () => selectConnector(true),
    },
    getRailInflight(id),
  )
  const accent = connectorAccentStyle(id)
  const displayName = CONNECTOR_DISPLAY_NAMES[id] ?? id
  const summary = summarizeOverviewTile(connector, keeperCount)

  return html`
    <div
      class=${`flex min-w-0 flex-col gap-3 rounded border bg-[var(--bg-1)] p-3 transition-colors ${
        selected
          ? 'border-[var(--accent)] shadow-[0_0_0_1px_var(--accent-18)]'
          : 'border-[var(--white-8)] hover:border-[var(--white-10)]'
      }`}
      data-overview-tile=${id}
      data-overview-selected=${selected ? 'true' : 'false'}
    >
      <button type="button"
        class="flex min-w-0 cursor-pointer items-start gap-3 text-left"
        onClick=${() => selectConnector(true)}
        aria-label=${`${displayName} 상세 보기`}
        aria-pressed=${selected ? 'true' : 'false'}
      >
        <span
          class="flex h-7 w-7 shrink-0 items-center justify-center rounded text-base"
          style=${accent}
        >${channelIcon(id)}</span>
        <span class="min-w-0 flex-1">
          <span class="flex items-center gap-2">
            <span class="block truncate text-sm font-semibold text-[var(--text-body)]" title=${displayName}>${displayName}</span>
            <span class=${`rounded-sm border px-2 py-0.5 text-3xs font-medium ${summary.badgeClass}`}>${summary.badge}</span>
            ${uptimeLabel !== null
              ? html`
                  <span
                    class="rounded-sm border border-[var(--ok-20)] bg-[var(--ok-10)] px-1.5 py-px text-3xs font-normal text-[var(--ok)]/80"
                    data-uptime-chip
                    title="last_ready_at 기준 경과 시간"
                  >${uptimeLabel}</span>
                `
              : null}
          </span>
          <span class="mt-1 block text-2xs leading-5 text-[var(--text-dim)]" data-overview-summary>${summary.detail}</span>
          ${(() => {
            const identity = formatTileIdentityLine(connector)
            return identity !== null
              ? html`<span
                  class="mt-1 block truncate text-3xs text-[var(--text-dim)]"
                  data-tile-identity=${id}
                  title=${identity}
                >${identity}</span>`
              : null
          })()}
        </span>
      </button>
      <${ConnectorReadinessRail} pills=${pills} />
      <span class=${`text-3xs uppercase tracking-4 ${selected ? 'text-[var(--accent-1)]' : 'text-[var(--text-dim)]'}`}>
        ${selected ? 'Selected' : 'View Details'}
      </span>
      <${TilePrimaryAction} id=${id} sidecarUp=${sidecarUp} />
      <${TileErrorNotice} connector=${connector} />
      <${TileHeartbeatStrip} id=${id} />
    </div>
  `
}

/** Pure: single-line identity summary for the tile — \"as @bot · N guilds\"
    style. Composes bot_user_name + guild_count into one truncate-safe
    string. Returns null when neither field has anything to show, so
    the caller renders nothing instead of an empty row.

    Why both on one line: tile vertical space is tight. A dedicated
    \"reach\" chip would add a whole new visual band; a compact subtitle
    line sits inside the existing header block. Reference: Stripe row
    subtitle \"paid · \$12.50\" / Linear issue row \"in Backlog · 3h\". */
export function formatTileIdentityLine(
  connector: GateConnectorInfo | null,
): string | null {
  if (connector === null) return null
  const parts: string[] = []
  const bot = connector.bot_user_name?.trim() ?? ''
  if (bot !== '') parts.push(`as @${bot}`)
  const guilds = connector.guild_count ?? 0
  if (guilds > 0) {
    parts.push(`${guilds} ${guilds === 1 ? 'guild' : 'guilds'}`)
  }
  return parts.length === 0 ? null : parts.join(' · ')
}

/** Pure: derive the primary-action button label/tone from the sidecar
    state + inflight flag. Exposed so tests pin the four combinations
    without mounting the component. */
interface TilePrimaryActionView {
  label: string
  tone: 'start' | 'stop'
  busy: boolean
}
export function tilePrimaryActionView(
  sidecarUp: boolean,
  inflight: boolean,
): TilePrimaryActionView {
  if (sidecarUp) {
    return {
      label: inflight ? '정지 중...' : '■ Stop',
      tone: 'stop',
      busy: inflight,
    }
  }
  return {
    label: inflight ? '시작 중...' : '▶ Start',
    tone: 'start',
    busy: inflight,
  }
}

const TILE_ACTION_TONE_CLASS: Record<'start' | 'stop', string> = {
  // Emerald tokens match BulkActions "Start All" — one color vocabulary
  // across per-tile + bulk controls. The per-tile button is deliberately
  // block-width and text-xs so it reads as the primary action of the
  // tile, distinct from the smaller pill row above.
  start: 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok)] hover:bg-[var(--ok-10)]',
  stop: 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)] hover:bg-[var(--bad-10)]',
}

/** The prominent per-tile Start/Stop button. Reference UIs (Vercel
    service card, Railway deployment card, Uptime Kuma monitor row):
    the tile's primary action should live as a full-width button near
    the tile footer, not buried inside a process/readiness pill. The
    readiness rail pills above still toggle process state for
    keyboard-forward operators, but a new operator scanning the page
    reads "Start" as the obvious next step. */
function TilePrimaryAction({ id, sidecarUp }: { id: KnownConnectorId; sidecarUp: boolean }) {
  const inflight = getRailInflight(id).process === true
  const view = tilePrimaryActionView(sidecarUp, inflight)
  const tone = TILE_ACTION_TONE_CLASS[view.tone]
  return html`
    <button type="button"
      class=${`w-full cursor-pointer rounded border px-2 py-1.5 text-xs font-semibold tracking-wide transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${tone}`}
      disabled=${view.busy}
      aria-busy=${view.busy ? 'true' : 'false'}
      aria-label=${sidecarUp ? `${id} sidecar 정지` : `${id} sidecar 시작`}
      onClick=${() => {
        void withRailInflight(id, 'process', () =>
          sidecarUp ? stopSidecar(id) : startSidecar(id),
        )
      }}
      data-tile-primary-action=${id}
      data-tile-primary-action-tone=${view.tone}
    >${view.label}</button>
  `
}

/** Pure: derive a single notice view from the connector runtime state.
    Returns null when nothing notable is happening. Priority:
    error (non-empty) > stale (stale=true). Error beats stale because
    an explicit error message is strictly more diagnostic than a
    \"data is old\" flag; callers that want both must render both. */
interface TileNoticeView {
  tone: 'error' | 'stale'
  label: string
  detail: string
}
export function deriveTileNotice(
  connector: GateConnectorInfo | null,
): TileNoticeView | null {
  if (connector === null) return null
  const err = connector.error?.trim() ?? ''
  if (err !== '') {
    return {
      tone: 'error',
      label: 'Error',
      detail: err,
    }
  }
  if (connector.stale === true) {
    const secs = connector.stale_after_sec
    const ageHint = secs > 0 ? ` (${secs}s threshold)` : ''
    return {
      tone: 'stale',
      label: 'Stale',
      detail: `데이터 오래됨${ageHint}`,
    }
  }
  return null
}

const TILE_NOTICE_TONE_CLASS: Record<'error' | 'stale', string> = {
  // Rose for hard errors (sidecar reported an explicit failure),
  // amber for stale (data hasn't refreshed but no explicit error).
  // Matches Sentry \"issue\" rose + Vercel \"warning\" amber convention.
  error: 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]',
  stale: 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]',
}

const TILE_NOTICE_GLYPH: Record<'error' | 'stale', string> = {
  error: '⚠',
  stale: '⧗',
}

/** Surfaces connector.error / connector.stale on the tile so operators
    scanning the page see them without drilling into the detailed
    panel. Currently these fields are only visible in the per-connector
    live-panel below — easy to miss until you click into it. */
function TileErrorNotice({ connector }: { connector: GateConnectorInfo | null }) {
  const notice = deriveTileNotice(connector)
  if (notice === null) return null
  const tone = TILE_NOTICE_TONE_CLASS[notice.tone]
  const glyph = TILE_NOTICE_GLYPH[notice.tone]
  return html`
    <div
      class=${`flex min-w-0 items-center gap-1.5 rounded border px-2 py-1 text-3xs ${tone}`}
      role="alert"
      aria-label=${`${notice.label}: ${notice.detail}`}
      title=${notice.detail}
      data-tile-notice=${notice.tone}
    >
      <span aria-hidden="true" class="shrink-0">${glyph}</span>
      <span class="shrink-0 font-semibold uppercase tracking-2">${notice.label}</span>
      <span class="min-w-0 truncate font-normal normal-case tracking-normal opacity-80" title=${notice.detail}>${notice.detail}</span>
    </div>
  `
}

/** Uptime Kuma style pulse row under each overview tile. Samples the
    connector's up/down state every HEARTBEAT_SAMPLE_MS into a per-id
    ring buffer; the strip reads from that buffer and refreshes via the
    signal subscription. */
function TileHeartbeatStrip({ id }: { id: KnownConnectorId }) {
  const history = useHeartbeatHistory(id)
  // Rolling 5-sample windows → uptime %. Complementary to HeartbeatStrip:
  // strip = per-sample state (dense), sparkline = window-averaged trend
  // (smooth). Stripe/Vercel convention of pairing a stat with its
  // micro-graph so operator sees direction of change at a glance.
  const uptimeSeries = rollingUptimeSeries(history, 5)
  const trendColor = deriveTrendColor(uptimeSeries)
  return html`
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-1">
        <${HeartbeatStreakChip}
          history=${history}
          testId=${`heartbeat-streak-${id}`}
        />
        <${HeartbeatUptimeChip}
          history=${history}
          testId=${`heartbeat-uptime-${id}`}
        />
        ${uptimeSeries.length >= 2
          ? html`<${Sparkline}
              values=${uptimeSeries}
              width=${52}
              height=${12}
              color=${trendColor}
              class="ml-auto"
              ariaHidden=${true}
              testId=${`heartbeat-trend-${id}`}
            />`
          : null}
      </div>
      <${HeartbeatStrip}
        history=${history}
        slots=${45}
        class="-ml-px"
        testId=${`heartbeat-strip-${id}`}
      />
    </div>
  `
}

/** Pure: pick a sparkline color from the final uptime % — ties the
    trend line's hue to its current reliability band so the row reads
    coherent (same emerald/amber/rose vocabulary as the uptime chip).
    Uses Tailwind's 400-weight hex literals for parity with the
    chip border/bg tones. Returns muted token for empty/sparse
    series so a new connector doesn't leak a stale hue. */
function deriveTrendColor(series: readonly number[]): string {
  if (series.length === 0) return '#ffffff22'
  const last = series[series.length - 1]!
  // Tailwind emerald-400 / amber-400 / rose-400 hex codes — matches
  // the border-*-400 tones used on HeartbeatUptimeChip.
  if (last >= 99) return '#34d399'
  if (last >= 95) return 'var(--warn)'
  return 'var(--rose-light)'
}

/** Standalone export of the bulk Start All / Stop All buttons so the
    cold-start onboarding view can mount the same controls without
    having to render the full overview strip. */
export function ConnectorBulkActions({ connectors }: { connectors: GateConnectorInfo[] }) {
  return BulkActions({ connectors })
}

function BulkActions({ connectors }: { connectors: GateConnectorInfo[] }) {
  const downCount = KNOWN_CONNECTOR_IDS.filter(id => findConnector(connectors, id)?.available !== true).length
  const upCount = KNOWN_CONNECTOR_IDS.length - downCount
  const startBusy = bulkInflight.value.start
  const stopBusy = bulkInflight.value.stop
  return html`
    <div class="flex items-center gap-2 text-2xs text-[var(--text-dim)]">
      <button type="button"
        class="cursor-pointer rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-2 py-1 text-2xs text-[var(--ok)] hover:bg-[var(--ok-10)] disabled:cursor-not-allowed disabled:opacity-40"
        disabled=${startBusy || downCount === 0}
        title=${downCount === 0 ? '모두 이미 실행 중' : `${downCount} 개 sidecar 시작`}
        aria-label=${startBusy ? '모든 sidecar 시작 중' : downCount === 0 ? '모두 이미 실행 중' : `${downCount} 개 sidecar 시작`}
        aria-busy=${startBusy ? 'true' : 'false'}
        onClick=${() => { void runBulk('start', c => c?.available !== true, connectors) }}
        data-bulk-action="start"
      >
        ${startBusy ? '시작 중...' : `▶ Start All (${downCount})`}
      </button>
      <button type="button"
        class="cursor-pointer rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-1 text-2xs text-[var(--bad-light)] hover:bg-[var(--bad-10)] disabled:cursor-not-allowed disabled:opacity-40"
        disabled=${stopBusy || upCount === 0}
        title=${upCount === 0 ? '실행 중인 sidecar 없음' : `${upCount} 개 sidecar 정지`}
        aria-label=${stopBusy ? '모든 sidecar 정지 중' : upCount === 0 ? '실행 중인 sidecar 없음' : `${upCount} 개 sidecar 정지`}
        aria-busy=${stopBusy ? 'true' : 'false'}
        onClick=${() => { void runBulk('stop', c => c?.available === true, connectors) }}
        data-bulk-action="stop"
      >
        ${stopBusy ? '정지 중...' : `■ Stop All (${upCount})`}
      </button>
    </div>
  `
}

export function countConnectedSidecars(connectors: GateConnectorInfo[]): number {
  return KNOWN_CONNECTOR_IDS.filter(id => findConnector(connectors, id)?.available === true).length
}

interface ConnectorStripSummary {
  runningCount: number
  healthyCount: number
  connectorTotal: number
  bindingCount: number
}

/** Pure: roll up the at-a-glance stats that feed the strip header line.
    Counts only KNOWN sidecars (matches the tile grid) so "3 of 4" always
    lines up with what the operator sees below. Bindings are summed across
    every connector — Grafana's "stat panel" convention: total across rows,
    not per-row.

    Reference — PatternFly "Description List" + Grafana "stat panel":
    a single quiet line of context that stays on the page while louder
    banners (celebration / incident) come and go. */
export function summarizeConnectorStrip(
  connectors: GateConnectorInfo[],
  _keeperCount: number,
): ConnectorStripSummary {
  const runningCount = countConnectedSidecars(connectors)
  const healthyCount = KNOWN_CONNECTOR_IDS.filter(id => {
    const connector = findConnector(connectors, id)
    return connector !== null
      && connector.available === true
      && connector.gate_healthy !== false
      && connectorStateLabel(connector) === 'connected'
  }).length
  const bindingCount = KNOWN_CONNECTOR_IDS.reduce((acc, id) => {
    const c = findConnector(connectors, id)
    return acc + (c?.configured_bindings?.length ?? 0)
  }, 0)
  return {
    runningCount,
    healthyCount,
    connectorTotal: KNOWN_CONNECTOR_IDS.length,
    bindingCount,
  }
}

/** Pure: list the display names of KNOWN connectors that are currently
    offline, in the canonical tile order. Returns [] when everything is
    up, or when a connector isn't advertised yet (we only mark
    offline once we've observed the connector being non-available —
    \"missing from the connectors array\" is ambiguous, could be
    bootstrapping rather than offline).

    Why this exists: StatusSummaryLine says \"3 of 4 sidecars running\"
    but doesn't name the missing 1 — the operator has to scan four
    tiles below to find it. This lets the summary line annotate which
    specific connector(s) are offline, matching Statuspage's
    \"2 components degraded: Payments, API\" convention. */
export function offlineConnectorNames(
  connectors: GateConnectorInfo[],
): string[] {
  const out: string[] = []
  for (const id of KNOWN_CONNECTOR_IDS) {
    const c = findConnector(connectors, id)
    if (c === null) continue // not yet observed — don't assert \"offline\"
    if (c.available === true) continue
    out.push(CONNECTOR_DISPLAY_NAMES[id] ?? id)
  }
  return out
}

/** Pure: compact label for the offline-connector annotation. Returns
    null when nothing to annotate. */
export function formatOfflineConnectorLabel(
  offlineNames: readonly string[],
): string | null {
  if (offlineNames.length === 0) return null
  if (offlineNames.length <= 2) return `${offlineNames.join(' · ')} offline`
  return `${offlineNames.slice(0, 2).join(' · ')} · +${offlineNames.length - 2} offline`
}

function StatusSummaryLine({ summary, connectors }: { summary: ConnectorStripSummary; connectors: GateConnectorInfo[] }) {
  // One quiet aggregate sentence — always on, never loud. Sits between
  // the loud banners (celebration / incident) and the action row, so the
  // operator always has baseline numbers even when neither banner fires.
  const now = livePulseNowMs.value
  const lastTick = lastHeartbeatTickMs.value
  const offlineLabel = formatOfflineConnectorLabel(offlineConnectorNames(connectors))
  return html`
    <div
      class="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-2xs text-[var(--text-dim)]"
      data-strip-summary
    >
      <${LivePulseDot}
        lastTickMs=${lastTick}
        nowMs=${now}
        sampleIntervalMs=${HEARTBEAT_SAMPLE_MS}
        testId="overview-strip-live"
      />
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-running>${summary.runningCount}/${summary.connectorTotal}</span>
        <span> running</span>
        ${offlineLabel !== null
          ? html`<span
              class="ml-1 text-[var(--bad-light)]/80"
              data-strip-summary-offline-names
              title="현재 offline인 커넥터 이름"
            > · ${offlineLabel}</span>`
          : null}
      </span>
      <span aria-hidden="true" class="text-[var(--white-10)]">·</span>
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-healthy>${summary.healthyCount}/${summary.connectorTotal}</span>
        <span> healthy</span>
      </span>
      <span aria-hidden="true" class="text-[var(--white-10)]">·</span>
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-bindings>${summary.bindingCount}</span>
        <span> ${summary.bindingCount === 1 ? 'binding' : 'bindings'}</span>
      </span>
    </div>
  `
}

function IncidentBanner({ droppedIds }: { droppedIds: string[] }) {
  if (droppedIds.length === 0) return null
  const names = droppedIds
    .map(id => CONNECTOR_DISPLAY_NAMES[id as KnownConnectorId] ?? id)
    .join(', ')
  return html`
    <div
      class="mb-2 flex items-center gap-2 rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-1.5 text-2xs font-semibold text-[var(--bad-light)]"
      data-incident-banner
      role="alert"
    >
      <span aria-hidden="true">⚠</span>
      <span>최근 5분 내 연결 끊김 — ${names}</span>
      <span class="ml-auto text-3xs font-normal text-[var(--bad-light)]/80">아래 Start 버튼으로 복구</span>
    </div>
  `
}

export function ConnectorOverviewStrip({
  connectors,
  keeperCount,
  selectedConnectorId = null,
  onSelectConnector,
  detailTargetId = 'connector-detail-panel',
}: OverviewProps) {
  useEffect(() => {
    stripMemory.value = updateStripMemory(stripMemory.value, connectors, Date.now())
  }, [connectors])

  // Heartbeat sampler — push the current up/down state for each known
  // connector into the per-id ring buffer on a fixed cadence. This is
  // what feeds the Uptime Kuma style pulse strip below each tile; the
  // 30s interval × 45 bars gives ~22 minutes of rolling history.
  useEffect(() => {
    const sample = () => {
      for (const id of KNOWN_CONNECTOR_IDS) {
        const c = findConnector(connectors, id)
        recordHeartbeat(id, deriveHeartbeatState(c))
      }
    }
    sample() // immediate first sample so new tiles show a bar straight away
    const t = window.setInterval(sample, HEARTBEAT_SAMPLE_MS)
    return () => window.clearInterval(t)
  }, [connectors])

  const droppedIds = detectRecentDrops(stripMemory.value, connectors, Date.now())
  const summary = summarizeConnectorStrip(connectors, keeperCount)
  return html`
    <div
      role="region"
      aria-label="커넥터 상태 요약"
      class="mb-4 rounded border border-[var(--card-border)] bg-[var(--bg-1)] p-3"
      data-overview-strip-root
    >
      <${IncidentBanner} droppedIds=${droppedIds} />
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <${StatusSummaryLine} summary=${summary} connectors=${connectors} />
        <${BulkActions} connectors=${connectors} />
      </div>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        ${KNOWN_CONNECTOR_IDS.map(id => html`
          <${OverviewTile}
            id=${id}
            connector=${findConnector(connectors, id)}
            keeperCount=${keeperCount}
            selected=${selectedConnectorId === id}
            onSelectConnector=${onSelectConnector}
            detailTargetId=${detailTargetId}
          />
        `)}
      </div>
    </div>
  `
}

export function _testResetBulkInflight() {
  bulkInflight.value = { start: false, stop: false }
}

export function _testResetStripMemory() {
  stripMemory.value = { lastSeenUp: {} }
}

export function _testSetStripMemory(memory: StripMemory) {
  stripMemory.value = memory
}
