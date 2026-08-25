import { beforeEach, describe, expect, it } from 'vitest'
import {
  agentCoreTotalEvents,
  agentCoreReplayLoadedEvents,
  agentCoreReplayTotalMatchingEvents,
  agentCoreReplayTruncated,
  agentCoreReplayCapped,
  agentCoreTotalLlmCalls,
  agentCoreTotalErrors,
  agentCoreLastLlmCallTs,
  agentCoreLastErrorTs,
  agentCoreEvidenceRefsCount,
  agentCoreArtifactRefsCount,
  agentCoreRawTraceRefsCount,
  agentCoreReportRefsCount,
  agentCoreProofRefsCount,
  agentCoreTelemetryRefsCount,
  agentCoreRuntimeEvidenceRefsCount,
  agentCoreLastEvidenceTs,
  agentCoreHealthSummary,
  noteAgentCoreReplayWindow,
  resetAgentCoreRuntimeSignals,
  pushAgentCoreAgentEvent,
  recordAgentCoreLlmCall,
  recordAgentCoreError,
  recordAgentCoreEvidenceRefs,
} from './store'
import type { AgentCoreAgentEvent } from './types/agent-core'

function resetAgentCoreSignals() {
  resetAgentCoreRuntimeSignals()
}

describe('agentCoreHealthSummary', () => {
  beforeEach(resetAgentCoreSignals)

  it('mirrors raw counter signals', () => {
    agentCoreTotalEvents.value = 10
    agentCoreTotalLlmCalls.value = 4
    agentCoreTotalErrors.value = 2
    expect(agentCoreHealthSummary.value.totalEvents).toBe(10)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(0)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(0)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(false)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(false)
    expect(agentCoreHealthSummary.value.totalLlmCalls).toBe(4)
    expect(agentCoreHealthSummary.value.totalErrors).toBe(2)
    expect(agentCoreHealthSummary.value.evidenceRefsCount).toBe(0)
  })

  it('tracks replay sample size separately from total matching entries', () => {
    noteAgentCoreReplayWindow({
      loadedEvents: 500,
      totalMatchingEvents: 1842,
      truncated: true,
    })

    expect(agentCoreTotalEvents.value).toBe(1842)
    expect(agentCoreReplayLoadedEvents.value).toBe(500)
    expect(agentCoreReplayTotalMatchingEvents.value).toBe(1842)
    expect(agentCoreReplayTruncated.value).toBe(true)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(1842)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(500)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(1842)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(true)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(false)
  })

  it('marks a server-capped replay window without offering another page', () => {
    noteAgentCoreReplayWindow({
      loadedEvents: 5499,
      totalMatchingEvents: 6000,
      truncated: false,
      capped: true,
    })

    expect(agentCoreReplayCapped.value).toBe(true)
    expect(agentCoreHealthSummary.value.replayCapped).toBe(true)
    expect(agentCoreHealthSummary.value.hasMore).toBe(false)
  })

  it('reflects agent event buffer length', () => {
    const evt = {
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      phase: 'Running',
    } satisfies AgentCoreAgentEvent
    pushAgentCoreAgentEvent(evt)
    pushAgentCoreAgentEvent({ ...evt, timestamp: 2 })
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(0)
  })

  it('dedups identical consecutive agent events', () => {
    const evt = {
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'same-event',
      phase: 'Running',
    } satisfies AgentCoreAgentEvent
    pushAgentCoreAgentEvent(evt)
    pushAgentCoreAgentEvent(evt)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('keeps distinct events that only share actor and timestamp', () => {
    pushAgentCoreAgentEvent({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'action',
      phase: 'Paused',
    } satisfies AgentCoreAgentEvent)
    pushAgentCoreAgentEvent({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'alice',
      timestamp: 1,
      event_key: 'lifecycle',
      phase: 'Running',
      detail: 'started',
    } satisfies AgentCoreAgentEvent)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('starts with zero totals', () => {
    resetAgentCoreSignals()
    const s = agentCoreHealthSummary.value
    expect(s.totalEvents).toBe(0)
    expect(s.replayLoadedEvents).toBe(0)
    expect(s.replayTotalMatchingEvents).toBe(0)
    expect(s.replayTruncated).toBe(false)
    expect(s.replayCapped).toBe(false)
    expect(s.totalLlmCalls).toBe(0)
    expect(s.totalErrors).toBe(0)
    expect(s.agentEventsCount).toBe(0)
    expect(s.lastLlmCallTs).toBeNull()
    expect(s.lastErrorTs).toBeNull()
    expect(s.evidenceRefsCount).toBe(0)
    expect(s.artifactRefsCount).toBe(0)
    expect(s.rawTraceRefsCount).toBe(0)
    expect(s.reportRefsCount).toBe(0)
    expect(s.proofRefsCount).toBe(0)
    expect(s.telemetryRefsCount).toBe(0)
    expect(s.runtimeEvidenceRefsCount).toBe(0)
    expect(s.lastEvidenceTs).toBeNull()
  })
})

describe('recordAgentCoreLlmCall / recordAgentCoreError / recordAgentCoreEvidenceRefs', () => {
  beforeEach(resetAgentCoreSignals)

  it('increments LLM call counter and pins timestamp', () => {
    recordAgentCoreLlmCall(1_700_000_000_000)
    recordAgentCoreLlmCall(1_700_000_060_000)
    expect(agentCoreTotalLlmCalls.value).toBe(2)
    expect(agentCoreLastLlmCallTs.value).toBe(1_700_000_060_000)
    expect(agentCoreHealthSummary.value.lastLlmCallTs).toBe(1_700_000_060_000)
  })

  it('increments error counter and pins timestamp', () => {
    recordAgentCoreError(1_700_000_000_000)
    expect(agentCoreTotalErrors.value).toBe(1)
    expect(agentCoreLastErrorTs.value).toBe(1_700_000_000_000)
    expect(agentCoreHealthSummary.value.lastErrorTs).toBe(1_700_000_000_000)
  })

  it('keeps LLM and error counters independent', () => {
    recordAgentCoreLlmCall(1)
    recordAgentCoreError(2)
    expect(agentCoreTotalLlmCalls.value).toBe(1)
    expect(agentCoreTotalErrors.value).toBe(1)
  })

  it('tracks Agent Core evidence reference counters independently', () => {
    recordAgentCoreEvidenceRefs({
      evidenceRefsCount: 6,
      artifactRefsCount: 2,
      rawTraceRefsCount: 1,
      reportRefsCount: 1,
      proofRefsCount: 1,
      telemetryRefsCount: 1,
      runtimeEvidenceRefsCount: 1,
      tsMs: 1_700_000_000_000,
    })

    expect(agentCoreEvidenceRefsCount.value).toBe(6)
    expect(agentCoreArtifactRefsCount.value).toBe(2)
    expect(agentCoreRawTraceRefsCount.value).toBe(1)
    expect(agentCoreReportRefsCount.value).toBe(1)
    expect(agentCoreProofRefsCount.value).toBe(1)
    expect(agentCoreTelemetryRefsCount.value).toBe(1)
    expect(agentCoreRuntimeEvidenceRefsCount.value).toBe(1)
    expect(agentCoreLastEvidenceTs.value).toBe(1_700_000_000_000)
    expect(agentCoreHealthSummary.value).toMatchObject({
      evidenceRefsCount: 6,
      artifactRefsCount: 2,
      rawTraceRefsCount: 1,
      reportRefsCount: 1,
      proofRefsCount: 1,
      telemetryRefsCount: 1,
      runtimeEvidenceRefsCount: 1,
      lastEvidenceTs: 1_700_000_000_000,
    })
  })
})
