// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { shouldUseCompactDashboardChrome } from './app'

describe('shouldUseCompactDashboardChrome', () => {
  it('uses compact chrome for keeper detail routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
      keeperDetailMode: true,
    })).toBe(true)
  })

  it('keeps the standard shell for normal dashboard routes', () => {
    expect(shouldUseCompactDashboardChrome({
      widgetSoloMode: false,
      focusMode: false,
      keeperDetailMode: false,
    })).toBe(false)
  })
})
