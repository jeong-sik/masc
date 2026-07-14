import { describe, expect, it } from 'vitest'

import {
  mergeMessages,
  normalizeDashboardRuntimeResolution,
  normalizeExecutionQueueItem,
  normalizeExecutionSessionBrief,
  normalizeMessage,
  normalizeTask,
  normalizeTaskStatus,
} from './store-normalizers'
import type { Message } from './types'

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

function message(overrides: Partial<Message> = {}): Message {
  return {
    id: 'm-1',
    seq: 1,
    from: 'sangsu',
    content: 'ready',
    timestamp: '2026-05-17T00:00:00Z',
    type: 'status',
    workspace: 'default',
    ...overrides,
  }
}

describe('normalizeExecutionSessionBrief', () => {
  it('does not promote retired workspace-only payloads to namespace', () => {
    const normalized = normalizeExecutionSessionBrief({
      session_id: 'session-1',
      goal: 'legacy payload',
      workspace: 'default',
    })
    expect(normalized).toMatchObject({
      session_id: 'session-1',
      goal: 'legacy payload',
      namespace: null,
    })
    expect(Object.prototype.hasOwnProperty.call(normalized ?? {}, 'workspace')).toBe(false)
  })

  it('keeps namespace-only payloads canonical without a workspace alias', () => {
    const normalized = normalizeExecutionSessionBrief({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
    })
    expect(Object.prototype.hasOwnProperty.call(normalized ?? {}, 'workspace')).toBe(false)
    expect(normalized).toMatchObject({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
    })
  })

  it('ignores retired workspace when namespace is present', () => {
    const normalized = normalizeExecutionSessionBrief({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
      workspace: 'legacy-workspace',
    })
    expect(normalized).toMatchObject({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
    })
    expect(Object.prototype.hasOwnProperty.call(normalized ?? {}, 'workspace')).toBe(false)
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
      runtime_blocker_class: 'runtime_exhausted',
      runtime_blocker_summary: 'no provider can satisfy tool surface',
      attention_reason: 'tool_contract_failed',
    })).toMatchObject({
      stop_cause: {
        code: 'runtime_exhausted',
        source: 'runtime_blocker_class',
        summary: 'no provider can satisfy tool surface',
      },
    })
  })
})

describe('normalizeTaskStatus', () => {
  it('keeps Goal Store vocabulary out of the generic execution-task normalizer', () => {
    expect(normalizeTaskStatus('completed')).toBeUndefined()
    expect(normalizeTaskStatus('pending')).toBeUndefined()
  })

  it('normalizes canonical execution task statuses', () => {
    expect(normalizeTask({
      id: 'task-1',
      title: 'Execution task',
      status: 'done',
    })).toMatchObject({
      id: 'task-1',
      status: 'done',
    })
  })

  it('preserves task gate snapshots from execution task payloads', () => {
    expect(normalizeTask({
      id: 'task-gate',
      title: 'Execution task with gate',
      status: 'awaiting_verification',
      gate: {
        strict: true,
        completion_contract: ['unit tests pass'],
        unmet_completion_contract: ['manual approval'],
        done: {
          status: 'blocked',
          checks: [
            { evidence: 'unit tests pass', outcome: 'satisfied', detail: 'vitest green' },
            { evidence: 'manual approval', outcome: 'missing', detail: 'operator pending' },
          ],
          reasons: ['operator approval pending'],
        },
        inspect_to_implement: {
          status: 'inconclusive',
          checks: [
            { evidence: 'diff review', outcome: 'unsupported', detail: 'not collected' },
          ],
        },
        verify_to_review: {
          status: 'not-a-known-status',
          reasons: ['backend drift fixture'],
        },
      },
    })).toMatchObject({
      gate: {
        strict: true,
        completion_contract: ['unit tests pass'],
        unmet_completion_contract: ['manual approval'],
        done: {
          status: 'blocked',
          checks: [
            { evidence: 'unit tests pass', outcome: 'satisfied', detail: 'vitest green' },
            { evidence: 'manual approval', outcome: 'missing', detail: 'operator pending' },
          ],
          reasons: ['operator approval pending'],
        },
        inspect_to_implement: {
          status: 'inconclusive',
          checks: [
            { evidence: 'diff review', outcome: 'unsupported', detail: 'not collected' },
          ],
        },
        verify_to_review: {
          status: 'unknown',
          status_raw: 'not-a-known-status',
          reasons: ['unknown gate status: not-a-known-status', 'backend drift fixture'],
        },
      },
    })
  })
})

