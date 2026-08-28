import { describe, expect, it } from 'vitest'
import { bundleStaleBannerModel } from './bundle-stale-banner'

// The banner's whole contract lives in the model: when the server's own
// dashboard_surface verdict warrants a strip, what it says, and — just as
// load-bearing — when it stays silent.

describe('bundleStaleBannerModel', () => {
  it('warns on stale with both generations named', () => {
    const model = bundleStaleBannerModel({
      status: 'stale',
      build_stamp_at: '2026-08-27T10:12:41Z',
      binary_built_at: '2026-08-27T10:30:10Z',
      next_action: 'cd dashboard && pnpm run build',
    })
    expect(model).not.toBeNull()
    expect(model!.message).toContain('낡았습니다')
    expect(model!.message).toContain('10:12')
    expect(model!.message).toContain('10:30')
    expect(model!.nextAction).toBe('cd dashboard && pnpm run build')
  })

  it('still warns on stale when the stamps are absent', () => {
    const model = bundleStaleBannerModel({ status: 'stale' })
    expect(model).not.toBeNull()
    expect(model!.message).toContain('낡았습니다')
    // No "(번들 < 서버)" fragment without both instants.
    expect(model!.message).not.toContain('번들')
    expect(model!.nextAction).toContain('pnpm run build')
  })

  it('warns on a missing build stamp as unverifiable, not as current', () => {
    const model = bundleStaleBannerModel({ status: 'missing' })
    expect(model).not.toBeNull()
    expect(model!.message).toContain('확인할 수 없습니다')
  })

  it('stays silent on ok', () => {
    expect(bundleStaleBannerModel({ status: 'ok' })).toBeNull()
  })

  it('stays silent when an older server gives no verdict', () => {
    expect(bundleStaleBannerModel(undefined)).toBeNull()
    expect(bundleStaleBannerModel(null)).toBeNull()
  })
})
