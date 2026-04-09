import { describe, expect, it } from 'vitest'

import type { Agent, Keeper } from '../types'
import {
  keeperPhaseForDisplay,
  runtimeBandForAgent,
  summarizeMonitoringEvidence,
  summarizeKeeperMonitoring,
} from './monitoring-runtime'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'analyst',
    status: 'busy',
    phase: 'Running',
    pipeline_stage: 'idle',
    ...overrides,
  }
}

describe('summarizeKeeperMonitoring', () => {
  it('treats a running keeper with idle pipeline as active, not offline', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'busy',
        phase: 'Running',
        pipeline_stage: 'idle',
      }),
    )

    expect(summary.band.key).toBe('active')
    expect(summary.phase.label).toBe('실행중')
    expect(summary.stage.label).toBe('활동 없음')
    expect(summarizeMonitoringEvidence(summary)).toEqual({
      phase: null,
      stage: null,
    })
  })

  it('promotes paused keepers into the paused operator band', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'paused',
        phase: 'Paused',
        pipeline_stage: 'paused',
        paused: true,
      }),
    )

    expect(summary.band.key).toBe('paused')
    expect(summary.phase.label).toBe('일시정지')
    expect(summary.stage.label).toBe('일시정지')
    expect(summarizeMonitoringEvidence(summary)).toEqual({
      phase: null,
      stage: null,
    })
  })

  it('prefers paused display phase even when backend phase still says Running', () => {
    const keeper = makeKeeper({
      status: 'idle',
      phase: 'Running',
      pipeline_stage: 'idle',
      paused: true,
    })

    expect(keeperPhaseForDisplay(keeper)).toBe('Paused')
    expect(summarizeKeeperMonitoring(keeper).phase.label).toBe('일시정지')
  })

  it('marks failing phases as attention-worthy', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'busy',
        phase: 'Failing',
        pipeline_stage: 'failing',
      }),
    )

    expect(summary.band.key).toBe('attention')
    expect(summary.phase.label).toBe('오류중')
    expect(summary.hint).toContain('오류')
    expect(summarizeMonitoringEvidence(summary)).toEqual({
      phase: summary.phase,
      stage: null,
    })
  })

  it('does not repeat Running as evidence when attention comes from another signal', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'busy',
        phase: 'Running',
        pipeline_stage: 'idle',
        last_blocker: 'heartbeat stale',
      }),
    )

    expect(summary.band.key).toBe('attention')
    expect(summarizeMonitoringEvidence(summary)).toEqual({
      phase: null,
      stage: null,
    })
  })

  it('keeps never-booted keepers in the offline band', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'offline',
        phase: 'Offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      }),
    )

    expect(summary.band.key).toBe('offline')
    expect(summary.phase.label).toBe('오프라인')
    expect(summary.hint).toContain('부팅')
  })

  it('keeps active stages only when they add new activity context', () => {
    const summary = summarizeKeeperMonitoring(
      makeKeeper({
        status: 'busy',
        phase: 'Running',
        pipeline_stage: 'tool_use',
      }),
    )

    expect(summarizeMonitoringEvidence(summary)).toEqual({
      phase: null,
      stage: summary.stage,
    })
  })
})

describe('runtimeBandForAgent', () => {
  it('uses keeper semantics when a keeper runtime is attached', () => {
    const agent = { name: 'keeper-analyst-agent', status: 'busy' } as Agent
    const keeper = makeKeeper({
      status: 'paused',
      phase: 'Paused',
      pipeline_stage: 'paused',
      paused: true,
    })

    expect(runtimeBandForAgent(agent, keeper)).toBe('paused')
  })

  it('maps non-keeper offline agents into the offline band', () => {
    const agent = { name: 'worker-1', status: 'offline' } as Agent
    expect(runtimeBandForAgent(agent, null)).toBe('offline')
  })

  it('treats online non-keeper agents as active', () => {
    const agent = { name: 'worker-1', status: 'listening' } as Agent
    expect(runtimeBandForAgent(agent, null)).toBe('active')
  })
})