describe('normalizeMessage', () => {
  it('preserves workspace metadata for board message workspace timelines', () => {
    expect(normalizeMessage({
      id: 'm-1',
      from_agent: 'sangsu',
      content: 'handoff ready',
      workspace_id: 'keeper-workspace',
    })).toMatchObject({
      id: 'm-1',
      from: 'sangsu',
      content: 'handoff ready',
      workspace: 'keeper-workspace',
    })
  })
})

describe('mergeMessages', () => {
  it('reuses the current array and message references for repeated snapshots', () => {
    const current = [
      message(),
      message({
        id: 'm-2',
        seq: 2,
        from: 'codex',
        content: 'done',
        timestamp: '2026-05-17T00:00:01Z',
      }),
    ]

    const merged = mergeMessages(current, [
      message(),
      message({
        id: 'm-2',
        seq: 2,
        from: 'codex',
        content: 'done',
        timestamp: '2026-05-17T00:00:01Z',
      }),
    ])

    expect(merged).toBe(current)
    expect(merged[0]).toBe(current[0])
    expect(merged[1]).toBe(current[1])
  })

  it('updates a same-key message when any rendered field changes', () => {
    const current = [message()]
    const changed = message({ content: 'blocked' })

    const merged = mergeMessages(current, [changed])

    expect(merged).not.toBe(current)
    expect(merged).toEqual([changed])
    expect(merged[0]).toBe(changed)
  })

  it('replaces a seq-only message when the next snapshot adds an id', () => {
    const current = [message({ id: undefined, seq: 7 })]
    const incoming = message({ id: 'm-7', seq: 7 })

    const merged = mergeMessages(current, [incoming])

    expect(merged).toEqual([incoming])
    expect(merged[0]).toBe(incoming)
  })

  it('keeps fallback messages distinct when type or workspace differs', () => {
    const current = [
      message({ id: undefined, seq: undefined, type: 'status', workspace: 'main' }),
    ]
    const incoming = message({
      id: undefined,
      seq: undefined,
      type: 'event',
      workspace: 'sidecar',
    })

    const merged = mergeMessages(current, [incoming])

    expect(merged).toHaveLength(2)
    expect(merged).toContain(current[0])
    expect(merged).toContain(incoming)
  })
})

