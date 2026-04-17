import { describe, expect, it } from 'vitest'

import type { ObservedLaneSummary } from './fsm-hub-types'
import { filterObservedLanes } from './fsm-hub-pipeline-panels'

function makeLane(overrides: Partial<ObservedLaneSummary> = {}): ObservedLaneSummary {
  return {
    field: 'KTC',
    label: '턴 주기',
    value: 'idle',
    tone: 'info',
    stalled: false,
    meaning: 'Waiting for the next heartbeat cycle',
    observedForSec: 12,
    transitionCount: 1,
    ...overrides,
  }
}

describe('filterObservedLanes', () => {
  const lanes: ObservedLaneSummary[] = [
    makeLane({ field: 'KTC', label: '턴 주기', value: 'idle', meaning: 'Waiting for the next heartbeat cycle' }),
    makeLane({ field: 'KDP', label: '의사결정', value: 'guard_ok', meaning: 'All safety guards passed' }),
    makeLane({ field: 'KCL', label: '캐스케이드', value: 'trying', meaning: 'Attempting inference with the selected provider' }),
    makeLane({ field: 'KMC', label: '컨텍스트 압축', value: 'accumulating', meaning: 'Collecting messages' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterObservedLanes(lanes, '')).toBe(lanes)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterObservedLanes(lanes, '   ')).toBe(lanes)
  })

  it('matches by field substring (case-insensitive)', () => {
    const result = filterObservedLanes(lanes, 'kcl')
    expect(result.map(l => l.field)).toEqual(['KCL'])
  })

  it('matches by label substring (Korean)', () => {
    const result = filterObservedLanes(lanes, '캐스케이드')
    expect(result.map(l => l.field)).toEqual(['KCL'])
  })

  it('matches by value substring', () => {
    const result = filterObservedLanes(lanes, 'trying')
    expect(result.map(l => l.field)).toEqual(['KCL'])
  })

  it('matches by meaning substring', () => {
    const result = filterObservedLanes(lanes, 'heartbeat')
    expect(result.map(l => l.field)).toEqual(['KTC'])
  })

  it('returns empty when no field matches', () => {
    expect(filterObservedLanes(lanes, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterObservedLanes(lanes, '  KCL  ').map(l => l.field)).toEqual(['KCL'])
  })

  it('does not mutate the input array', () => {
    const copy = lanes.slice()
    filterObservedLanes(lanes, 'trying')
    expect(lanes).toEqual(copy)
  })

  it('handles lanes with empty meaning safely', () => {
    const input: ObservedLaneSummary[] = [makeLane({ field: 'KSM', label: 'phase', value: 'Stable', meaning: '' })]
    expect(filterObservedLanes(input, 'KSM')).toHaveLength(1)
    expect(filterObservedLanes(input, 'anything-else')).toHaveLength(0)
  })
})
