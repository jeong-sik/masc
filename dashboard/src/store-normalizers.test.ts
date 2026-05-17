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
      runtime_trust: {
        needs_attention: true,
        latest_terminal_reason: {
          code: 'required_tool_use_unsatisfied',
          severity: 'bad',
        },
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
        blocked_keepers: 24,
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
        blocked_keepers: 24,
      },
    })
  })
})
