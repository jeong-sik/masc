import { beforeEach, describe, expect, it } from 'vitest'
import {
  oasAgentEvents,
  oasKeeperSnapshots,
  oasLastKeeperTick,
  oasTotalEvents,
  oasTotalLlmCalls,
  oasTotalErrors,
  oasHealthSummary,
  pushOasAgentEvent,
  updateOasKeeperSnapshot,
} from './store'
import type { OasAgentEvent, OasKeeperSnapshot } from './types/oas'

function resetOasSignals() {
  oasAgentEvents.value = []
  oasKeeperSnapshots.value = new Map()
  oasLastKeeperTick.value = null
  oasTotalEvents.value = 0
  oasTotalLlmCalls.value = 0
  oasTotalErrors.value = 0
}

describe('oasHealthSummary', () => {
  beforeEach(resetOasSignals)

  it('mirrors raw counter signals', () => {
    oasTotalEvents.value = 10
    oasTotalLlmCalls.value = 4
    oasTotalErrors.value = 2
    expect(oasHealthSummary.value.totalEvents).toBe(10)
    expect(oasHealthSummary.value.totalLlmCalls).toBe(4)
    expect(oasHealthSummary.value.totalErrors).toBe(2)
  })

  it('reflects agent event buffer length', () => {
    const evt = {
      type: 'action_executed',
      agent_name: 'dreamer',
      timestamp: 1,
      action: 'ponder',
    } as unknown as OasAgentEvent
    pushOasAgentEvent(evt)
    pushOasAgentEvent({ ...evt, timestamp: 2 })
    expect(oasHealthSummary.value.agentEventsCount).toBe(2)
    expect(oasHealthSummary.value.totalEvents).toBe(2)
  })

  it('dedups identical consecutive agent events', () => {
    const evt = {
      type: 'action_executed',
      agent_name: 'dreamer',
      timestamp: 1,
      action: 'ponder',
    } as unknown as OasAgentEvent
    pushOasAgentEvent(evt)
    pushOasAgentEvent(evt) // same type+agent+timestamp → should be dropped
    expect(oasHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('tracks keeper snapshots and last tick', () => {
    const snap: OasKeeperSnapshot = {
      keeper_name: 'runtime-keeper',
      timestamp: 100,
      generation: 1,
      context_ratio: 0.2,
      message_count: 5,
    } as OasKeeperSnapshot
    updateOasKeeperSnapshot(snap)
    expect(oasHealthSummary.value.keeperSnapshotsCount).toBe(1)
    expect(oasHealthSummary.value.lastKeeperTick).not.toBeNull()
  })

  it('starts with zero totals', () => {
    resetOasSignals()
    const s = oasHealthSummary.value
    expect(s.totalEvents).toBe(0)
    expect(s.totalLlmCalls).toBe(0)
    expect(s.totalErrors).toBe(0)
    expect(s.agentEventsCount).toBe(0)
    expect(s.keeperSnapshotsCount).toBe(0)
    expect(s.lastKeeperTick).toBeNull()
  })
})
