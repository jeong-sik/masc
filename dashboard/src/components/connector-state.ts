// Connector state label + its pure visual mappings.
//
// Extracted from connector-status.ts (which re-exports the external members for
// back-compat, matching the ./connector-constants precedent). These are pure
// functions of a GateConnectorInfo / ConnectorStateLabel — no component state,
// no signals — so they live apart from the 2000+ line route surface and can be
// unit-tested (connector-card-border.test.ts) in isolation.

import type { GateConnectorInfo } from '../api/gate'

const CONNECTOR_STATE_LABELS = ['offline', 'stale', 'connected', 'disconnected'] as const
export type ConnectorStateLabel = (typeof CONNECTOR_STATE_LABELS)[number]

function isConnectorStateLabel(value: string | undefined): value is ConnectorStateLabel {
  return value === 'offline' || value === 'stale' || value === 'connected' || value === 'disconnected'
}

function assertNever(value: never): never {
  throw new Error(`Unhandled connector state label: ${String(value)}`)
}

export function connectorStateLabel(connector: GateConnectorInfo | null): ConnectorStateLabel {
  const advertised = connector?.status?.trim().toLowerCase()
  if (isConnectorStateLabel(advertised)) {
    return advertised
  }
  if (!connector?.available) return 'offline'
  if (connector.stale) return 'stale'
  if (connector.connected) return 'connected'
  return 'disconnected'
}

/** Pure: Portainer-style left border tone for a connector card.
    A 4px colored left border lets operators scan a vertical stack of
    cards and spot problem connectors by color alone — no reading the
    status pill required. Mapping matches Portainer's container state
    palette: emerald for connected, amber for stale (intermittent),
    rose for disconnected (broken), muted for offline (not running). */
export function connectorCardBorderClass(label: ConnectorStateLabel): string {
  switch (label) {
    case 'connected':
      return 'border-l-4 border-l-emerald-500'
    case 'stale':
      return 'border-l-4 border-l-[var(--color-warn)]'
    case 'disconnected':
      return 'border-l-4 border-l-rose-500'
    case 'offline':
      return 'border-l-4 border-l-[var(--color-border-default)]'
    default:
      return assertNever(label)
  }
}

export function connectorStateTone(connector: GateConnectorInfo | null): string {
  const label = connectorStateLabel(connector)
  if (label === 'connected') {
    return 'border-[var(--ok-border)] bg-[var(--ok-10)] text-[var(--color-status-ok)]'
  }
  if (label === 'disconnected') {
    return 'border-[var(--err-border)] bg-[var(--bad-10)] text-[var(--bad-light)]'
  }
  return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
}

export function dotClassForLabel(label: ConnectorStateLabel): string {
  switch (label) {
    case 'connected':
      return 'bg-[var(--ok-10)]'
    case 'stale':
      return 'bg-[var(--warn-10)]'
    case 'disconnected':
      return 'bg-[var(--bad-10)]'
    case 'offline':
      return 'bg-[var(--color-fg-disabled)]'
    default:
      return assertNever(label)
  }
}

export function connectorCardStateClass(label: ConnectorStateLabel): string {
  switch (label) {
    case 'connected':
      return ''
    case 'stale':
      return 'stale'
    case 'offline':
    case 'disconnected':
      return 'down'
    default:
      return assertNever(label)
  }
}

export function connectorStatusPillClass(label: ConnectorStateLabel): string {
  switch (label) {
    case 'connected':
      return 'run'
    case 'stale':
      return 'pause'
    case 'offline':
    case 'disconnected':
      return 'off'
    default:
      return assertNever(label)
  }
}

export function connectorStatusPillLabel(label: ConnectorStateLabel): string {
  switch (label) {
    case 'connected':
      return 'Connected'
    case 'stale':
      return 'Stale'
    case 'offline':
    case 'disconnected':
      return 'Down'
    default:
      return assertNever(label)
  }
}