describe('normalizeDashboardRuntimeResolution fleet safety', () => {
  it('projects only the active stream and body timeout fields', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_runtime: {
        stream_idle_timeout_sec: { value: 75, source: 'toml' },
        body_timeout_override_sec: { value: null, source: 'default' },
      },
    }))

    expect(result?.keeper_runtime).toEqual({
      stream_idle_timeout_sec: { value: 75, source: 'toml' },
      body_timeout_override_sec: { value: null, source: 'default' },
    })
  })

  it('projects an unset stream idle timeout as explicitly disabled', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_runtime: {
        stream_idle_timeout_sec: { value: null, source: 'default' },
        body_timeout_override_sec: { value: null, source: 'default' },
      },
    }))

    expect(result?.keeper_runtime?.stream_idle_timeout_sec).toEqual({
      value: null,
      source: 'default',
    })
  })

  it('rejects unknown keeper runtime sources instead of coercing them', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_runtime: {
        stream_idle_timeout_sec: { value: null, source: 'compatibility' },
        body_timeout_override_sec: { value: null, source: 'default' },
      },
    }))

    expect(result?.keeper_runtime).toBeNull()
  })

  it('rejects a missing stream idle value instead of treating it as disabled', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_runtime: {
        stream_idle_timeout_sec: { source: 'default' },
        body_timeout_override_sec: { value: null, source: 'default' },
      },
    }))

    expect(result?.keeper_runtime).toBeNull()
  })

  it('rejects a non-positive stream idle value instead of clamping it', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_runtime: {
        stream_idle_timeout_sec: { value: 0, source: 'toml' },
        body_timeout_override_sec: { value: null, source: 'default' },
      },
    }))

    expect(result?.keeper_runtime).toBeNull()
  })

  it('keeps old runtime payloads compatible when fleet safety fields are absent', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw())

    expect(result?.fleet_safety).toBeNull()
    expect(result?.fd_accountant).toBeNull()
  })

  it('parses FD accountant facts for the runtime truth panel', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      fd_accountant: {
        fd_open: 42,
        fd_limit: 1024,
        per_kind: [{ kind: 'provider_http', active_operations: 3 }],
        resource_errors: [{ kind: 'provider_http', error: 'process_fd_exhausted', count: 2 }],
      },
    }))

    expect(result?.fd_accountant).toEqual({
      fd_open: 42,
      fd_limit: 1024,
      per_kind: [{ kind: 'provider_http', active_operations: 3 }],
      resource_errors: [{ kind: 'provider_http', error: 'process_fd_exhausted', count: 2 }],
    })
  })

  it('parses observation-only disk facts without deriving a gate', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      disk_observation: {
        mode: 'observation_only',
        masc_root: '/tmp/workspace/.masc',
        storage_space_exhaustion_observations_total: 2,
        last_storage_space_exhaustion_ts: 1234.5,
        filesystem: {
          path: '/tmp/workspace/.masc',
          filesystem: '/dev/disk3s1',
          mounted_on: '/System/Volumes/Data',
          total_bytes: 1000,
          used_bytes: 400,
          available_bytes: 600,
          capacity_percent: 40,
          available_percent: 60,
        },
      },
    }))

    expect(result?.disk_observation).toEqual({
      mode: 'observation_only',
      masc_root: '/tmp/workspace/.masc',
      storage_space_exhaustion_observations_total: 2,
      last_storage_space_exhaustion_ts: 1234.5,
      filesystem: {
        path: '/tmp/workspace/.masc',
        filesystem: '/dev/disk3s1',
        mounted_on: '/System/Volumes/Data',
        total_bytes: 1000,
        used_bytes: 400,
        available_bytes: 600,
        capacity_percent: 40,
        available_percent: 60,
        error: null,
      },
    })
  })

  it('parses optional health fleet-safety fields type-safely', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      keeper_fibers: 1,
      paused_keepers: 3,
      paused_keepers_health: {
        count: 3,
        names: ['analyst', 'base', 'sangsu'],
        running_count: 0,
        running_names: [],
        durable_count: 3,
        durable_names: ['analyst', 'base', 'sangsu'],
        autoboot_enabled_count: 3,
        autoboot_enabled_names: ['analyst', 'base', 'sangsu'],
        details: [{
          name: 'analyst',
          autoboot_enabled: true,
          pause_kind: 'operator_paused',
          paused_elapsed_sec: 12,
          last_blocker: {
            klass: 'turn_timeout',
            detail: 'turn exceeded budget',
          },
          missing_pause_root_cause: false,
        }],
        read_error_count: 0,
        read_errors: [],
      },
      keeper_fleet_no_fibers: false,
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
      paused_keepers_health: {
        count: 3,
        names: ['analyst', 'base', 'sangsu'],
        details: [{
          name: 'analyst',
          pause_kind: 'operator_paused',
          last_blocker: {
            klass: 'turn_timeout',
          },
        }],
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

  it('parses contract proof and task-scope blocker fields', () => {
    const result = normalizeDashboardRuntimeResolution(runtimeResolutionRaw({
      cdal: {
        writer_status: 'proof_store_incomplete',
        operator_action_required: true,
        proof_store_path_drift: false,
        proof_store: {
          root: '/Users/dancer/me/.oas',
          proofs_dir: '/Users/dancer/me/.oas/proofs',
          exists: true,
          latest_activity_at: '2026-05-21T03:00:00Z',
          latest_activity_unix: 1779332400,
          age_seconds: 30,
          status: 'stale_incomplete_runs',
          completeness: {
            scan_limit: 200,
            run_dir_entries_seen: 200,
            scan_truncated: false,
            run_dirs_scanned: 200,
            completed_run_dirs: 194,
            incomplete_run_dirs: 6,
            stale_incomplete_run_dirs: 3,
            terminal_incomplete_run_dirs: 1,
            missing_manifest_run_dirs: 6,
            missing_contract_run_dirs: 6,
            stale_incomplete_grace_seconds: 300,
            sample_stale_incomplete_run_ids: ['contract-stale-a'],
            sample_terminal_incomplete_run_ids: ['contract-abort-a'],
          },
        },
        task_scope: {
          status: 'partial_task_scope',
          recent_limit: 500,
          recent_rows: 500,
          task_id_rows: 225,
          missing_task_scope_rows: 275,
          legacy_unscoped_rows: 270,
          current_writer_missing_task_scope_rows: 5,
          missing_task_scope: true,
          partial_task_scope: true,
          current_writer_missing_task_scope: true,
        },
      },
    }))

    expect(result?.cdal).toMatchObject({
      writer_status: 'proof_store_incomplete',
      operator_action_required: true,
      proof_store: {
        status: 'stale_incomplete_runs',
        completeness: {
          incomplete_run_dirs: 6,
          stale_incomplete_run_dirs: 3,
          terminal_incomplete_run_dirs: 1,
          sample_stale_incomplete_run_ids: ['contract-stale-a'],
          sample_terminal_incomplete_run_ids: ['contract-abort-a'],
        },
      },
      task_scope: {
        status: 'partial_task_scope',
        legacy_unscoped_rows: 270,
        current_writer_missing_task_scope_rows: 5,
        current_writer_missing_task_scope: true,
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
