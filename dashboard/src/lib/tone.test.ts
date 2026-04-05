import { describe, expect, it } from 'vitest'
import { toneClass } from './tone'

describe('toneClass', () => {
  it('treats error-like values as bad', () => {
    expect(toneClass('error')).toBe('bad')
    expect(toneClass('failed')).toBe('bad')
    expect(toneClass('fatal')).toBe('bad')
  })

  it('treats stopped as bad', () => {
    expect(toneClass('stopped')).toBe('bad')
  })

  it('treats offline as bad', () => {
    expect(toneClass('offline')).toBe('bad')
  })

  it('treats warning-like values as warn', () => {
    expect(toneClass('warning')).toBe('warn')
    expect(toneClass('degraded')).toBe('warn')
  })

  it('treats unbooted as warn', () => {
    expect(toneClass('unbooted')).toBe('warn')
  })

  it('defaults unknown values to ok', () => {
    expect(toneClass('active')).toBe('ok')
    expect(toneClass(null)).toBe('ok')
    expect(toneClass(undefined)).toBe('ok')
  })
})
