import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./api/dashboard', () => ({
  fetchTelemetry: vi.fn(),
}))

import { fetchTelemetry, type TelemetryEntry } from './api/dashboard'
import {
  applyOasRuntimeEvent,
  hydrateOasRuntimeFromTelemetryEntries,
  replayOasRuntimeTelemetry,
} from './oas-runtime-store'
import {
  oasAgentEvents,
  oasHealthSummary,
  oasKeeperSnapshots,
} from './store'
import {
  ensureLiveTraceSlot,
  liveTraceFeeds,
} from './components/session-trace/session-trace-live-store'

const fetchTelemetryMock = vi.mocked(fetchTelemetry)

function resetRuntimeState() {
  hydrateOasRuntimeFromTelemetryEntries([])
  liveTraceFeeds.value = {}
}

describe('oas-runtime-store', () => {
  beforeEach(() => {
    fetchTelemetryMock.mockReset()
    resetRuntimeState()
  })

  it('hydrates durable telemetry into one OAS runtime summary', () => {
    const entries: TelemetryEntry[] = [
      {
        source: 'oas_event',
        type: 'oas:durable:error_occurred',
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
        source: 'oas_event',
        type: 'oas:durable:llm_request',
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
        source: 'oas_event',
        type: 'oas:masc:keeper:snapshot',
        ts_unix: 200,
        correlation_id: 'corr-2',
        run_id: 'run-1',
        payload: {
          keeper_name: 'keeper-a',
          generation: 3,
          context_ratio: 0.42,
          message_count: 9,
          timestamp: 200,
        },
      },
      {
        source: 'oas_event',
        type: 'oas:masc:autonomy:agent_selected',
        ts_unix: 100,
        correlation_id: 'corr-1',
        run_id: 'run-1',
        payload: {
          agent_name: 'alpha',
          trigger: 'thompson',
          timestamp: 100,
        },
      },
    ] as TelemetryEntry[]

    hydrateOasRuntimeFromTelemetryEntries(entries)

    expect(oasHealthSummary.value.totalEvents).toBe(4)
    expect(oasHealthSummary.value.replayLoadedEvents).toBe(4)
    expect(oasHealthSummary.value.replayTotalMatchingEvents).toBe(4)
    expect(oasHealthSummary.value.replayTruncated).toBe(false)
    expect(oasHealthSummary.value.agentEventsCount).toBe(1)
    expect(oasHealthSummary.value.keeperSnapshotsCount).toBe(1)
    expect(oasHealthSummary.value.totalLlmCalls).toBe(1)
    expect(oasHealthSummary.value.totalErrors).toBe(1)
    expect(oasHealthSummary.value.lastKeeperTick).toBe(200_000)
    expect(oasHealthSummary.value.lastLlmCallTs).toBe(300_000)
    expect(oasHealthSummary.value.lastErrorTs).toBe(400_000)
    expect(oasAgentEvents.value[0]?.agent_name).toBe('alpha')
    expect(oasKeeperSnapshots.value.get('keeper-a')?.generation).toBe(3)
  })

  it('preserves cache delta fields on live durable llm_request trace events', () => {
    ensureLiveTraceSlot('alpha')

    expect(
      applyOasRuntimeEvent({
        type: 'oas:durable:llm_request',
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
      type: 'oas:masc:autonomy:agent_selected',
      ts_unix: 123,
      correlation_id: 'corr-live',
      run_id: 'run-live',
      payload: {
        agent_name: 'beta',
        trigger: 'thompson',
        timestamp: 123,
      },
    }

    hydrateOasRuntimeFromTelemetryEntries([
      {
        source: 'oas_event',
        ...liveEvent,
      } as TelemetryEntry,
    ])

    expect(applyOasRuntimeEvent(liveEvent)).toBe(false)
    expect(oasHealthSummary.value.totalEvents).toBe(1)
    expect(oasHealthSummary.value.agentEventsCount).toBe(1)
  })

  it('hydrates keeper lifecycle phase from OAS payload', () => {
    hydrateOasRuntimeFromTelemetryEntries([
      {
        source: 'oas_event',
        type: 'oas:masc:keeper:lifecycle',
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

    expect(oasHealthSummary.value.totalEvents).toBe(1)
    expect(oasHealthSummary.value.agentEventsCount).toBe(1)
    // Wire format is lowercase (backend `phase_to_string`); the factory
    // normalizes to PascalCase `KeeperPhase` for frontend consistency.
    expect(oasAgentEvents.value[0]).toMatchObject({
      type: 'keeper_lifecycle',
      keeper_name: 'keeper-a',
      phase: 'Running',
      event: 'started',
      detail: 'supervised',
    })
  })

  it('hydrates runtime artifact and evidence refs from OAS events', () => {
    hydrateOasRuntimeFromTelemetryEntries([
      {
        source: 'oas_event',
        type: 'oas:runtime.artifact_attached',
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
        source: 'oas_event',
        type: 'oas:runtime.artifact_attached',
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
        source: 'oas_event',
        type: 'oas:runtime.session_completed',
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
        source: 'oas_event',
        type: 'oas:runtime.agent_completed',
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

    expect(oasHealthSummary.value.totalEvents).toBe(4)
    expect(oasHealthSummary.value.evidenceRefsCount).toBeGreaterThan(0)
    expect(oasHealthSummary.value.artifactRefsCount).toBe(2)
    expect(oasHealthSummary.value.rawTraceRefsCount).toBeGreaterThanOrEqual(2)
    expect(oasHealthSummary.value.reportRefsCount).toBeGreaterThanOrEqual(1)
    expect(oasHealthSummary.value.proofRefsCount).toBeGreaterThanOrEqual(1)
    expect(oasHealthSummary.value.telemetryRefsCount).toBeGreaterThanOrEqual(1)
    expect(oasHealthSummary.value.runtimeEvidenceRefsCount).toBeGreaterThanOrEqual(1)
    expect(oasHealthSummary.value.lastEvidenceTs).toBe(530_000)
  })

  it('dedupes timestamp-less events across replay/live time drift', () => {
    vi.useFakeTimers()
    try {
      const driftEvent = {
        source: 'oas_event',
        type: 'oas:durable:llm_request',
        correlation_id: 'corr-drift',
        run_id: 'run-drift',
        payload: {
          agent_name: 'beta',
          model: 'gpt-5',
          input_tokens: 32,
        },
      } as TelemetryEntry

      vi.setSystemTime(new Date('2026-04-15T00:00:00Z'))
      hydrateOasRuntimeFromTelemetryEntries([driftEvent])

      vi.setSystemTime(new Date('2026-04-15T00:10:00Z'))
      expect(applyOasRuntimeEvent(driftEvent)).toBe(false)
      expect(oasHealthSummary.value.totalEvents).toBe(1)
      expect(oasHealthSummary.value.totalLlmCalls).toBe(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('replays recent OAS telemetry via the dashboard API', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 1,
      total_matching_entries: 1200,
      truncated: true,
      entries: [
        {
          source: 'oas_event',
          type: 'oas:masc:reputation_changed',
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

    await replayOasRuntimeTelemetry()

    expect(fetchTelemetryMock).toHaveBeenCalledWith({
      source: 'oas_event',
      n: 500,
      signal: undefined,
    })
    expect(oasHealthSummary.value.totalEvents).toBe(1200)
    expect(oasHealthSummary.value.replayLoadedEvents).toBe(1)
    expect(oasHealthSummary.value.replayTotalMatchingEvents).toBe(1200)
    expect(oasHealthSummary.value.replayTruncated).toBe(true)
    expect(oasAgentEvents.value[0]?.type).toBe('reputation_changed')
  })

  it('increments total events above the replay baseline for live arrivals', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 1,
      total_matching_entries: 1200,
      truncated: true,
      entries: [
        {
          source: 'oas_event',
          type: 'oas:masc:autonomy:agent_selected',
          ts_unix: 555,
          correlation_id: 'corr-baseline',
          run_id: 'run-r',
          payload: {
            agent_name: 'gamma',
            trigger: 'thompson',
            timestamp: 555,
          },
        } as TelemetryEntry,
      ],
    })

    await replayOasRuntimeTelemetry()

    expect(oasHealthSummary.value.totalEvents).toBe(1200)

    expect(applyOasRuntimeEvent({
      type: 'oas:masc:autonomy:agent_selected',
      ts_unix: 556,
      correlation_id: 'corr-live',
      run_id: 'run-live',
      payload: {
        agent_name: 'delta',
        trigger: 'thompson',
        timestamp: 556,
      },
    })).toBe(true)

    expect(oasHealthSummary.value.totalEvents).toBe(1201)
    expect(oasHealthSummary.value.agentEventsCount).toBe(2)
  })
})
