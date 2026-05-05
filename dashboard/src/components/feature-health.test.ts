import { describe, expect, it } from 'vitest'

import { statusLabel } from './feature-health'

describe('statusLabel', () => {
  it.each([
    ['healthy', '정상'],
    ['warning', '실험적'],
    ['inactive', '비활성'],
    ['deprecated', '폐기 예정'],
  ] as const)('statusLabel(%s) → %s', (status, expected) => {
    expect(statusLabel(status)).toBe(expected)
  })
})

