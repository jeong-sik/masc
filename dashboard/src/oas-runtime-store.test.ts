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

const fetchTelemetryMock = vi.mocked(fetchTelemetry)

function resetRuntimeState() {
  hydrateOasRuntimeFromTelemetryEntries([])
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
    expect(oasAgentEvents.value[0]).toMatchObject({
      type: 'keeper_lifecycle',
      keeper_name: 'keeper-a',
      phase: 'running',
      event: 'started',
      detail: 'supervised',
    })
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
    expect(oasHealthSummary.value.totalEvents).toBe(1)
    expect(oasAgentEvents.value[0]?.type).toBe('reputation_changed')
  })
})
