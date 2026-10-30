// Dashboard error notification types

// The agent_failed SSE payload is the only producer feeding this surface
// (sse-store.ts). Its error_domain field mirrors Agent_core.Error.category_label
// (packages/agent_core/lib/base/error.ml) — a closed nine-member vocabulary.
//
// Its error_code field is NOT closed: Keeper_turn_terminal_code.to_wire passes
// provider codes and core-error wires through unchanged, so error_code is
// display text, never a lookup key.
export const ERROR_DOMAINS = [
  'api',
  'provider',
  'agent',
  'mcp',
  'config',
  'serialization',
  'io',
  'orchestration',
  'internal',
] as const

export type ErrorDomain = (typeof ERROR_DOMAINS)[number]

export type ErrorSeverity = 'critical' | 'warning'

export interface DashboardError {
  id: string
  fingerprint: string
  agentName: string
  taskId: string | null
  message: string
  /** Raw wire error_code. Open vocabulary — shown as text, not looked up. */
  errorCode: string
  /** null when the wire carried a domain this build does not model. */
  domain: ErrorDomain | null
  severity: ErrorSeverity
  timestamp: number
  acknowledged: boolean
  count: number
  lastSeen: number
}

const DOMAIN_SET: ReadonlySet<string> = new Set(ERROR_DOMAINS)

/** Returns null rather than a default so an unmodelled domain stays visible. */
export function parseErrorDomain(raw: string): ErrorDomain | null {
  return DOMAIN_SET.has(raw) ? (raw as ErrorDomain) : null
}

// Severity uses the producer's own retryable flag rather than a code table the
// dashboard would have to keep in step with the server. An unmodelled domain is
// critical because the dashboard has no basis to judge it.
export function severityFor(
  domain: ErrorDomain | null,
  retryable: boolean,
): ErrorSeverity {
  if (domain === null) return 'critical'
  return retryable ? 'warning' : 'critical'
}
