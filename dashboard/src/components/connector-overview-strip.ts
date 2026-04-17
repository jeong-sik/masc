// ConnectorOverviewStrip — top-level operator console for the all-bridges view.
//
// Layer 1: Summary Bar (one row)
//   total / up / warn / down + bulk Start All / Stop All.
//
// Layer 2: Dense Connector Table (one row per connector)
//   Fixed-width columns give natural alignment that a flex-grid of pills
//   cannot. Row states collapse the four readiness axes (token, process,
//   gate, bindings) into compact cells so N×M scales horizontally without
//   re-wrapping mid-label.
//
// Rendered only on the all-connectors view. A single-connector filter
// continues to render the full ConnectorLivePanel directly.
//
// Expanded detail for a row is supplied by the caller via
// `renderExpandedDetail`, avoiding a circular import with connector-status.ts.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ComponentChildren } from 'preact'
import type { GateConnectorInfo } from '../api/gate'
import type { GateKeeperInfo } from '../api/schemas/gate-keepers'
import {
  deriveRail,
  getRailInflight,
  withRailInflight,
  type RailPill,
  type RailState,
} from './connector-readiness-rail'
import {
  CONNECTOR_DISPLAY_NAMES,
  KNOWN_CONNECTOR_IDS,
  channelIcon,
  startSidecar,
  stopSidecar,
  type KnownConnectorId,
} from './connector-status'
import { openConnectorConfig } from './connector-config-form'
import { CopyableCode } from './common/copyable-code'

const bulkInflight = signal<{ start: boolean; stop: boolean }>({ start: false, stop: false })
const expandedRow = signal<KnownConnectorId | null>(null)
const pathsExpanded = signal<boolean>(false)

export function _testResetBulkInflight() {
  bulkInflight.value = { start: false, stop: false }
  expandedRow.value = null
  pathsExpanded.value = false
}

export interface MascPaths {
  connectorsDir: string | null
  logsDir: string | null
  keepersDir: string
  sidecarsDir: string
}

/** Derive MASC-managed paths from the first connector that has a names_path.
    Returns `null` fields when no runtime has been observed yet. Keeper and
    sidecar paths are repo-relative conventions and never null. Pure helper. */
export function deriveMascPaths(connectors: GateConnectorInfo[]): MascPaths {
  const fallback: MascPaths = {
    connectorsDir: null,
    logsDir: null,
    keepersDir: 'config/keepers/',
    sidecarsDir: 'sidecars/',
  }
  const withPath = connectors.find(c => typeof c.names_path === 'string' && c.names_path.length > 0)
  if (!withPath) return fallback
  const match = withPath.names_path.match(/^(.*)\/connectors\/[^/]+\/names\.json$/)
  if (!match) return fallback
  const mascRoot = match[1] ?? ''
  return {
    connectorsDir: `${mascRoot}/connectors/`,
    logsDir: `${mascRoot}/logs/`,
    keepersDir: 'config/keepers/',
    sidecarsDir: 'sidecars/',
  }
}

function PathRow({ label, value, hint }: { label: string; value: string; hint: string }) {
  return html`
    <div class="flex items-center gap-2" data-paths-row=${label}>
      <span class="w-[100px] shrink-0 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]" title=${hint}>${label}</span>
      <div class="min-w-0 flex-1">
        <${CopyableCode} command=${value} ariaLabel=${`Copy ${label} path`} />
      </div>
    </div>
  `
}

function PathsStrip({ connectors }: { connectors: GateConnectorInfo[] }) {
  const paths = deriveMascPaths(connectors)
  const open = pathsExpanded.value
  return html`
    <div class="mb-3 rounded-lg border border-[var(--card-border)] bg-[var(--bg-1)]" data-panel="connector-paths-strip">
      <button
        type="button"
        class="flex w-full cursor-pointer items-center justify-between gap-3 px-3 py-2 text-left text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
        onClick=${() => { pathsExpanded.value = !open }}
        aria-expanded=${open}
        aria-controls="connector-paths-body"
      >
        <span>
          <span class="mr-2 text-[10px] uppercase tracking-[0.14em]">Paths</span>
          <span class="font-mono">${paths.connectorsDir ?? paths.sidecarsDir}</span>
          <span class="ml-2 text-[var(--text-dim)]">${paths.connectorsDir ? '' : '(런타임 미관찰 · sidecar 경로만 표시)'}</span>
        </span>
        <span>${open ? '▴' : '▾'}</span>
      </button>
      ${open
        ? html`
            <div id="connector-paths-body" class="space-y-1.5 border-t border-[var(--card-border)] px-3 py-2">
              ${paths.connectorsDir
                ? html`<${PathRow} label="Connectors" value=${paths.connectorsDir} hint="sidecar names.json / status.json 위치" />`
                : null}
              ${paths.logsDir
                ? html`<${PathRow} label="Logs" value=${paths.logsDir} hint="sidecar 로그 디렉토리" />`
                : null}
              <${PathRow} label="Keepers" value=${paths.keepersDir} hint="keeper TOML 설정 파일" />
              <${PathRow} label="Sidecars" value=${paths.sidecarsDir} hint="sidecar 스크립트 (run.sh) 위치" />
            </div>
          `
        : null}
    </div>
  `
}

