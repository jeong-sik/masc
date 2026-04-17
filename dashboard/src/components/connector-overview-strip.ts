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
import type { GateConnectorInfo } from '../api/gate'
import { ConnectorReadinessRail, deriveRail } from './connector-readiness-rail'
import { CONNECTOR_DISPLAY_NAMES, KNOWN_CONNECTOR_IDS, channelIcon, connectorAccentStyle, startSidecar, stopSidecar, type KnownConnectorId } from './connector-status'
import { openConnectorConfig } from './connector-config-form'

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
        if (sidecarUp) void stopSidecar(id)
        else void startSidecar(id)
      },
      expandHeader: () => scrollToCard(id),
      scrollToBindings: () => scrollToCard(id),
    },
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

export function ConnectorOverviewStrip({ connectors, keeperCount }: OverviewProps) {
  return html`
    <div class="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      ${KNOWN_CONNECTOR_IDS.map(id => html`
        <${OverviewTile}
          id=${id}
          connector=${findConnector(connectors, id)}
          keeperCount=${keeperCount}
        />
      `)}
    </div>
  `
}
