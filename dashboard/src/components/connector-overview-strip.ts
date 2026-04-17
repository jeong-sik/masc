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
import { CONNECTOR_DISPLAY_NAMES, KNOWN_CONNECTOR_IDS, channelIcon, connectorAccentStyle, startSidecar, stopSidecar, type KnownConnectorId } from './connector-status'
import { openConnectorConfig } from './connector-config-form'
import { formatElapsedCompact } from '../lib/format-time'
import { HeartbeatStrip } from './common/heartbeat-strip'
import { recordHeartbeat, useHeartbeatHistory, type HeartbeatState } from '../lib/heartbeat-history'

/** Sampling cadence for the heartbeat ring buffer. Chosen so 45 bars
    cover ~22 minutes of history — matches Uptime Kuma's default
    "last 45 checks at 30s interval" visual rhythm. */
const HEARTBEAT_SAMPLE_MS = 30_000

/** Pure: derive the heartbeat state for a connector from the gate info
    that the overview strip already polls. No extra network calls. */
export function deriveHeartbeatState(
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
}

function findConnector(connectors: GateConnectorInfo[], id: string): GateConnectorInfo | null {
  return connectors.find(c => c.connector_id === id) ?? null
}

function scrollToCard(id: string) {
  const el = document.getElementById(`connector-card-${id}`)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function OverviewTile({ id, connector, keeperCount }: {
  id: KnownConnectorId
  connector: GateConnectorInfo | null
  keeperCount: number
}) {
  const sidecarUp = connector?.available === true
  const uptimeLabel = sidecarUp ? formatConnectorUptime(connector?.last_ready_at, Date.now()) : null
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
      expandHeader: () => scrollToCard(id),
      scrollToBindings: () => scrollToCard(id),
    },
    getRailInflight(id),
  )
  const accent = connectorAccentStyle(id)
  const displayName = CONNECTOR_DISPLAY_NAMES[id] ?? id

  return html`
    <div
      class="flex min-w-0 flex-col gap-2 rounded-lg border border-[var(--white-8)] bg-[var(--bg-1)] p-3 transition-colors hover:border-[var(--white-10)]"
      data-overview-tile=${id}
    >
      <button
        type="button"
        class="flex min-w-0 cursor-pointer items-center gap-2 text-left"
        onClick=${() => scrollToCard(id)}
        aria-label=${`${displayName} 카드로 이동`}
      >
        <span
          class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-[14px]"
          style=${accent}
        >${channelIcon(id)}</span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[13px] font-semibold text-[var(--text-body)]">${displayName}</span>
          <span class="flex items-center gap-1.5 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">
            <span>${sidecarUp ? '🟢 connected' : '⊘ offline'}</span>
            ${uptimeLabel !== null
              ? html`
                  <span
                    class="rounded-full border border-emerald-400/20 bg-emerald-500/5 px-1.5 py-[1px] text-[9px] font-normal normal-case tracking-normal text-emerald-200/80"
                    data-uptime-chip
                    title="last_ready_at 기준 경과 시간"
                  >${uptimeLabel}</span>
                `
              : null}
          </span>
        </span>
      </button>
      <${ConnectorReadinessRail} pills=${pills} />
      <${TileHeartbeatStrip} id=${id} />
    </div>
  `
}

/** Uptime Kuma style pulse row under each overview tile. Samples the
    connector's up/down state every HEARTBEAT_SAMPLE_MS into a per-id
    ring buffer; the strip reads from that buffer and refreshes via the
    signal subscription. */
