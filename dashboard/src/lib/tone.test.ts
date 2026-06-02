import { describe, it, expect } from 'vitest'
import { toneClass } from './tone'

describe('toneClass', () => {
  it('classifies bad tones', () => {
    for (const t of ['bad','error','failed','fatal','offline','stopped','critical','risk']) {
      expect(toneClass(t)).toBe('bad')
    }
  })
  it('classifies warn tones', () => {
    for (const t of ['warn','warning','pending','degraded','interrupted','watch','paused','blocked','unbooted']) {
      expect(toneClass(t)).toBe('warn')
    }
  })
  it('classifies ok tones', () => {
    for (const t of ['ok','healthy','active','running','done','idle']) {
      expect(toneClass(t)).toBe('ok')
    }
  })
  it('defaults to ok for null/undefined/empty', () => {
    expect(toneClass(null)).toBe('ok')
    expect(toneClass(undefined)).toBe('ok')
    expect(toneClass('')).toBe('ok')
  })
})
