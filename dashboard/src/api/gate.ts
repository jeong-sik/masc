import { get } from './core'
import {
  parseGateStatusData,
  type BindingInfo,
  type ChannelInfo,
  type GateEventInfo,
  type GateStatusData,
} from './schemas/gate-status'
import {
  parseGateKeepersData,
  type GateKeeperInfo,
  type GateKeepersData,
} from './schemas/gate-keepers'
import {
  parseGateConnectorsData,
  type ConnectorBindingSummary,
  type ConnectorNames,
  type ConnectorRuntimeSummary,
  type ConnectorStoragePaths,
  type DiscordAuditEntry,
  type DiscordConfiguredBinding,
  type GateConnectorInfo,
  type GateConnectorsData,
} from './schemas/gate-connectors'

export type { BindingInfo, ChannelInfo, GateEventInfo, GateStatusData }
export { GateStatusSchemaDriftError } from './schemas/gate-status'
export type { GateKeeperInfo, GateKeepersData }
export { GateKeepersSchemaDriftError } from './schemas/gate-keepers'
export type {
  ConnectorBindingSummary,
  ConnectorNames,
  ConnectorRuntimeSummary,
  ConnectorStoragePaths,
  DiscordAuditEntry,
  DiscordConfiguredBinding,
  GateConnectorInfo,
  GateConnectorsData,
}
export { GateConnectorsSchemaDriftError } from './schemas/gate-connectors'

// Thin null-returning wrappers preserving the pre-migration contract
// for `src/api/gate.test.ts` assertions. New call sites should use the
// throw-on-drift parsers directly.
export function decodeGateStatusData(raw: unknown): GateStatusData | null {
  try {
    return parseGateStatusData(raw)
  } catch {
    return null
  }
}

export function decodeGateKeepersData(raw: unknown): GateKeepersData | null {
  try {
    return parseGateKeepersData(raw)
  } catch {
    return null
  }
}

export function decodeGateConnectorsData(raw: unknown): GateConnectorsData | null {
  try {
    return parseGateConnectorsData(raw)
  } catch {
    return null
  }
}

export async function fetchGateStatus(signal?: AbortSignal): Promise<GateStatusData> {
  const raw = await get<unknown>('/api/v1/gate/status', { signal })
  return parseGateStatusData(raw)
}

export async function fetchGateConnectors(signal?: AbortSignal): Promise<GateConnectorsData> {
  const raw = await get<unknown>('/api/v1/gate/connectors', { signal })
  return parseGateConnectorsData(raw)
}

export async function fetchGateKeepers(signal?: AbortSignal): Promise<GateKeepersData> {
  const raw = await get<unknown>('/api/v1/gate/keepers?limit=50&detailed=true', { signal })
  return parseGateKeepersData(raw)
}
