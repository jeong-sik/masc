// Connector vocabulary SSOT.
//
// Pure, side-effect-free constants and accessors for the connector surface,
// extracted from the 2458-LOC connector-status.ts so lightweight consumers
// (overview skeleton, onboarding) import them from one small module instead of
// pulling a reference to the whole ConnectorStatusPanel body. connector-status.ts
// re-exports every symbol here for back-compat.
//
// Scope note: only the pure connector *vocabulary* lives here. State-label
// classification (connectorStateLabel / connectorCardBorderClass) stays in
// connector-status.ts because it shares the file-local exhaustiveness helper,
// and the sidecar actions (start/stop/bind) stay there because they close over
// the panel's signal-backed UI state. The connector-status import cycle is
// therefore NOT addressed here (tracked separately — backlog Slice 8).

// Known connectors shown in the dashboard (status panels, accent colours,
// channel icons). Includes external sidecars and the in-process Discord gateway.
// Source of truth: the sidecars under /sidecars/, the in-process gateway under
// lib/server/server_discord_in_process_gateway.{ml,mli}, and config/navigation.ts.
export const KNOWN_CONNECTOR_IDS = ['discord', 'imessage', 'slack', 'telegram'] as const
export type KnownConnectorId = (typeof KNOWN_CONNECTOR_IDS)[number]

// Subset of {@link KNOWN_CONNECTOR_IDS} that run inside the server process. For
// these the sidecar Start/Stop/tail affordances are suppressed (no sidecar
// process — the operator sets an env var and restarts). RFC-0203 §Phase 3.
export const IN_PROCESS_CONNECTOR_IDS = ['discord'] as const
export type InProcessConnectorId = (typeof IN_PROCESS_CONNECTOR_IDS)[number]

export function isInProcessConnector(connectorId: string): boolean {
  return (IN_PROCESS_CONNECTOR_IDS as readonly string[]).includes(connectorId)
}

// The env var the operator must set to activate an in-process connector.
export const IN_PROCESS_CONNECTOR_ENV: Record<InProcessConnectorId, string> = {
  discord: 'DISCORD_BOT_TOKEN',
}

export const CONNECTOR_DISPLAY_NAMES: Record<KnownConnectorId, string> = {
  discord: 'Discord',
  imessage: 'iMessage',
  slack: 'Slack',
  telegram: 'Telegram',
}

export interface SidecarCommands {
  start: string
  tail: string
  status: string
  stop: string
}

// Sidecar directories — only for connectors that run as external sidecar
// processes. Discord is intentionally absent (RFC-0203 §Phase 3).
const SIDECAR_DIRS: Record<string, string> = {
  imessage: 'sidecars/imessage-bot',
  slack: 'sidecars/slack-bot',
  telegram: 'sidecars/telegram-bot',
}

export function sidecarCommands(connectorId: string): SidecarCommands {
  const dir = SIDECAR_DIRS[connectorId] ?? `sidecars/${connectorId}-bot`
  return {
    start: `cd ${dir} && ./run.sh`,
    tail: `cd ${dir} && ./run.sh tail`,
    status: `cd ${dir} && ./run.sh status`,
    stop: `cd ${dir} && ./run.sh stop`,
  }
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