function findConnector(connectors: GateConnectorInfo[], id: string): GateConnectorInfo | null {
  return connectors.find(c => c.connector_id === id) ?? null
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
    await Promise.allSettled(
      targets.map(id =>
        withRailInflight(id, 'process', () => kind === 'start' ? startSidecar(id) : stopSidecar(id)),
      ),
    )
  } finally {
    bulkInflight.value = { ...bulkInflight.value, [kind]: false }
  }
}

/** Standalone export used by onboarding (cold-start) view. */
export function ConnectorBulkActions({ connectors }: { connectors: GateConnectorInfo[] }) {
  return BulkActions({ connectors })
}

function BulkActions({ connectors }: { connectors: GateConnectorInfo[] }) {
  const downCount = KNOWN_CONNECTOR_IDS.filter(id => findConnector(connectors, id)?.available !== true).length
  const upCount = KNOWN_CONNECTOR_IDS.length - downCount
  const startBusy = bulkInflight.value.start
  const stopBusy = bulkInflight.value.stop
  return html`
    <div class="flex items-center justify-end gap-2 text-[11px] text-[var(--text-dim)]">
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

interface SummaryCounts {
  up: number
  warn: number
  down: number
  total: number
}

function computeSummary(connectors: GateConnectorInfo[], keepers: GateKeeperInfo[]): SummaryCounts {
  let up = 0
  let warn = 0
  let down = 0
  const noop = () => {}
  for (const id of KNOWN_CONNECTOR_IDS) {
    const c = findConnector(connectors, id)
    if (!c || c.available !== true) { down++; continue }
    const pills = deriveRail({
      sidecarUp: true,
      gateHealthy: c.gate_healthy ?? null,
      bindingCount: c.configured_bindings?.length ?? 0,
      keeperCount: keepers.length,
    }, { openConfig: noop, toggleProcess: noop, expandHeader: noop, scrollToBindings: noop })
    if (pills.some(p => p.state === 'bad')) down++
    else if (pills.some(p => p.state === 'warn')) warn++
    else up++
  }
  return { up, warn, down, total: KNOWN_CONNECTOR_IDS.length }
}

function SummaryBar({ connectors, keepers }: { connectors: GateConnectorInfo[]; keepers: GateKeeperInfo[] }) {
  const s = computeSummary(connectors, keepers)
  return html`
    <div class="mb-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-[var(--card-border)] bg-[var(--bg-1)] px-3 py-2 text-[12px]" data-panel="connector-summary-bar">
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">커넥터</span>
        <span class="font-semibold text-[var(--text-body)]" data-summary-total>${s.total}</span>
        <span class="flex items-center gap-1 text-emerald-200" title="모든 축 정상" data-summary-up>
          <span class="inline-block h-1.5 w-1.5 rounded-full bg-emerald-400"></span>
          <span>${s.up} up</span>
        </span>
        <span class="flex items-center gap-1 text-amber-200" title="일부 축 주의" data-summary-warn>
          <span class="inline-block h-1.5 w-1.5 rounded-full bg-amber-400"></span>
          <span>${s.warn} warn</span>
        </span>
        <span class="flex items-center gap-1 text-rose-200" title="sidecar 오프라인 또는 실패" data-summary-down>
          <span class="inline-block h-1.5 w-1.5 rounded-full bg-rose-400"></span>
          <span>${s.down} down</span>
        </span>
      </div>
      <${BulkActions} connectors=${connectors} />
    </div>
  `
}

const CELL_TONE: Record<RailState, { text: string; dot: string; bg: string }> = {
  ok:   { text: 'text-emerald-200',       dot: 'bg-emerald-400',      bg: 'bg-emerald-500/8' },
  warn: { text: 'text-amber-200',         dot: 'bg-amber-400',        bg: 'bg-amber-500/8' },
  bad:  { text: 'text-rose-200',          dot: 'bg-rose-400',         bg: 'bg-rose-500/8' },
  idle: { text: 'text-[var(--text-dim)]', dot: 'bg-[var(--white-8)]', bg: 'bg-transparent' },
}

const CELL_GLYPH: Record<RailState, string> = { ok: '✓', warn: '!', bad: '⊘', idle: '·' }

function RailCell({ pill }: { pill: RailPill }) {
  const tone = CELL_TONE[pill.state]
  const inflight = pill.inflight === true
  return html`
    <button
      type="button"
      class=${`flex h-full w-full cursor-pointer items-center justify-center rounded text-[12px] transition-colors ${tone.bg} ${tone.text} hover:brightness-125 disabled:cursor-not-allowed disabled:opacity-40 ${inflight ? 'animate-pulse' : ''}`}
      onClick=${pill.onClick}
      disabled=${inflight}
      title=${`${pill.label}: ${pill.detail}${pill.hint ? ' — ' + pill.hint : ''}`}
      data-rail-pill=${pill.key}
      data-rail-state=${pill.state}
    >
      <span class=${`inline-flex h-4 w-4 items-center justify-center rounded-full text-[10px] font-bold ${inflight ? 'bg-[var(--white-10)]' : tone.dot} text-[var(--bg-0)]`}>
        ${inflight ? '…' : CELL_GLYPH[pill.state]}
      </span>
    </button>
  `
}

// Brand accent per connector for the 4px left bar (no card-wide gradient).
const LEFT_BAR_COLOR: Record<KnownConnectorId, string> = {
  discord:  'bg-[rgb(88,101,242)]',
  imessage: 'bg-[rgb(48,209,88)]',
  slack:    'bg-[rgb(236,178,46)]',
  telegram: 'bg-[rgb(34,158,217)]',
}

const ROW_GRID_COLS =
  'grid-template-columns: 4px 24px minmax(120px, 1.4fr) minmax(100px, 1fr) repeat(4, 40px) minmax(140px, 1.4fr) auto;'

interface RowProps {
  id: KnownConnectorId
  connector: GateConnectorInfo | null
  keepers: GateKeeperInfo[]
  renderExpandedDetail: (c: GateConnectorInfo | null) => ComponentChildren
}

function connectorKeeperNames(connector: GateConnectorInfo | null): string[] {
  if (!connector) return []
  const names = new Set<string>()
  for (const b of connector.configured_bindings ?? []) names.add(b.keeper_name)
  return [...names].sort()
}

function ConnectorRow({ id, connector, keepers, renderExpandedDetail }: RowProps) {
  const sidecarUp = connector?.available === true
  const toggleExpand = () => {
    expandedRow.value = expandedRow.value === id ? null : id
  }
  const pills = deriveRail(
    {
      sidecarUp,
      gateHealthy: connector?.gate_healthy ?? null,
      bindingCount: connector?.configured_bindings?.length ?? 0,
      keeperCount: keepers.length,
    },
    {
      openConfig: () => openConnectorConfig(id),
      toggleProcess: () => {
        void withRailInflight(id, 'process', () =>
          sidecarUp ? stopSidecar(id) : startSidecar(id),
        )
      },
      expandHeader: toggleExpand,
      scrollToBindings: toggleExpand,
    },
    getRailInflight(id),
  )
  const displayName = CONNECTOR_DISPLAY_NAMES[id] ?? id
  // Lowercase in DOM so textContent-based assertions (connected/offline) keep
  // matching; `uppercase` class provides the visual rendering.
  const stateText = sidecarUp ? 'connected' : 'offline'
  const stateTone = sidecarUp ? 'text-emerald-200' : 'text-[var(--text-dim)]'
  const stateGlyph = sidecarUp ? '🟢' : '⊘'
  const keeperNames = connectorKeeperNames(connector)
  const bindingCount = connector?.configured_bindings?.length ?? 0
  const isExpanded = expandedRow.value === id
  const summary = keeperNames.length === 0
    ? '—'
    : `${bindingCount} ch · ${keeperNames.slice(0, 2).join(', ')}${keeperNames.length > 2 ? ` +${keeperNames.length - 2}` : ''}`

  return html`
    <div id=${`connector-row-${id}`} class="overflow-hidden rounded-md border border-[var(--card-border)] bg-[var(--bg-1)]" data-connector-row=${id}>
      <div class="grid items-stretch" style=${ROW_GRID_COLS}>
        <div class=${`min-h-[40px] ${LEFT_BAR_COLOR[id]}`} aria-hidden="true"></div>
        <button
          type="button"
          class="flex items-center justify-center text-base leading-none hover:text-[var(--text-body)]"
          onClick=${toggleExpand}
          aria-label=${`${displayName} 상세 ${isExpanded ? '접기' : '펼치기'}`}
          aria-expanded=${isExpanded}
        >${channelIcon(id)}</button>
        <button
          type="button"
          class="flex items-center truncate py-2 text-left text-[13px] font-semibold text-[var(--text-body)] hover:text-emerald-100"
          onClick=${toggleExpand}
        >${displayName}</button>
        <span class=${`flex items-center gap-1.5 py-2 text-[11px] uppercase tracking-[0.12em] ${stateTone}`}>
          <span aria-hidden="true">${stateGlyph}</span>
          <span>${stateText}</span>
        </span>
        ${pills.map(pill => html`<${RailCell} pill=${pill} />`)}
        <span class="flex items-center truncate py-2 text-[11px] text-[var(--text-dim)]" title=${keeperNames.join(', ') || 'no keepers bound'}>
          ${summary}
        </span>
        <div class="flex items-center gap-1 px-2">
          <button
            type="button"
            class=${`cursor-pointer rounded border px-2 py-0.5 text-[10px] uppercase tracking-[0.12em] hover:brightness-125 ${sidecarUp
              ? 'border-rose-400/30 bg-rose-500/12 text-rose-100'
              : 'border-emerald-400/30 bg-emerald-500/12 text-emerald-100'}`}
            onClick=${() => { void withRailInflight(id, 'process', () => sidecarUp ? stopSidecar(id) : startSidecar(id)) }}
            title=${sidecarUp ? 'sidecar 정지' : 'sidecar 시작'}
            data-row-action=${sidecarUp ? 'stop' : 'start'}
          >${sidecarUp ? 'Stop' : 'Start'}</button>
          <button
            type="button"
            class="cursor-pointer rounded border border-[var(--card-border)] px-1.5 py-0.5 text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
            onClick=${() => openConnectorConfig(id)}
            title=${`${displayName} 설정 폼 열기`}
            aria-label=${`${displayName} config`}
            data-row-action="config"
          >⚙</button>
          <button
            type="button"
            class="cursor-pointer rounded border border-[var(--card-border)] px-1.5 py-0.5 text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
            onClick=${() => { expandedRow.value = id }}
            title=${`${displayName} 설치 가이드 (3 STEPS)`}
            aria-label=${`${displayName} guide`}
            data-row-action="guide"
          >?</button>
          <button
            type="button"
            class="cursor-pointer rounded border border-[var(--card-border)] px-1.5 py-0.5 text-[11px] text-[var(--text-dim)] hover:text-[var(--text-body)]"
            onClick=${toggleExpand}
            aria-label=${`${displayName} detail toggle`}
          >${isExpanded ? '▴' : '▾'}</button>
        </div>
      </div>
      ${isExpanded
        ? html`<div class="border-t border-[var(--card-border)] bg-[var(--white-3)] p-3" data-connector-row-detail=${id}>${renderExpandedDetail(connector)}</div>`
        : null}
    </div>
  `
}

interface OverviewProps {
  connectors: GateConnectorInfo[]
  keepers: GateKeeperInfo[]
  renderExpandedDetail: (connector: GateConnectorInfo | null) => ComponentChildren
}

export function ConnectorOverviewStrip({ connectors, keepers, renderExpandedDetail }: OverviewProps) {
  return html`
    <div class="mb-4" data-panel="connector-overview">
      <${SummaryBar} connectors=${connectors} keepers=${keepers} />
      <${PathsStrip} connectors=${connectors} />
      <div class="grid gap-1.5 px-1 pb-1 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]"
           style=${ROW_GRID_COLS}>
        <span></span>
        <span></span>
        <span>Name</span>
        <span>State</span>
        <span class="text-center" title="Token">TKN</span>
        <span class="text-center" title="Process">PRC</span>
        <span class="text-center" title="Gate">GTE</span>
        <span class="text-center" title="Bindings">BND</span>
        <span>Keepers</span>
        <span class="pr-2 text-right">Actions</span>
      </div>
      <div class="flex flex-col gap-1.5">
        ${KNOWN_CONNECTOR_IDS.map(id => html`
          <${ConnectorRow}
            id=${id}
            connector=${findConnector(connectors, id)}
            keepers=${keepers}
            renderExpandedDetail=${renderExpandedDetail}
          />
        `)}
      </div>
    </div>
  `
}
