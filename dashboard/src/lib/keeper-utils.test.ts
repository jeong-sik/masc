import { describe, expect, it } from 'vitest'
import { isVerifierRoleKeeper } from './keeper-utils'

describe('isVerifierRoleKeeper', () => {
  it('detects the english "verifier" token', () => {
    expect(isVerifierRoleKeeper(['verifier'])).toBe(true)
  })

  it('detects the korean "검증자" token', () => {
    expect(isVerifierRoleKeeper(['검증자'])).toBe(true)
  })

  it('rejects non-verifier mention targets', () => {
    expect(isVerifierRoleKeeper(['analyst', 'scholar'])).toBe(false)
  })

  it('returns false for empty mention targets', () => {
    expect(isVerifierRoleKeeper([])).toBe(false)
  })

  it('returns false for null / undefined', () => {
    expect(isVerifierRoleKeeper(null)).toBe(false)
    expect(isVerifierRoleKeeper(undefined)).toBe(false)
  })

  it('accepts mixed mention targets including the verifier token', () => {
    expect(isVerifierRoleKeeper(['analyst', 'verifier', 'guard'])).toBe(true)
  })
})
