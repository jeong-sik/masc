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
import { signal } from '@preact/signals'
import type { GateConnectorInfo } from '../api/gate'
import { ConnectorReadinessRail, deriveRail, getRailInflight, withRailInflight } from './connector-readiness-rail'
import { CONNECTOR_DISPLAY_NAMES, KNOWN_CONNECTOR_IDS, channelIcon, connectorAccentStyle, startSidecar, stopSidecar, type KnownConnectorId } from './connector-status'
import { openConnectorConfig } from './connector-config-form'

const bulkInflight = signal<{ start: boolean; stop: boolean }>({ start: false, stop: false })

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
          <span class="block text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">${sidecarUp ? '🟢 connected' : '⊘ offline'}</span>
        </span>
      </button>
      <${ConnectorReadinessRail} pills=${pills} />
    </div>
  `
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

export function ConnectorOverviewStrip({ connectors, keeperCount }: OverviewProps) {
  return html`
    <div class="mb-4">
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
