import { describe, it, expect } from 'vitest'
import { isOfflineStatus } from './status-utils'

describe('isOfflineStatus', () => {
  it('returns true for offline', () => {
    expect(isOfflineStatus('offline')).toBe(true)
  })

  it('returns true for inactive', () => {
    expect(isOfflineStatus('inactive')).toBe(true)
  })

  it('returns true for unbooted', () => {
    expect(isOfflineStatus('unbooted')).toBe(true)
  })

  it('returns true for stopped', () => {
    expect(isOfflineStatus('stopped')).toBe(true)
  })

  it('returns false for active', () => {
    expect(isOfflineStatus('active')).toBe(false)
  })

  it('returns false for running', () => {
    expect(isOfflineStatus('running')).toBe(false)
  })

  it('returns false for null', () => {
    expect(isOfflineStatus(null)).toBe(false)
  })

  it('returns false for undefined', () => {
    expect(isOfflineStatus(undefined)).toBe(false)
  })

  it('returns false for empty string', () => {
    expect(isOfflineStatus('')).toBe(false)
  })

  it('is case-insensitive', () => {
    expect(isOfflineStatus('OFFLINE')).toBe(true)
    expect(isOfflineStatus('Inactive')).toBe(true)
    expect(isOfflineStatus('UNBOOTED')).toBe(true)
  })
})
