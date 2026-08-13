import type { DashboardFleetSafetyHealth } from '../types'
import type { DashboardFullHealthResponse } from '../api/dashboard'

export const LIVE_OVERVIEW_COMPOSITE_HEALTH: DashboardFullHealthResponse = {
  health_detail: 'full',
  overall_status: 'degraded',
  operator_action_required: true,
  operator_action_reasons: [
    'keeper_fleet_safety',
    'keeper_reaction_ledger',
    'keeper_event_queue',
  ],
  schedule_runner: null,
  keeper_event_queue: null,
}

/**
 * Regression fixture from the 2026-08-13 live Overview contradiction:
 * the roster showed 8/8 while runtime health reported 7 executable keepers,
 * a reaction-capacity shortfall, and a degraded reaction ledger.
 */
export const LIVE_OVERVIEW_HEALTH_CONTRADICTION: DashboardFleetSafetyHealth = {
  keeper_fibers: 8,
  paused_keepers: 0,
  paused_keepers_health: null,
  keeper_fleet_safety: {
    schema: 'masc.keeper_fleet_operator.v1',
    status: 'degraded',
    reason: 'reaction_capacity_below_target',
    blocker: 'reaction_capacity_below_target',
    blocked_keeper_count: 1,
    blocked_keepers: [{
      keeper_name: 'rtprobe',
      agent_name: 'rtprobe',
      task_id: null,
      task_status: null,
      reason: 'phase_running',
      action: 'inspect_capacity_accounting',
      execution_truth: 'retained_disabled',
      non_executable_cause: 'proactive_disabled',
      operator_action_type: null,
      operator_tool_name: null,
      operator_action_confirm_required: null,
    }],
    bootable_keeper_count: 8,
    running_keeper_fiber_count: 7,
    failing_keeper_fiber_count: 1,
    recovering_keeper_fiber_count: 1,
    executable_keeper_fiber_count: 7,
    no_executable_keeper_fibers: false,
    reaction_capacity_below_target: true,
    reaction_capacity_shortfall_count: 1,
    paused_keeper_count: 0,
    autoboot_enabled_keeper_count: 8,
    paused_autoboot_enabled_keeper_count: 0,
    target_reaction_capacity_count: 8,
    operator_action_required: true,
  },
  keeper_reaction_ledger: {
    status: 'degraded',
    operator_action_required: true,
    keeper_count: 8,
    row_count: 42,
    stimulus_count: 21,
    reaction_count: 14,
    turn_started_count: 14,
    quarantined_row_count: 0,
    cursor_swept_stimulus_count: 7,
    pending_stimulus_count: 0,
    read_error_count: 0,
    pending_by_keeper: [],
  },
}
