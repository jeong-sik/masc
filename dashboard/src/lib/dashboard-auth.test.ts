import { afterEach, describe, expect, it } from 'vitest'
import {
  bootstrapDashboardAuthTokenFromUrl,
  readStoredDashboardAuthToken,
  resolveDashboardAuthToken,
} from './dashboard-auth'

afterEach(() => {
  try {
    window.sessionStorage?.clear?.()
    window.history.replaceState({}, '', 'http://localhost/')
  } catch {
    // Ignore cleanup failures in the test environment.
  }
})

describe('dashboard auth token bootstrap', () => {
  it('moves the token out of the URL and into session storage', () => {
    window.history.replaceState({}, '', '/dashboard?agent=ops&token=secret#overview')

    const token = bootstrapDashboardAuthTokenFromUrl()

    expect(token).toBe('secret')
    expect(readStoredDashboardAuthToken()).toBe('secret')
    expect(window.location.search).toBe('?agent=ops')
    expect(window.location.hash).toBe('#overview')
  })

  it('falls back to stored token when the URL no longer contains one', () => {
    window.sessionStorage?.setItem?.('masc_dashboard_auth_token', 'stored-secret')

    expect(resolveDashboardAuthToken('')).toBe('stored-secret')
  })
})
