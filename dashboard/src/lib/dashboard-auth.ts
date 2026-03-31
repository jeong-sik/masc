const DASHBOARD_AUTH_TOKEN_KEY = 'masc_bearer_token'

function safeSessionStorage(): Storage | null {
  if (typeof window === 'undefined') return null
  try {
    const storage = window.sessionStorage
    return storage && typeof storage.getItem === 'function' ? storage : null
  } catch {
    return null
  }
}

export function sanitizeDashboardAuthToken(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim()
  return normalized || null
}

export function readStoredDashboardAuthToken(storage: Storage | null = safeSessionStorage()): string | null {
  try {
    return sanitizeDashboardAuthToken(storage?.getItem(DASHBOARD_AUTH_TOKEN_KEY))
  } catch {
    return null
  }
}

export function persistDashboardAuthToken(
  value: string,
  storage: Storage | null = safeSessionStorage(),
): string | null {
  const normalized = sanitizeDashboardAuthToken(value)
  if (!normalized) return null
  try {
    storage?.setItem(DASHBOARD_AUTH_TOKEN_KEY, normalized)
  } catch {
    // Ignore storage failures and keep the in-memory value only.
  }
  return normalized
}

export function resolveDashboardAuthToken(
  search = typeof window === 'undefined' ? '' : window.location.search,
  storage: Storage | null = safeSessionStorage(),
): string | null {
  const params = new URLSearchParams(search)
  return sanitizeDashboardAuthToken(params.get('token'))
    || readStoredDashboardAuthToken(storage)
}

export function bootstrapDashboardAuthTokenFromUrl(
  locationObj: Pick<Location, 'pathname' | 'search' | 'hash'> | null =
    typeof window === 'undefined' ? null : window.location,
  historyObj: Pick<History, 'replaceState' | 'state'> | null =
    typeof window === 'undefined' ? null : window.history,
  storage: Storage | null = safeSessionStorage(),
): string | null {
  if (!locationObj) return readStoredDashboardAuthToken(storage)

  const params = new URLSearchParams(locationObj.search || '')
  const token = sanitizeDashboardAuthToken(params.get('token'))
  if (!token) return readStoredDashboardAuthToken(storage)

  persistDashboardAuthToken(token, storage)
  params.delete('token')

  if (historyObj && typeof historyObj.replaceState === 'function') {
    const nextSearch = params.toString()
    const nextUrl =
      `${locationObj.pathname}${nextSearch ? `?${nextSearch}` : ''}${locationObj.hash || ''}`
    historyObj.replaceState(historyObj.state ?? null, '', nextUrl)
  }

  return token
}
