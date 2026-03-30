import { describe, expect, it } from 'vitest'
import {
  normalizePersonaSummaries,
  normalizePersonaSummary,
} from './keeper-spawn-state'

describe('normalizePersonaSummary', () => {
  it('accepts backend persona summary fields and keeps the handle for spawning', () => {
    expect(
      normalizePersonaSummary({
        persona_name: 'sonsukku',
        display_name: '손석구',
        role: '무심한 로코형 동네 형',
        trait: '건조한 농담과 낮은 텐션',
      }),
    ).toEqual({
      name: 'sonsukku',
      displayName: '손석구',
      role: '무심한 로코형 동네 형',
      mode: undefined,
      description: '건조한 농담과 낮은 텐션',
    })
  })

  it('falls back to existing dashboard-shaped fields when they already match', () => {
    expect(
      normalizePersonaSummary({
        name: 'sangsu',
        displayName: '상수',
        role: '찌질한 영화감독',
        description: '직설적이고 현실 감각 있는 동네 형',
      }),
    ).toEqual({
      name: 'sangsu',
      displayName: '상수',
      role: '찌질한 영화감독',
      mode: undefined,
      description: '직설적이고 현실 감각 있는 동네 형',
    })
  })
})

describe('normalizePersonaSummaries', () => {
  it('reads both wrapped and bare arrays and filters invalid entries', () => {
    expect(
      normalizePersonaSummaries({
        personas: [
          { persona_name: 'sonsukku', display_name: '손석구' },
          { name: '' },
          'skip-me',
        ],
      }),
    ).toEqual([
      {
        name: 'sonsukku',
        displayName: '손석구',
        role: undefined,
        mode: undefined,
        description: undefined,
      },
    ])
  })
})
