import { describe, it, expect } from 'vitest'
import { statusDotColor } from './status-badge'

describe('statusDotColor', () => {
  it('returns warn for in_progress', () => {
    expect(statusDotColor('in_progress')).toBe('bg-[var(--warn)]')
  })

  it('returns warn for running', () => {
    expect(statusDotColor('running')).toBe('bg-[var(--warn)]')
  })

  it('returns accent for awaiting_verification', () => {
    expect(statusDotColor('awaiting_verification')).toBe('bg-[var(--accent)]')
  })

  it('returns accent for interrupted', () => {
    expect(statusDotColor('interrupted')).toBe('bg-[var(--accent)]')
  })

  it('returns accent for listening', () => {
    expect(statusDotColor('listening')).toBe('bg-[var(--accent)]')
  })

  it('returns slate for inactive', () => {
    expect(statusDotColor('inactive')).toBe('bg-[#5f7199]')
  })

  it('returns slate for offline', () => {
    expect(statusDotColor('offline')).toBe('bg-[#5f7199]')
  })

  it('returns ok for active', () => {
    expect(statusDotColor('active')).toBe('bg-[var(--ok)]')
  })

  it('returns text-slate for busy', () => {
    expect(statusDotColor('busy')).toBe('bg-[var(--text-slate)]')
  })

  it('returns text-slate for stopped', () => {
    expect(statusDotColor('stopped')).toBe('bg-[var(--text-slate)]')
  })

  it('returns bad for error', () => {
    expect(statusDotColor('error')).toBe('bg-[var(--bad)]')
  })

  it('returns muted for unknown status', () => {
    expect(statusDotColor('unknown')).toBe('bg-[var(--text-muted)]')
    expect(statusDotColor('')).toBe('bg-[var(--text-muted)]')
  })
})
