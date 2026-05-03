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

  it('defaults to true when neither runtime nor build flag is set', () => {
    expect(dashboardWsOnlyEnabled()).toBe(true)
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
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'false')
    expect(dashboardWsOnlyEnabled()).toBe(false)
  })

  it('accepts "false" or "0" as negative build flag values', () => {
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'false')
    expect(dashboardWsOnlyEnabled()).toBe(false)
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', '0')
    expect(dashboardWsOnlyEnabled()).toBe(false)
  })

  it('treats other build flag values as true', () => {
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', 'yes')
    expect(dashboardWsOnlyEnabled()).toBe(true)
    vi.stubEnv('VITE_DASHBOARD_WS_ONLY', '')
    expect(dashboardWsOnlyEnabled()).toBe(true)
  })
})
