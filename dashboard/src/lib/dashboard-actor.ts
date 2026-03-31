const DASHBOARD_AGENT_NAME_RE = /[^A-Za-z0-9._-]+/g
const DASHBOARD_AGENT_NAME_MAX_LENGTH = 32

export const DASHBOARD_AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function safeStorage(): Storage | null {
  if (typeof window === 'undefined') return null
  try {
    const storage = window.localStorage
    return storage && typeof storage.getItem === 'function' ? storage : null
  } catch {
    return null
  }
}

export function sanitizeDashboardActorName(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null
  const normalized = value
    .trim()
    .replace(DASHBOARD_AGENT_NAME_RE, '')
    .slice(0, DASHBOARD_AGENT_NAME_MAX_LENGTH)
  return normalized || null
}

export function readStoredDashboardActorName(storage: Storage | null = safeStorage()): string | null {
  try {
    return sanitizeDashboardActorName(storage?.getItem(DASHBOARD_AGENT_NAME_KEY))
  } catch {
    return null
  }
}

export function resolveDashboardActorName(
  search = typeof window === 'undefined' ? '' : window.location.search,
  storage: Storage | null = safeStorage(),
): string | null {
  const params = new URLSearchParams(search)
  return sanitizeDashboardActorName(params.get('agent'))
    || sanitizeDashboardActorName(params.get('agent_name'))
    || readStoredDashboardActorName(storage)
}

export function persistDashboardActorName(
  value: string,
  storage: Storage | null = safeStorage(),
): string {
  const normalized = sanitizeDashboardActorName(value) || 'dashboard'
  try {
    storage?.setItem(DASHBOARD_AGENT_NAME_KEY, normalized)
  } catch {
    // Ignore storage write failures and keep the in-memory value.
  }
  return normalized
}
