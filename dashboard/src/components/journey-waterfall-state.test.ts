import { describe, expect, it } from 'vitest'

import type {
  ToolCallsResponse,
  TrajectoryEntry,
  TrajectoryResponse,
} from '../api/dashboard'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import type { Keeper } from '../types'
import {
  buildJourneyWaterfall,
  selectDefaultJourneyKeeper,
} from './journey-waterfall-state'

function trajectory(entries: TrajectoryEntry[]): TrajectoryResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    generation: 1,
    total_entries: entries.length,
    showing: entries.length,
    entries,
  }
}

function toolCalls(entries: ToolCallsResponse['entries']): ToolCallsResponse {
  return {
    keeper: 'keeper-a',
    count: entries.length,
    entries,
  }
}

function runtimeTrace(overrides: Partial<KeeperRuntimeTraceResponse> = {}): KeeperRuntimeTraceResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    turn_id: 2,
    manifest_path: '.masc/keepers/keeper-a/runtime.jsonl',
    manifest_path_present: true,
    manifest_total_rows: 10,
    manifest_returned_rows: 10,
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
      requested_keeper_turn_id: 2,
      manifest_keeper_turn_ids: [2],
      receipt_turn_counts: [4],
      max_oas_turn_count: 4,
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
      context_compact_started_count: 1,
      context_compacted_count: 1,
      last_compaction: null,
    },
    memory: {
      memory_injected_count: 1,
      memory_injected_present_count: 1,
      memory_flushed_count: 1,
      memory_flush_success_count: 1,
      memory_flush_error_count: 0,
      episodes_flushed: 1,
      procedures_flushed: 0,
    },
    runtime_lens: {
      turn_clock: {
        trace_id: 'trace-1',
        keeper_turn_id: 2,
        max_oas_turn_count: 4,
        terminal_event_present: true,
        terminal_event: 'turn_finished',
        manifest_total_rows: 10,
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
    ...overrides,
  }
}

describe('buildJourneyWaterfall', () => {
  it('groups thinking and enriched tool calls by keeper turn', () => {
    const model = buildJourneyWaterfall({
      keeper: 'keeper-a',
      trajectory: trajectory([
        {
          type: 'thinking',
          ts: 1,
          ts_iso: '2026-05-14T00:00:01.000Z',
          turn: 2,
          content: 'Need to inspect the file.',
          content_length: 25,
          redacted: false,
        },
        {
          ts: 2,
          ts_iso: '2026-05-14T00:00:02.000Z',
          turn: 2,
          round: 1,
          tool_name: 'fs_read',
          args: { path: '/tmp/old' },
          gate: { status: 'pass' },
          result: 'old result',
          duration_ms: 250,
          cost_usd: 0.001,
        },
      ]),
      toolCalls: toolCalls([
        {
          ts: 2,
          keeper: 'keeper-a',
          tool: 'fs_read',
          input: { file_path: '/tmp/current' },
          output: 'current result',
          success: true,
          duration_ms: 250,
          trace_id: 'trace-1',
          turn: 2,
        },
      ]),
      runtimeTrace: runtimeTrace(),
    })

    expect(model.turns).toHaveLength(1)
    expect(model.turns[0]?.turn).toBe(2)
    expect(model.turns[0]?.thinkingCount).toBe(1)
    expect(model.turns[0]?.toolCallCount).toBe(1)
    expect(model.turns[0]?.runtimeEvidence?.maxOasTurnCount).toBe(4)
    expect(model.summary.totalCostUsd).toBe(0.001)
    const toolEntry = model.turns[0]?.entries.find(entry => entry.kind === 'tool_call')
    expect(toolEntry?.source).toBe('trajectory+tool_call_log')
    expect(toolEntry?.toolArgs).toEqual({ file_path: '/tmp/current' })
    expect(toolEntry?.toolResult).toBe('current result')
  })

  it('keeps tool-call-log rows when trajectory is missing', () => {
    const model = buildJourneyWaterfall({
      keeper: 'keeper-a',
      trajectory: null,
      toolCalls: toolCalls([
        {
          ts: 3,
          keeper: 'keeper-a',
          tool: 'masc_status',
          input: {},
          output: 'ok',
          success: true,
          duration_ms: 10,
          trace_id: 'trace-1',
          keeper_turn_id: 5,
        },
      ]),
      runtimeTrace: null,
    })

    expect(model.turns).toHaveLength(1)
    expect(model.turns[0]?.turn).toBe(5)
    expect(model.turns[0]?.entries[0]?.source).toBe('tool_call_log')
    expect(model.turns[0]?.runtimeEvidence).toBeNull()
  })

  it('does not attach runtime evidence to the wrong turn', () => {
    const model = buildJourneyWaterfall({
      keeper: 'keeper-a',
      trajectory: trajectory([
        {
          ts: 2,
          ts_iso: '2026-05-14T00:00:02.000Z',
          turn: 9,
          round: 1,
          tool_name: 'fs_read',
          args: {},
          gate: { status: 'reject', reason: 'policy' },
          result: null,
          duration_ms: 0,
          error: 'rejected',
        },
      ]),
      toolCalls: null,
      runtimeTrace: runtimeTrace(),
    })

    expect(model.turns[0]?.turn).toBe(9)
    expect(model.turns[0]?.gateRejectedCount).toBe(1)
    expect(model.turns[0]?.runtimeEvidence).toBeNull()
    expect(model.summary.runtimeEvidence?.keeperTurnId).toBe(2)
  })
})

describe('selectDefaultJourneyKeeper', () => {
  it('preserves a valid current keeper selection', () => {
    const rows: Keeper[] = [
      { name: 'bravo', status: 'offline' },
      { name: 'alpha', status: 'active', keepalive_running: true },
    ]

    expect(selectDefaultJourneyKeeper(rows, 'bravo')).toBe('bravo')
  })

  it('selects the most active keeper when no current selection exists', () => {
    const rows: Keeper[] = [
      { name: 'offline', status: 'offline', last_turn_ago_s: 1 },
      { name: 'fresh', status: 'active', keepalive_running: true, last_turn_ago_s: 20 },
      { name: 'older', status: 'active', keepalive_running: true, last_turn_ago_s: 120 },
    ]

    expect(selectDefaultJourneyKeeper(rows)).toBe('fresh')
  })
})
