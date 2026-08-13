import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./api/dashboard', () => ({
  fetchTelemetry: vi.fn(),
}))

import { fetchTelemetry, type TelemetryEntry } from './api/dashboard'
import {
  applyAgentCoreRuntimeEvent,
  hydrateAgentCoreRuntimeFromTelemetryEntries,
  replayAgentCoreRuntimeTelemetry,
  loadMoreAgentCoreEvents,
} from './agent-core-runtime-store'
import {
  agentCoreAgentEvents,
  agentCoreHealthSummary,
} from './store'
import {
  ensureLiveTraceSlot,
  liveTraceFeeds,
} from './components/session-trace/session-trace-live-store'

const fetchTelemetryMock = vi.mocked(fetchTelemetry)

function resetRuntimeState() {
  hydrateAgentCoreRuntimeFromTelemetryEntries([])
  liveTraceFeeds.value = {}
}

describe('agent-core-runtime-store', () => {
  beforeEach(() => {
    fetchTelemetryMock.mockReset()
    resetRuntimeState()
  })

  it('hydrates durable telemetry into one Agent Core runtime summary', () => {
    const entries: TelemetryEntry[] = [
      {
        source: 'agent_core_event',
        type: 'agent_core:durable:error_occurred',
        ts_unix: 400,
        correlation_id: 'corr-4',
        run_id: 'run-1',
        payload: {
          agent_name: 'alpha',
          error_domain: 'tool',
          detail: 'timeout',
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:durable:llm_request',
        ts_unix: 300,
        correlation_id: 'corr-3',
        run_id: 'run-1',
        payload: {
          agent_name: 'alpha',
          model: 'gpt-5',
          input_tokens: 64,
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:masc:trust_updated',
        ts_unix: 100,
        correlation_id: 'corr-1',
        run_id: 'run-1',
        payload: {
          agent_a: 'alpha',
          agent_b: 'beta',
          trust_score: 0.8,
          timestamp: 100,
        },
      },
    ] as TelemetryEntry[]

    hydrateAgentCoreRuntimeFromTelemetryEntries(entries)

    expect(agentCoreHealthSummary.value.totalEvents).toBe(3)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(3)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(3)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(false)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(1)
    expect(agentCoreHealthSummary.value.totalLlmCalls).toBe(1)
    expect(agentCoreHealthSummary.value.totalErrors).toBe(1)
    expect(agentCoreHealthSummary.value.lastLlmCallTs).toBe(300_000)
    expect(agentCoreHealthSummary.value.lastErrorTs).toBe(400_000)
    expect(agentCoreAgentEvents.value[0]?.agent_name).toBe('alpha')
  })

  it('preserves cache delta fields on live durable llm_request trace events', () => {
    ensureLiveTraceSlot('alpha')

    expect(
      applyAgentCoreRuntimeEvent({
        type: 'agent_core:durable:llm_request',
        ts_unix: 300,
        correlation_id: 'corr-cache',
        run_id: 'run-cache',
        payload: {
          agent_name: 'alpha',
          model: 'gpt-5',
          input_tokens: 100,
          cache_creation_input_tokens: 10,
          cache_read_input_tokens: 20,
          cache_miss_input_tokens: 70,
        },
      }, { includeLiveTrace: true }),
    ).toBe(true)

    const detail = liveTraceFeeds.value.alpha?.[0]?.detail ?? {}
    expect(detail.cache_creation_tokens).toBe(10)
    expect(detail.cache_read_tokens).toBe(20)
    expect(detail.cache_miss_input_tokens).toBe(70)
  })

  it('dedupes a live event already present in replayed telemetry', () => {
    const liveEvent = {
      type: 'agent_core:masc:trust_updated',
      event_id: 'evt-live-replay',
      ts_unix: 123,
      correlation_id: 'corr-live',
      run_id: 'run-live',
      payload: {
        agent_a: 'beta',
        agent_b: 'gamma',
        trust_score: 0.8,
        timestamp: 123,
      },
    }

    hydrateAgentCoreRuntimeFromTelemetryEntries([
      {
        source: 'agent_core_event',
        ...liveEvent,
      } as TelemetryEntry,
    ])

    expect(applyAgentCoreRuntimeEvent(liveEvent)).toBe(false)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(1)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('hydrates keeper lifecycle phase from Agent Core payload', () => {
    hydrateAgentCoreRuntimeFromTelemetryEntries([
      {
        source: 'agent_core_event',
        type: 'agent_core:masc:keeper:lifecycle',
        ts_unix: 210,
        correlation_id: 'corr-life',
        run_id: 'run-life',
        payload: {
          keeper_name: 'keeper-a',
          event: 'started',
          phase: 'running',
          detail: 'supervised',
          timestamp: 210,
        },
      } as TelemetryEntry,
    ])

    expect(agentCoreHealthSummary.value.totalEvents).toBe(1)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(1)
    // Wire format is lowercase (backend `phase_to_string`); the factory
    // normalizes to PascalCase `KeeperPhase` for frontend consistency.
    expect(agentCoreAgentEvents.value[0]).toMatchObject({
      type: 'keeper_lifecycle',
      keeper_name: 'keeper-a',
      phase: 'Running',
      event: 'started',
      detail: 'supervised',
    })
  })

  it('hydrates runtime artifact and evidence refs from Agent Core events', () => {
    hydrateAgentCoreRuntimeFromTelemetryEntries([
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.artifact_attached',
        event_type: 'runtime.artifact_attached',
        ts_unix: 500,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          seq: 4,
          ts: 500,
          kind: [
            'Artifact_attached',
            {
              artifact_id: 'art-raw',
              name: 'runtime-raw-trace-json',
              kind: 'json',
              mime_type: 'application/json',
              path: '/tmp/runtime-raw-trace-json.json',
              size_bytes: 512,
            },
          ],
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.artifact_attached',
        event_type: 'runtime.artifact_attached',
        ts_unix: 510,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          seq: 5,
          ts: 510,
          kind: [
            'Artifact_attached',
            {
              artifact_id: 'art-evidence',
              name: 'runtime-evidence',
              kind: 'json',
              mime_type: 'application/json',
              path: '/tmp/runtime-evidence.json',
              size_bytes: 1024,
            },
          ],
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.session_completed',
        event_type: 'runtime.session_completed',
        ts_unix: 520,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          evidence: {
            files: [
              { label: 'report_json', path: '/tmp/report.json' },
              { label: 'proof_json', path: '/tmp/proof.json' },
              { label: 'telemetry_json', path: '/tmp/runtime-telemetry-json.json' },
            ],
          },
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.agent_completed',
        event_type: 'runtime.agent_completed',
        ts_unix: 530,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          kind: [
            'Agent_completed',
            {
              participant_name: 'alpha',
              raw_trace_run_id: 'raw-run-1',
            },
          ],
        },
      },
    ] as TelemetryEntry[])

    expect(agentCoreHealthSummary.value.totalEvents).toBe(4)
    expect(agentCoreHealthSummary.value.evidenceRefsCount).toBeGreaterThan(0)
    expect(agentCoreHealthSummary.value.artifactRefsCount).toBe(2)
    expect(agentCoreHealthSummary.value.rawTraceRefsCount).toBeGreaterThanOrEqual(2)
    expect(agentCoreHealthSummary.value.reportRefsCount).toBeGreaterThanOrEqual(1)
    expect(agentCoreHealthSummary.value.proofRefsCount).toBeGreaterThanOrEqual(1)
    expect(agentCoreHealthSummary.value.telemetryRefsCount).toBeGreaterThanOrEqual(1)
    expect(agentCoreHealthSummary.value.runtimeEvidenceRefsCount).toBeGreaterThanOrEqual(1)
    expect(agentCoreHealthSummary.value.lastEvidenceTs).toBe(530_000)
  })

  it('dedupes timestamp-less events across replay/live time drift', () => {
    vi.useFakeTimers()
    try {
      const driftEvent = {
        source: 'agent_core_event',
        type: 'agent_core:durable:llm_request',
        event_id: 'evt-drift',
        correlation_id: 'corr-drift',
        run_id: 'run-drift',
        payload: {
          agent_name: 'beta',
          model: 'gpt-5',
          input_tokens: 32,
        },
      } as TelemetryEntry

      vi.setSystemTime(new Date('2026-04-15T00:00:00Z'))
      hydrateAgentCoreRuntimeFromTelemetryEntries([driftEvent])

      vi.setSystemTime(new Date('2026-04-15T00:10:00Z'))
      expect(applyAgentCoreRuntimeEvent(driftEvent)).toBe(false)
      expect(agentCoreHealthSummary.value.totalEvents).toBe(1)
      expect(agentCoreHealthSummary.value.totalLlmCalls).toBe(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('preserves identical strings from distinct event identities', () => {
    const event = (eventId: string) => ({
      type: 'agent_core:masc:trust_updated',
      event_id: eventId,
      ts_unix: 600,
      correlation_id: 'corr-shared',
      run_id: 'run-shared',
      payload: {
        agent_a: 'same-agent',
        agent_b: 'same-peer',
        trust_score: 0.5,
        timestamp: 600,
      },
    })

    expect(applyAgentCoreRuntimeEvent(event('evt-distinct-a'))).toBe(true)
    expect(applyAgentCoreRuntimeEvent(event('evt-distinct-b'))).toBe(true)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(2)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('scopes a repeated producer event id to its run', () => {
    const event = (runId: string) => ({
      type: 'agent_core:masc:trust_updated',
      event_id: 'evt-process-local',
      run_id: runId,
      payload: {
        agent_a: 'same-agent',
        agent_b: 'same-peer',
        trust_score: 0.5,
      },
    })

    expect(applyAgentCoreRuntimeEvent(event('run-a'))).toBe(true)
    expect(applyAgentCoreRuntimeEvent(event('run-b'))).toBe(true)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(2)
  })

  it('preserves unidentified identical events instead of content-deduping them', () => {
    const event = {
      type: 'agent_core:masc:trust_updated',
      ts_unix: 610,
      correlation_id: 'corr-legacy',
      run_id: 'run-legacy',
      payload: {
        agent_a: 'legacy-agent',
        agent_b: 'legacy-peer',
        trust_score: 0.4,
        timestamp: 610,
      },
    }

    expect(applyAgentCoreRuntimeEvent(event)).toBe(true)
    expect(applyAgentCoreRuntimeEvent(event)).toBe(true)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(2)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('dedupes one stable run sequence across replay and live delivery', () => {
    const event = {
      type: 'agent_core:masc:trust_updated',
      run_id: 'run-sequenced',
      seq: 7,
      payload: {
        agent_a: 'sequenced-agent',
        agent_b: 'sequenced-peer',
        trust_score: 0.7,
      },
    }

    hydrateAgentCoreRuntimeFromTelemetryEntries([{ source: 'agent_core_event', ...event } as TelemetryEntry])
    expect(applyAgentCoreRuntimeEvent(event)).toBe(false)
    expect(agentCoreHealthSummary.value.totalEvents).toBe(1)
  })

  it('replays recent Agent Core telemetry via the dashboard API', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 1,
      total_matching_entries: 1200,
      truncated: true,
      entries: [
        {
          source: 'agent_core_event',
          type: 'agent_core:masc:reputation_changed',
          ts_unix: 555,
          correlation_id: 'corr-r',
          run_id: 'run-r',
          payload: {
            agent_name: 'gamma',
            old_score: 0.4,
            new_score: 0.8,
            trend: 'up',
            timestamp: 555,
          },
        } as TelemetryEntry,
      ],
    })

    await replayAgentCoreRuntimeTelemetry()

    expect(fetchTelemetryMock).toHaveBeenCalledWith({
      source: 'agent_core_event',
      n: 500,
      signal: undefined,
    })
    expect(agentCoreHealthSummary.value.totalEvents).toBe(1200)
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(1)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(1200)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(true)
    expect(agentCoreAgentEvents.value[0]?.type).toBe('reputation_changed')
  })

  it('increments total events above the replay baseline for live arrivals', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 1,
      total_matching_entries: 1200,
      truncated: true,
      entries: [
        {
          source: 'agent_core_event',
          type: 'agent_core:masc:trust_updated',
          ts_unix: 555,
          correlation_id: 'corr-baseline',
          run_id: 'run-r',
          payload: {
            agent_a: 'gamma',
            agent_b: 'delta',
            trust_score: 0.8,
            timestamp: 555,
          },
        } as TelemetryEntry,
      ],
    })

    await replayAgentCoreRuntimeTelemetry()

    expect(agentCoreHealthSummary.value.totalEvents).toBe(1200)

    expect(applyAgentCoreRuntimeEvent({
      type: 'agent_core:masc:trust_updated',
      ts_unix: 556,
      correlation_id: 'corr-live',
      run_id: 'run-live',
      payload: {
        agent_a: 'delta',
        agent_b: 'epsilon',
        trust_score: 0.8,
        timestamp: 556,
      },
    })).toBe(true)

    expect(agentCoreHealthSummary.value.totalEvents).toBe(1201)
    expect(agentCoreHealthSummary.value.agentEventsCount).toBe(2)
  })

  it('keeps loading more from retiring hasMore before the window is exhausted', async () => {
    // A replayed row sits inside the server's total-matching count. Counting
    // it again made loaded exceed total, and noteAgentCoreReplayWindow reads
    // loaded >= total as "nothing left" — so the second page silently became
    // the last one no matter how many rows the server still held.
    const entry = (seq: number): TelemetryEntry =>
      ({
        source: 'agent_core_event',
        type: 'agent_core:masc:trust_updated',
        ts_unix: 500 + seq,
        correlation_id: `corr-${seq}`,
        run_id: 'run-page',
        seq,
        payload: {
          agent_a: 'gamma',
          agent_b: 'delta',
          trust_score: 0.5,
          timestamp: 500 + seq,
        },
      }) as TelemetryEntry

    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 2,
      total_matching_entries: 1200,
      truncated: true,
      entries: [entry(1), entry(2)],
    })
    await replayAgentCoreRuntimeTelemetry()

    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(2)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(true)

    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 2,
      total_matching_entries: 1200,
      truncated: true,
      entries: [entry(3), entry(4)],
    })
    await loadMoreAgentCoreEvents()

    // Four distinct rows loaded out of 1200 — the operator must still be able
    // to ask for the rest.
    expect(agentCoreHealthSummary.value.replayLoadedEvents).toBe(4)
    expect(agentCoreHealthSummary.value.replayTotalMatchingEvents).toBe(1200)
    expect(agentCoreHealthSummary.value.replayTruncated).toBe(true)
  })
})
