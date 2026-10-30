import { KNOWN_CONNECTOR_IDS, type KnownConnectorId } from '../config/connector-ids'

export { KNOWN_CONNECTOR_IDS, type KnownConnectorId } from '../config/connector-ids'

// Every registered connector runs in the MASC server.
export const IN_PROCESS_CONNECTOR_IDS = KNOWN_CONNECTOR_IDS
export type InProcessConnectorId = (typeof IN_PROCESS_CONNECTOR_IDS)[number]

export function isInProcessConnector(connectorId: string): boolean {
  return (IN_PROCESS_CONNECTOR_IDS as readonly string[]).includes(connectorId)
}

// What an operator has to put in place for an in-process connector to start.
// For Slack this is the app-level token (Socket Mode credential): absent, the
// in-process gateway does not start. The bot token (SLACK_BOT_TOKEN) is a
// second, outbound-only credential surfaced by the config form / setup guide.
// iMessage has no credential at all — macOS authorizes the process itself —
// so what it needs is a permission grant, which is why this is not named
// after an env var.
export const IN_PROCESS_CONNECTOR_ACTIVATION: Record<InProcessConnectorId, string> = {
  discord: 'DISCORD_BOT_TOKEN 환경변수',
  imessage: 'Messages.app 전체 디스크 접근 권한',
  slack: 'SLACK_APP_TOKEN 환경변수',
  telegram: 'TELEGRAM_BOT_TOKEN 환경변수',
}

export const CONNECTOR_DISPLAY_NAMES: Record<KnownConnectorId, string> = {
  discord: 'Discord',
  imessage: 'iMessage',
  slack: 'Slack',
  telegram: 'Telegram',
}

// Brand accent RGB triplets per connector, biased toward dark-theme legibility.
const CONNECTOR_ACCENT_RGB: Record<string, string> = {
  discord: '88,101,242', // blurple
  imessage: '48,209,88', // iOS Messages bubble green
  slack: '236,178,46', // brand yellow (most distinctive vs telegram cyan)
  telegram: '34,158,217', // brand cyan
}

export function connectorAccentStyle(connectorId: string): string {
  const rgb = CONNECTOR_ACCENT_RGB[connectorId] ?? '120,130,150'
  return `background:linear-gradient(135deg,rgba(${rgb},0.16),rgba(${rgb},0.04))`
}

const CHANNEL_ICONS: Record<string, string> = {
  discord: '\u{1F3AE}',
  imessage: '\u{1F4F1}',
  telegram: '\u{2708}',
  slack: '\u{1F4AC}',
  signal: '\u{1F512}',
  webchat: '\u{1F310}',
  api: '\u{26A1}',
  internal: '\u{2699}',
}

export function channelIcon(ch: string): string {
  return CHANNEL_ICONS[ch] ?? '\u{1F517}'
}
