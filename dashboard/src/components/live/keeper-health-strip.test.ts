import { describe, expect, it } from 'vitest'
import { keeperHealthStatusChips } from './keeper-health-strip'

describe('keeperHealthStatusChips', () => {
  it('renders a single ok chip when no alerts are present', () => {
    expect(keeperHealthStatusChips({ warningCount: 0, criticalCount: 0 })).toEqual([
      { key: 'ok', label: '정상', tone: 'ok' },
    ])
  })

  it('combines warnings and criticals into the alert chip', () => {
    expect(keeperHealthStatusChips({ warningCount: 2, criticalCount: 1 })).toEqual([
      { key: 'warning', label: '3 주의', tone: 'warn' },
      { key: 'critical', label: '1 위험', tone: 'bad' },
    ])
  })
})
