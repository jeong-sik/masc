import { describe, expect, it } from 'vitest'

import {
  normalizeDashboardRuntimeResolution,
  normalizeExecutionQueueItem,
  normalizeExecutionSessionBrief,
  normalizeMessage,
} from './store-normalizers'

const configItem = { path: '/tmp/masc', source: 'test', exists: true }
const build = {
  release_version: 'dev',
  started_at: '2026-05-17T00:00:00Z',
  uptime_seconds: 12,
}

function runtimeResolutionRaw(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    status: 'ready',
    warnings: [],
    base_path: configItem,
    workspace_path: configItem,
    resolved_base_path: configItem,
    data_root: configItem,
    prompt_markdown_dir: configItem,
    build,
    ...overrides,
  }
}

describe('normalizeExecutionSessionBrief', () => {
  it('promotes legacy room-only payloads to namespace while keeping the room alias', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-1',
      goal: 'legacy payload',
      room: 'default',
    })).toMatchObject({
      session_id: 'session-1',
      goal: 'legacy payload',
      namespace: 'default',
      room: 'default',
    })
  })

  it('keeps namespace-only payloads canonical and mirrors the room alias', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
    })).toMatchObject({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
      room: 'default',
    })
  })

  it('prefers namespace when both fields are present during rollout', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
      room: 'legacy-room',
    })).toMatchObject({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
      room: 'default',
    })
  })
})

describe('normalizeExecutionQueueItem', () => {
  it('accepts keeper stopped-reaction items with runtime trust', () => {
    expect(normalizeExecutionQueueItem({
      id: 'keeper-sangsu',
      kind: 'keeper',
      severity: 'bad',
      status: 'paused',
      summary: 'required keeper tool use was not satisfied',
      target_type: 'keeper',
      target_id: 'sangsu',
      attention_reason: 'required_tool_use_unsatisfied',
      next_human_action: 'inspect_provider_tool_contract',
      terminal_reason_code: 'required_tool_use_unsatisfied',
      runtime_trust: {
        needs_attention: true,
        latest_terminal_reason: {
          code: 'required_tool_use_unsatisfied',
          severity: 'bad',
        },
      },
    })).toMatchObject({
      id: 'keeper-sangsu',
      kind: 'keeper',
      terminal_reason_code: 'required_tool_use_unsatisfied',
      stop_cause: {
        code: 'required_tool_use_unsatisfied',
        source: 'terminal_reason_code',
      },
      runtime_trust: {
        needs_attention: true,
        latest_terminal_reason: {
          code: 'required_tool_use_unsatisfied',
          severity: 'bad',
        },
      },
    })
  })

  it('normalizes runtime blockers into execution row stop_cause before attention fallback', () => {
    expect(normalizeExecutionQueueItem({
      id: 'keeper-sangsu',
      kind: 'keeper',
      severity: 'bad',
      status: 'blocked',
      summary: 'keeper turn is blocked',
      target_type: 'keeper',
      target_id: 'sangsu',
      runtime_blocker_class: 'no_tool_capable_provider',
      runtime_blocker_summary: 'no provider can satisfy required tools',
      attention_reason: 'tool_contract_failed',
    })).toMatchObject({
      stop_cause: {
        code: 'no_tool_capable_provider',
        source: 'runtime_blocker_class',
        summary: 'no provider can satisfy required tools',
      },
    })
  })
})

describe('normalizeMessage', () => {
  it('preserves room metadata for board message room timelines', () => {
    expect(normalizeMessage({
      id: 'm-1',
      from_agent: 'sangsu',
      content: 'handoff ready',
      room_id: 'keeper-room',
    })).toMatchObject({
      id: 'm-1',
      from: 'sangsu',
      content: 'handoff ready',
      room: 'keeper-room',
    })
  })
})

