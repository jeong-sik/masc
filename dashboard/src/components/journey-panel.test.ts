// @vitest-environment happy-dom
import { h } from 'preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { signal } from '@preact/signals'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

import type {
  ToolCallsResponse,
  TrajectoryResponse,
} from '../api/dashboard'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import type { Keeper } from '../types'

function trajectory(): TrajectoryResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    generation: 1,
    total_entries: 1,
    showing: 1,
    entries: [
      {
        ts: 2,
        ts_iso: '2026-05-14T00:00:02.000Z',
        turn: 1,
        round: 1,
        tool_name: 'fs_read',
        args: { path: '/tmp/old' },
        gate: { status: 'pass' },
        result: 'old result',
        duration_ms: 120,
        cost_usd: 0.002,
      },
    ],
  }
}

function toolCalls(): ToolCallsResponse {
  return {
    keeper: 'keeper-a',
    count: 1,
    entries: [
      {
        ts: 2,
        keeper: 'keeper-a',
        tool: 'fs_read',
        input: { file_path: '/tmp/current' },
        output: 'current result',
        success: true,
        duration_ms: 120,
        trace_id: 'trace-1',
        turn: 1,
      },
    ],
  }
}

function runtimeTrace(): KeeperRuntimeTraceResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    turn_id: 1,
    manifest_path: '.masc/keepers/keeper-a/runtime.jsonl',
    manifest_path_present: true,
    manifest_total_rows: 5,
    manifest_returned_rows: 5,
    receipt_returned_rows: 1,
    manifest_scan_diagnostics: {
      state: 'available',
      schema: 'keeper.runtime_manifest_scan_diagnostics.v1',
      retired_event_count: 0,
      retired_event_counts: [],
      unsupported_event_count: 0,
      unsupported_event_counts: [],
      unsupported_event_unattributed_count: 0,
      invalid_manifest_row_count: 0,
      invalid_json_row_count: 0,
      samples: [],
    },
    turn_identity: {
      requested_keeper_turn_id: 1,
      manifest_keeper_turn_ids: [1],
      receipt_turn_counts: [2],
      max_oas_turn_count: 2,
      provider_lane_resolved_count: 1,
      provider_attempt_started_count: 1,
      provider_attempt_finished_count: 1,
      checkpoint_saved_count: 1,
      event_bus_correlated_count: 1,
      memory_injected_count: 1,
      memory_flushed_count: 1,
      receipt_appended_count: 1,
      turn_finished_count: 1,
    },
    provider_attempts: {
      started_count: 1,
      finished_count: 1,
      terminal_status: 'provider_returned',
      terminal_error: null,
      terminal_exception_kind: null,
      attempts: [],
    },
    event_bus: {
      event_bus_correlated_count: 1,
      correlation_ids: ['corr-1'],
      run_ids: ['run-1'],
    },
    memory: {
      memory_injected_count: 1,
      memory_injected_present_count: 1,
      memory_flushed_count: 1,
      memory_flush_success_count: 1,
      memory_flush_error_count: 0,
      episodes_flushed: 0,
      procedures_flushed: 0,
    },
    runtime_lens: {
      turn_clock: {
        trace_id: 'trace-1',
        keeper_turn_id: 1,
        max_oas_turn_count: 2,
        terminal_event_present: true,
        terminal_event: 'turn_finished',
        manifest_total_rows: 5,
      },
      axes: {} as KeeperRuntimeTraceResponse['runtime_lens']['axes'],
      swimlanes: {} as KeeperRuntimeTraceResponse['runtime_lens']['swimlanes'],
      clock_edges: [],
      clock_groups: [],
      gaps: [],
    },
    linked_artifacts: {
      receipts: [],
      checkpoints: [],
      tool_call_logs: [],
    },
    manifest_rows: [],
    receipts: [],
    health: 'ok',
    stale_reason: null,
  }
}

async function loadJourneyPanel(keeperRows: Keeper[]) {
  vi.resetModules()
  const keeperSignal = signal<readonly Keeper[]>(keeperRows)
  const fetchKeeperTrajectory = vi.fn().mockResolvedValue(trajectory())
  const fetchKeeperToolCalls = vi.fn().mockResolvedValue(toolCalls())
  const fetchKeeperRuntimeTrace = vi.fn().mockResolvedValue(runtimeTrace())

  vi.doMock('../store', () => ({
    keepers: keeperSignal,
  }))
  vi.doMock('../api/dashboard', () => ({
    fetchKeeperTrajectory,
    fetchKeeperToolCalls,
  }))
  vi.doMock('../api/keeper', () => ({
    fetchKeeperRuntimeTrace,
  }))

  const mod = await import('./journey-panel')
  return {
    JourneyPanel: mod.JourneyPanel,
    fetchKeeperTrajectory,
    fetchKeeperToolCalls,
    fetchKeeperRuntimeTrace,
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.resetModules()
  vi.doUnmock('../store')
  vi.doUnmock('../api/dashboard')
  vi.doUnmock('../api/keeper')
})

describe('JourneyPanel', () => {
  it('renders selected keeper waterfall from existing trace APIs', async () => {
    const { JourneyPanel, fetchKeeperTrajectory, fetchKeeperToolCalls, fetchKeeperRuntimeTrace } =
      await loadJourneyPanel([
        {
          name: 'keeper-a',
          status: 'active',
          keepalive_running: true,
          turn_count: 7,
        },
      ])

    render(h(JourneyPanel, {}))

    await waitFor(() => {
      expect(screen.getByText('Keeper Turn Waterfall')).toBeInTheDocument()
      expect(screen.getByText('Turn 1')).toBeInTheDocument()
      expect(screen.getByText('fs_read')).toBeInTheDocument()
      expect(screen.getByText('agent turns 2')).toBeInTheDocument()
      expect(screen.getByText('trajectory + I/O')).toBeInTheDocument()
    })

    expect(fetchKeeperTrajectory).toHaveBeenCalledWith('keeper-a', 200, true, true)
    expect(fetchKeeperToolCalls).toHaveBeenCalledWith('keeper-a', 200, expect.objectContaining({
      signal: expect.any(AbortSignal),
    }))
    expect(fetchKeeperRuntimeTrace).toHaveBeenCalledWith('keeper-a', expect.objectContaining({
      limit: 200,
      signal: expect.any(AbortSignal),
    }))
  })
})
