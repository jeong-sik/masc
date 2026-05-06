// AgentPresence — AX atom that renders an agent's presence state.
//
// Kimi design system sec05 reference: Slack status dot + Discord activity
// indicator. The dot + pulse animation communicates "this agent is a
// digital colleague" rather than an abstract process.
//
// Maps the internal Agent.status domain (6 values) to 4 visual presence
// states (online / working / idle / offline). The mapping is intentionally
// lossy — visual density in a roster card cannot carry 6 states without
// crowding.

import { html } from 'htm/preact'

export type PresenceVisualState = 'online' | 'working' | 'idle' | 'offline'
export type AgentPresenceSize = 'sm' | 'md'

export interface PresenceConfig {
  colorClass: string
  pulse: boolean
  label: string
}

export interface AgentPresenceSummary {
  readonly rawStatus: string
  readonly state: PresenceVisualState
  readonly label: string
  readonly pulse: boolean
  readonly size: AgentPresenceSize
  readonly detail: string
  readonly detailPresent: boolean
}

const PRESENCE_CONFIG: Record<PresenceVisualState, PresenceConfig> = {
  online: {
    colorClass: 'bg-[var(--color-status-ok)]',
    pulse: false,
    label: '온라인',
  },
  working: {
    colorClass: 'bg-[var(--color-accent-fg)]',
    pulse: true,
    label: '작업 중',
  },
  idle: {
    colorClass: 'bg-[var(--color-status-warn)]',
    pulse: false,
    label: '대기',
  },
  offline: {
    colorClass: 'bg-[var(--color-bg-hover)]',
    pulse: false,
    label: '오프라인',
  },
}

/** Pure: map the backend Agent.status to a visual presence state.
    The mapping collapses 6 backend states into 4 visual buckets so
    the roster grid stays scannable. */
export function agentStatusToPresence(
  status: string | null | undefined,
): PresenceVisualState {
  switch (status) {
    case 'active':
      return 'online'
    case 'busy':
    case 'listening':
      return 'working'
    case 'idle':
      return 'idle'
    case 'inactive':
    case 'offline':
    default:
      return 'offline'
  }
}

/** Pure: config lookup exposed so callers can pre-build strings. */
export function presenceConfig(state: PresenceVisualState): PresenceConfig {
  return PRESENCE_CONFIG[state]
}

export function summarizeAgentPresence(
  status: string | null | undefined,
  detail: string | null | undefined,
  size: AgentPresenceSize,
): AgentPresenceSummary {
  const state = agentStatusToPresence(status)
  const config = presenceConfig(state)
  const normalizedDetail = detail ?? ''
  return {
    rawStatus: status ?? '',
    state,
    label: config.label,
    pulse: config.pulse,
    size,
    detail: normalizedDetail,
    detailPresent: normalizedDetail.length > 0,
  }
}

interface AgentPresenceProps {
  status: string | null | undefined
  detail?: string | null
  size?: AgentPresenceSize
  testId?: string
}

const SIZE_CLASSES = {
  sm: 'h-2 w-2',
  md: 'h-2.5 w-2.5',
} as const

export function AgentPresence({
  status,
  detail,
  size = 'sm',
  testId,
}: AgentPresenceProps) {
  const summary = summarizeAgentPresence(status, detail, size)
  const config = PRESENCE_CONFIG[summary.state]
  const dotSize = SIZE_CLASSES[size]
  const pulseRing = config.pulse
    ? html`<span
        class="absolute inline-flex h-full w-full animate-ping rounded-full opacity-60 ${config.colorClass}"
        aria-hidden="true"
      ></span>`
    : null

  return html`
    <div
      class="inline-flex max-w-full flex-wrap items-center gap-x-2 gap-y-1"
      data-agent-presence
      data-presence-raw-status=${summary.rawStatus}
      data-presence-state=${summary.state}
      data-presence-label=${summary.label}
      data-presence-pulse=${summary.pulse}
      data-presence-size=${summary.size}
      data-presence-detail-present=${summary.detailPresent}
      data-presence-detail=${summary.detail}
      data-testid=${testId}
    >
      <span class="relative inline-flex ${dotSize}">
        ${pulseRing}
        <span
          class="relative inline-flex rounded-full ${dotSize} ${config.colorClass}"
          role="img"
          aria-label=${config.label}
        ></span>
      </span>
      <span class="text-xs text-[var(--color-fg-secondary)]">${config.label}</span>
      ${summary.detailPresent
        ? html`<span
            class="min-w-0 max-w-[12rem] truncate text-xs text-[var(--color-fg-muted)]"
            title=${summary.detail}
            >${summary.detail}</span
          >`
        : null}
    </div>
  `
}