function TileHeartbeatStrip({ id }: { id: KnownConnectorId }) {
  const history = useHeartbeatHistory(id)
  return html`<${HeartbeatStrip}
    history=${history}
    slots=${45}
    class="-ml-[1px]"
    testId=${`heartbeat-strip-${id}`}
  />`
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
    <div class="mb-2 flex items-center justify-end gap-2 text-[11px] text-[var(--text-dim)]">
      <span>일괄:</span>
      <button
        type="button"
        class="cursor-pointer rounded border border-emerald-400/30 bg-emerald-500/10 px-2 py-1 text-[11px] text-emerald-100 hover:bg-emerald-500/20 disabled:cursor-not-allowed disabled:opacity-40"
        disabled=${startBusy || downCount === 0}
        title=${downCount === 0 ? '모두 이미 실행 중' : `${downCount} 개 sidecar 시작`}
        onClick=${() => { void runBulk('start', c => c?.available !== true, connectors) }}
        data-bulk-action="start"
      >
        ${startBusy ? '시작 중...' : `▶ Start All (${downCount})`}
      </button>
      <button
        type="button"
        class="cursor-pointer rounded border border-rose-400/30 bg-rose-500/10 px-2 py-1 text-[11px] text-rose-100 hover:bg-rose-500/20 disabled:cursor-not-allowed disabled:opacity-40"
        disabled=${stopBusy || upCount === 0}
        title=${upCount === 0 ? '실행 중인 sidecar 없음' : `${upCount} 개 sidecar 정지`}
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

export interface ConnectorStripSummary {
  sidecarUp: number
  sidecarTotal: number
  bindingCount: number
  keeperCount: number
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
  keeperCount: number,
): ConnectorStripSummary {
  const sidecarUp = countConnectedSidecars(connectors)
  const bindingCount = KNOWN_CONNECTOR_IDS.reduce((acc, id) => {
    const c = findConnector(connectors, id)
    return acc + (c?.configured_bindings?.length ?? 0)
  }, 0)
  return {
    sidecarUp,
    sidecarTotal: KNOWN_CONNECTOR_IDS.length,
    bindingCount,
    keeperCount,
  }
}

function StatusSummaryLine({ summary }: { summary: ConnectorStripSummary }) {
  // One quiet aggregate sentence — always on, never loud. Sits between
  // the loud banners (celebration / incident) and the action row, so the
  // operator always has baseline numbers even when neither banner fires.
  return html`
    <div
      class="mb-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-[11px] text-[var(--text-dim)]"
      data-strip-summary
    >
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-sidecars>${summary.sidecarUp} of ${summary.sidecarTotal}</span>
        <span> sidecars running</span>
      </span>
      <span aria-hidden="true" class="text-[var(--white-10)]">·</span>
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-bindings>${summary.bindingCount}</span>
        <span> ${summary.bindingCount === 1 ? 'binding' : 'bindings'} configured</span>
      </span>
      <span aria-hidden="true" class="text-[var(--white-10)]">·</span>
      <span>
        <span class="font-semibold text-[var(--text-body)]" data-strip-summary-keepers>${summary.keeperCount}</span>
        <span> ${summary.keeperCount === 1 ? 'keeper' : 'keepers'} online</span>
      </span>
    </div>
  `
}

function CelebrationBanner({ connectedCount }: { connectedCount: number }) {
  if (connectedCount < KNOWN_CONNECTOR_IDS.length) return null
  return html`
    <div
      class="mb-2 flex items-center justify-center gap-2 rounded-md border border-emerald-400/40 bg-emerald-500/10 px-3 py-1.5 text-[11px] font-semibold text-emerald-100"
      data-celebration="all-connected"
    >
      <span aria-hidden="true">✨</span>
      <span>${connectedCount}/${KNOWN_CONNECTOR_IDS.length} 커넥터 모두 정상 — 운영 준비 완료</span>
      <span aria-hidden="true">✨</span>
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
      class="mb-2 flex items-center gap-2 rounded-md border border-rose-400/40 bg-rose-500/10 px-3 py-1.5 text-[11px] font-semibold text-rose-100"
      data-incident-banner
      role="alert"
    >
      <span aria-hidden="true">⚠</span>
      <span>최근 5분 내 연결 끊김 — ${names}</span>
      <span class="ml-auto text-[10px] font-normal text-rose-200/80">아래 Start 버튼으로 복구</span>
    </div>
  `
}

export function ConnectorOverviewStrip({ connectors, keeperCount }: OverviewProps) {
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
  const connectedCount = countConnectedSidecars(connectors)
  const summary = summarizeConnectorStrip(connectors, keeperCount)
  return html`
    <div
      class="sticky top-0 z-10 mb-4 -mx-4 border-b border-[var(--card-border)] bg-[var(--bg-0)]/95 px-4 pt-2 pb-3 backdrop-blur supports-[backdrop-filter]:bg-[var(--bg-0)]/80"
      data-overview-strip-root
    >
      <${IncidentBanner} droppedIds=${droppedIds} />
      <${CelebrationBanner} connectedCount=${connectedCount} />
      <${StatusSummaryLine} summary=${summary} />
      <${BulkActions} connectors=${connectors} />
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        ${KNOWN_CONNECTOR_IDS.map(id => html`
          <${OverviewTile}
            id=${id}
            connector=${findConnector(connectors, id)}
            keeperCount=${keeperCount}
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
