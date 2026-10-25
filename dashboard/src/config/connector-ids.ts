// Connector identity shared by routes and gateway setup.
export const KNOWN_CONNECTOR_IDS = ['discord', 'imessage', 'slack', 'telegram'] as const
export type KnownConnectorId = (typeof KNOWN_CONNECTOR_IDS)[number]

const KNOWN_CONNECTOR_ID_SET = new Set<string>(KNOWN_CONNECTOR_IDS)

export function isKnownConnectorId(value: string | undefined): value is KnownConnectorId {
  return value !== undefined && KNOWN_CONNECTOR_ID_SET.has(value)
}
