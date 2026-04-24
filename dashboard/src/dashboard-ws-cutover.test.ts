import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { dashboardWsOnlyEnabled } from './dashboard-ws-cutover'

type MutableWindow = Window & {
  __MASC_DASHBOARD_WS_ONLY__?: unknown
}

describe('dashboardWsOnlyEnabled', () => {
  let originalWindow: MutableWindow

  beforeEach(() => {
    originalWindow = window as MutableWindow
    delete originalWindow.__MASC_DASHBOARD_WS_ONLY__
    vi.unstubAllEnvs()
  })

  afterEach(() => {
    delete originalWindow.__MASC_DASHBOARD_WS_ONLY__
    vi.unstubAllEnvs()
  })

  it('defaults to false when neither runtime nor build flag is set', () => {
    expect(dashboardWsOnlyEnabled()).toBe(false)
  })

  it('returns true when runtime window flag is explicitly true', () => {
    originalWindow.__MASC_DASHBOARD_WS_ONLY__ = true
    expect(dashboardWsOnlyEnabled()).toBe(true)
  })

  it('returns false when runtime window flag is explicitly false, even if build flag says true', () => {
    originalWindow.__MASC_DASHBOARD_WS_ONLY__ = false
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'true')
    expect(dashboardWsOnlyEnabled()).toBe(false)
  })

  it('falls through to build flag when runtime flag is not a boolean', () => {
    originalWindow.__MASC_DASHBOARD_WS_ONLY__ = 'maybe'
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'true')
    expect(dashboardWsOnlyEnabled()).toBe(true)
  })

  it('accepts "true" or "1" as affirmative build flag values', () => {
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'true')
    expect(dashboardWsOnlyEnabled()).toBe(true)
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', '1')
    expect(dashboardWsOnlyEnabled()).toBe(true)
  })

  it('treats other build flag values as false', () => {
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'yes')
    expect(dashboardWsOnlyEnabled()).toBe(false)
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', '')
    expect(dashboardWsOnlyEnabled()).toBe(false)
  })
})
