import { describe, expect, it } from 'vitest'
import { toneClass } from './tone'

describe('toneClass', () => {
  it('treats error-like values as bad', () => {
    expect(toneClass('error')).toBe('bad')
    expect(toneClass('failed')).toBe('bad')
    expect(toneClass('fatal')).toBe('bad')
  })

  it('treats warning-like values as warn', () => {
    expect(toneClass('warning')).toBe('warn')
    expect(toneClass('degraded')).toBe('warn')
  })
})