describe('normalizeDashboardRuntimeResolution fleet safety', () => {
  it('keeps old runtime payloads compatible when fleet safety fields are absent', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw())

    expect(result?.fleet_safety).toBeNull()
  })

  it('parses optional health fleet-safety fields type-safely', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_fibers: 1,
      paused_keepers: 3,
      keeper_fleet_no_fibers: false,
      keeper_fd_pressure: {
        status: 'blocked',
        reason: 'fd_pressure',
        admission_blocked: true,
        admission_blocked_keepers: 24,
      },
      keeper_fleet_safety: {
        status: 'blocked',
        blocker: 'no_running_fibers',
        bootable_keeper_count: 1,
        running_keeper_fiber_count: 0,
        healthy_running_keeper_fiber_count: 0,
        failing_keeper_fiber_count: 0,
        executable_keeper_fiber_count: 0,
        minimum_running_fibers: 1,
        no_running_fibers: true,
        no_executable_keeper_fibers: true,
        low_running_fiber_margin: false,
        reaction_capacity_below_target: true,
        reaction_capacity_shortfall_count: 14,
        executable_reaction_capacity_below_target: true,
        executable_reaction_capacity_shortfall_count: 14,
        paused_keeper_count: 13,
        autoboot_enabled_keeper_count: 14,
        paused_autoboot_enabled_keeper_count: 13,
        effective_reaction_capacity_count: 0,
        executable_reaction_capacity_count: 0,
        target_reaction_capacity_count: 14,
        operator_action_required: true,
        blocked_keepers: 24,
      },
      keeper_reaction_ledger: {
        status: 'ok',
        operator_action_required: false,
        keeper_count: 2,
        row_count: 8,
        stimulus_count: 4,
        reaction_count: 4,
        cursor_ack_count: 2,
        cursor_swept_stimulus_count: 3,
        legacy_cursor_swept_stimulus_count: 1,
        pending_stimulus_count: 0,
        read_error_count: 0,
        pending_by_keeper: [],
      },
    }))

    expect(result?.fleet_safety).toMatchObject({
      keeper_fibers: 1,
      paused_keepers: 3,
      keeper_fleet_no_fibers: false,
      keeper_fd_pressure: {
        status: 'blocked',
        reason: 'fd_pressure',
        admission_blocked: true,
        admission_blocked_keepers: 24,
      },
      keeper_fleet_safety: {
        status: 'blocked',
        blocker: 'no_running_fibers',
        bootable_keeper_count: 1,
        running_keeper_fiber_count: 0,
        healthy_running_keeper_fiber_count: 0,
        failing_keeper_fiber_count: 0,
        executable_keeper_fiber_count: 0,
        minimum_running_fibers: 1,
        no_running_fibers: true,
        no_executable_keeper_fibers: true,
        low_running_fiber_margin: false,
        reaction_capacity_below_target: true,
        reaction_capacity_shortfall_count: 14,
        executable_reaction_capacity_below_target: true,
        executable_reaction_capacity_shortfall_count: 14,
        paused_keeper_count: 13,
        autoboot_enabled_keeper_count: 14,
        paused_autoboot_enabled_keeper_count: 13,
        effective_reaction_capacity_count: 0,
        executable_reaction_capacity_count: 0,
        target_reaction_capacity_count: 14,
        operator_action_required: true,
        blocked_keepers: 24,
      },
      keeper_reaction_ledger: {
        status: 'ok',
        cursor_ack_count: 2,
        cursor_swept_stimulus_count: 3,
        legacy_cursor_swept_stimulus_count: 1,
        pending_stimulus_count: 0,
        read_error_count: 0,
      },
    })
  })

  it('keeps reaction-ledger health even when other fleet safety fields are absent', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_reaction_ledger: {
        status: 'degraded',
        operator_action_required: true,
        pending_stimulus_count: 2,
        cursor_swept_stimulus_count: 5,
        legacy_cursor_swept_stimulus_count: 1,
        pending_by_keeper: [{
          keeper_name: 'keeper-a',
          pending_stimulus_count: 2,
          pending_stimulus_ids: ['p-1', 'p-2'],
        }],
      },
    }))

    expect(result?.fleet_safety).toMatchObject({
      keeper_fibers: null,
      keeper_reaction_ledger: {
        status: 'degraded',
        operator_action_required: true,
        pending_stimulus_count: 2,
        cursor_swept_stimulus_count: 5,
        legacy_cursor_swept_stimulus_count: 1,
        pending_by_keeper: [{
          keeper_name: 'keeper-a',
          pending_stimulus_count: 2,
          pending_stimulus_ids: ['p-1', 'p-2'],
        }],
      },
    })
  })
})
