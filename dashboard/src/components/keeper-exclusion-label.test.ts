import { describe, expect, it } from 'vitest'
import { keeperExclusionLabel } from './keeper-exclusion-label'

describe('keeperExclusionLabel', () => {
  it('maps declarative_autoboot_disabled to a Korean operator label', () => {
    expect(keeperExclusionLabel('declarative_autoboot_disabled')).toBe('시작 시 부팅 안 함')
  })

  it('maps autoboot_disabled to a Korean operator label', () => {
    expect(keeperExclusionLabel('autoboot_disabled')).toBe('수동 부팅 해제')
  })

  it('returns null for paused — the roster and detail strip already render a dedicated 일시정지 badge, so the exclusion label must not duplicate it', () => {
    expect(keeperExclusionLabel('paused')).toBeNull()
  })

  it('returns null for bootable keepers (null / undefined reason)', () => {
    expect(keeperExclusionLabel(null)).toBeNull()
    expect(keeperExclusionLabel(undefined)).toBeNull()
  })

  it('returns a visible generic label for unknown reason strings without surfacing raw backend tokens', () => {
    expect(keeperExclusionLabel('something_future')).toBe('부팅 제외')
    expect(keeperExclusionLabel('')).toBeNull()
  })
})
