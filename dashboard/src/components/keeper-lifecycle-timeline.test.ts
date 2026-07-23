import { describe, it, expect, vi } from 'vitest'

// Mock modules with lucide-preact icons that cause test-env errors
vi.mock('../store', () => ({
  keepers: { value: [] },
}))
vi.mock('./common/feedback-state', () => ({ LoadingState: () => null }))
vi.mock('./common/time-ago', () => ({ TimeAgo: () => null }))
vi.mock('./keeper-phase-indicator', () => ({
  getPhaseStyle: () => ({ color: '', bg: '', border: '', icon: '', label: '' }),
}))
vi.mock('./keeper-phase-strip', () => ({ toPascalPhase: (s: string) => s }))
vi.mock('../api/keeper', () => ({
  fetchKeeperLifecycle: vi.fn(async () => ({ keeper: '', count: 0, events: [] })),
}))

import { lifecycleEventTone, lifecycleEventLabel } from './keeper-lifecycle-timeline'

describe('lifecycleEventTone', () => {
  it('started returns ok', () => {
    expect(lifecycleEventTone('started')).toBe('ok')
  })

  it('reconciled returns ok', () => {
    expect(lifecycleEventTone('reconciled')).toBe('ok')
  })

  it('restarted returns warn', () => {
    expect(lifecycleEventTone('restarted')).toBe('warn')
  })

  it('dead_cleaned returns bad', () => {
    expect(lifecycleEventTone('dead_cleaned')).toBe('bad')
  })

  it('purged returns info', () => {
    expect(lifecycleEventTone('purged')).toBe('info')
  })

  it('unknown events return info', () => {
    expect(lifecycleEventTone('unknown_event')).toBe('info')
    expect(lifecycleEventTone('')).toBe('info')
  })

  it('is case-insensitive via trim+toLowerCase', () => {
    expect(lifecycleEventTone('  Started  ')).toBe('ok')
    expect(lifecycleEventTone('RESTARTED')).toBe('warn')
  })
})

describe('lifecycleEventLabel', () => {
  it('maps started to Korean label', () => {
    expect(lifecycleEventLabel('started')).toBe('기동됨')
  })

  it('maps restarted to Korean label', () => {
    expect(lifecycleEventLabel('restarted')).toBe('재시작됨')
  })

  it('maps dead_cleaned to Korean label', () => {
    expect(lifecycleEventLabel('dead_cleaned')).toBe('종료 정리됨')
  })

  it('maps purged to Korean label', () => {
    expect(lifecycleEventLabel('purged')).toBe('완전 삭제됨')
  })

  it('falls back to underscore-replaced string for unknown events', () => {
    expect(lifecycleEventLabel('my_custom_event')).toBe('my custom event')
  })

  it('returns empty string as-is', () => {
    expect(lifecycleEventLabel('')).toBe('')
  })
})
