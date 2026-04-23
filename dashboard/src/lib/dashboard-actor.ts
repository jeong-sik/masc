const DASHBOARD_AGENT_NAME_RE = /[^A-Za-z0-9._-]+/g
const DASHBOARD_AGENT_NAME_MAX_LENGTH = 32

export const DASHBOARD_AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type HistoryLike = Pick<History, 'replaceState'>
type LocationLike = Pick<Location, 'pathname' | 'search' | 'hash'>

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

export function hasDashboardActorQueryParam(
  search = typeof window === 'undefined' ? '' : window.location.search,
): boolean {
  const params = new URLSearchParams(search)
  return params.has('agent') || params.has('agent_name')
}

export function replaceDashboardActorQueryParam(
  value: string,
  location: LocationLike | null = typeof window === 'undefined' ? null : window.location,
  history: HistoryLike | null = typeof window === 'undefined' ? null : window.history,
): string {
  const normalized = sanitizeDashboardActorName(value) || 'dashboard'
  if (!location || !history) return normalized
  const params = new URLSearchParams(location.search)
  params.set('agent', normalized)
  params.delete('agent_name')
  const query = params.toString()
  const nextUrl = `${location.pathname}${query ? `?${query}` : ''}${location.hash}`
  history.replaceState(null, '', nextUrl)
  return normalized
}

export function syncDashboardActorName(
  value: string,
  options: {
    storage?: Storage | null
    rewriteQuery?: boolean
    location?: LocationLike | null
    history?: HistoryLike | null
  } = {},
): string {
  const normalized = persistDashboardActorName(value, options.storage ?? safeStorage())
  if (options.rewriteQuery) {
    replaceDashboardActorQueryParam(
      normalized,
      options.location ?? (typeof window === 'undefined' ? null : window.location),
      options.history ?? (typeof window === 'undefined' ? null : window.history),
    )
  }
  return normalized
}
