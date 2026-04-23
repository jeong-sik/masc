import { beforeEach, describe, expect, it } from 'vitest'
import {
  oasTotalEvents,
  oasReplayLoadedEvents,
  oasReplayTotalMatchingEvents,
  oasReplayTruncated,
  oasTotalLlmCalls,
  oasTotalErrors,
  oasLastLlmCallTs,
  oasLastErrorTs,
  oasHealthSummary,
  noteOasReplayWindow,
  resetOasRuntimeSignals,
  pushOasAgentEvent,
  updateOasKeeperSnapshot,
  recordOasLlmCall,
  recordOasError,
} from './store'
import type { OasAgentEvent, OasKeeperSnapshot } from './types/oas'

function resetOasSignals() {
  resetOasRuntimeSignals()
}

describe('oasHealthSummary', () => {
  beforeEach(resetOasSignals)

  it('mirrors raw counter signals', () => {
    oasTotalEvents.value = 10
    oasTotalLlmCalls.value = 4
    oasTotalErrors.value = 2
    expect(oasHealthSummary.value.totalEvents).toBe(10)
    expect(oasHealthSummary.value.replayLoadedEvents).toBe(0)
    expect(oasHealthSummary.value.replayTotalMatchingEvents).toBe(0)
    expect(oasHealthSummary.value.replayTruncated).toBe(false)
    expect(oasHealthSummary.value.totalLlmCalls).toBe(4)
    expect(oasHealthSummary.value.totalErrors).toBe(2)
  })

  it('tracks replay sample size separately from total matching entries', () => {
    noteOasReplayWindow({
      loadedEvents: 500,
      totalMatchingEvents: 1842,
      truncated: true,
    })

    expect(oasTotalEvents.value).toBe(1842)
    expect(oasReplayLoadedEvents.value).toBe(500)
    expect(oasReplayTotalMatchingEvents.value).toBe(1842)
    expect(oasReplayTruncated.value).toBe(true)
    expect(oasHealthSummary.value.totalEvents).toBe(1842)
    expect(oasHealthSummary.value.replayLoadedEvents).toBe(500)
    expect(oasHealthSummary.value.replayTotalMatchingEvents).toBe(1842)
    expect(oasHealthSummary.value.replayTruncated).toBe(true)
  })

  it('reflects agent event buffer length', () => {
    const evt = {
      type: 'action_executed',
      actor_kind: 'agent',
      agent_name: 'dreamer',
      timestamp: 1,
      action: 'ponder',
    } satisfies OasAgentEvent
    pushOasAgentEvent(evt)
    pushOasAgentEvent({ ...evt, timestamp: 2 })
    expect(oasHealthSummary.value.agentEventsCount).toBe(2)
    expect(oasHealthSummary.value.totalEvents).toBe(0)
  })

  it('dedups identical consecutive agent events', () => {
    const evt = {
      type: 'action_executed',
      actor_kind: 'agent',
      agent_name: 'dreamer',
      timestamp: 1,
      event_key: 'same-event',
      action: 'ponder',
    } satisfies OasAgentEvent
    pushOasAgentEvent(evt)
    pushOasAgentEvent(evt)
    expect(oasHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('keeps distinct events that only share actor and timestamp', () => {
    pushOasAgentEvent({
      type: 'action_executed',
      actor_kind: 'agent',
      agent_name: 'dreamer',
      timestamp: 1,
      event_key: 'action',
      action: 'ponder',
    } satisfies OasAgentEvent)
    pushOasAgentEvent({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'dreamer',
      timestamp: 1,
      event_key: 'lifecycle',
      phase: 'running',
      detail: 'started',
    } satisfies OasAgentEvent)
    expect(oasHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('tracks keeper snapshots and uses backend tick time', () => {
    const snap: OasKeeperSnapshot = {
      keeper_name: 'runtime-keeper',
      timestamp: 100,
      generation: 1,
      context_ratio: 0.2,
      message_count: 5,
    } as OasKeeperSnapshot
    updateOasKeeperSnapshot(snap)
    expect(oasHealthSummary.value.keeperSnapshotsCount).toBe(1)
    expect(oasHealthSummary.value.lastKeeperTick).toBe(100_000)
  })

  it('starts with zero totals', () => {
    resetOasSignals()
    const s = oasHealthSummary.value
    expect(s.totalEvents).toBe(0)
    expect(s.replayLoadedEvents).toBe(0)
    expect(s.replayTotalMatchingEvents).toBe(0)
    expect(s.replayTruncated).toBe(false)
    expect(s.totalLlmCalls).toBe(0)
    expect(s.totalErrors).toBe(0)
    expect(s.agentEventsCount).toBe(0)
    expect(s.keeperSnapshotsCount).toBe(0)
    expect(s.lastKeeperTick).toBeNull()
    expect(s.lastLlmCallTs).toBeNull()
    expect(s.lastErrorTs).toBeNull()
  })
})

describe('recordOasLlmCall / recordOasError', () => {
  beforeEach(resetOasSignals)

  it('increments LLM call counter and pins timestamp', () => {
    recordOasLlmCall(1_700_000_000_000)
    recordOasLlmCall(1_700_000_060_000)
    expect(oasTotalLlmCalls.value).toBe(2)
    expect(oasLastLlmCallTs.value).toBe(1_700_000_060_000)
    expect(oasHealthSummary.value.lastLlmCallTs).toBe(1_700_000_060_000)
  })

  it('increments error counter and pins timestamp', () => {
    recordOasError(1_700_000_000_000)
    expect(oasTotalErrors.value).toBe(1)
    expect(oasLastErrorTs.value).toBe(1_700_000_000_000)
    expect(oasHealthSummary.value.lastErrorTs).toBe(1_700_000_000_000)
  })

  it('keeps LLM and error counters independent', () => {
    recordOasLlmCall(1)
    recordOasError(2)
    expect(oasTotalLlmCalls.value).toBe(1)
    expect(oasTotalErrors.value).toBe(1)
  })
})
