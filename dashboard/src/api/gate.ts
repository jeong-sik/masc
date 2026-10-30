import { get } from './core'
import {
  parseGateStatusData,
  type BindingInfo,
  type ChannelInfo,
  type GateEventInfo,
  type GateStatusData,
} from './schemas/gate-status'
import {
  parseGateConnectorsData,
  type ConnectorBindingSummary,
  type ConnectorRuntimeSummary,
  type ConnectorStoragePaths,
  type DiscordAuditEntry,
  type DiscordConfiguredBinding,
  type GateConnectorInfo,
  type GateConnectorsData,
} from './schemas/gate-connectors'

export type { BindingInfo, ChannelInfo, GateEventInfo, GateStatusData }
export { GateStatusSchemaDriftError } from './schemas/gate-status'
export type {
  ConnectorBindingSummary,
  ConnectorRuntimeSummary,
  ConnectorStoragePaths,
  DiscordAuditEntry,
  DiscordConfiguredBinding,
  GateConnectorInfo,
  GateConnectorsData,
}
export { GateConnectorsSchemaDriftError } from './schemas/gate-connectors'

export async function fetchGateStatus(signal?: AbortSignal): Promise<GateStatusData> {
  const raw = await get<unknown>('/api/v1/gate/status', { signal })
  return parseGateStatusData(raw)
}

export async function fetchGateConnectors(signal?: AbortSignal): Promise<GateConnectorsData> {
  const raw = await get<unknown>('/api/v1/gate/connectors', { signal })
  return parseGateConnectorsData(raw)
}
