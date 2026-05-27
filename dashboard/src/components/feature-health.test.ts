import { describe, expect, it } from 'vitest'

import { featureStatusLabel } from './feature-health'

describe('featureStatusLabel', () => {
  it.each([
    ['healthy', '정상'],
    ['warning', '실험적'],
    ['inactive', '비활성'],
    ['deprecated', '폐기 예정'],
  ] as const)('featureStatusLabel(%s) → %s', (status, expected) => {
    expect(featureStatusLabel(status)).toBe(expected)
  })
})

