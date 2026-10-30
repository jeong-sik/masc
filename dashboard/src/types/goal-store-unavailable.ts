// RFC-0444 §2.3 row 4: the wire envelope a Goal store this build cannot read
// answers with, parsed into a closed union. The three token lists below are
// the exact lowercase constructor names the server emits
// (lib/types/goal_store_unavailable.ml: reason_name, mirror_status_name,
// reset_step_name); the parser refuses any other value instead of defaulting.

export const GOAL_STORE_UNAVAILABLE_REASONS = [
  'missing_after_init',
  'unreadable',
  'not_json',
  'schema_rejected',
] as const
export type GoalStoreUnavailableReason = (typeof GOAL_STORE_UNAVAILABLE_REASONS)[number]

export const GOAL_STORE_MIRROR_STATUSES = [
  'mirror_absent',
  'mirror_unreadable',
  'mirror_decodes',
  'mirror_rejected',
] as const
export type GoalStoreMirrorStatus = (typeof GOAL_STORE_MIRROR_STATUSES)[number]

export const GOAL_STORE_RESET_STEPS = [
  'repair_field',
  'reset_goal_store',
  'restore_permission',
] as const
export type GoalStoreResetStep = (typeof GOAL_STORE_RESET_STEPS)[number]

export interface GoalStoreMirror {
  status: GoalStoreMirrorStatus
  /** Row count of a mirror that decodes; null for the other three statuses. */
  goalCount: number | null
}

/** `error_code: "goal_store_unavailable"` — the Goal store itself. */
export interface GoalStoreUnavailable {
  kind: 'unavailable'
  reason: GoalStoreUnavailableReason
  /** The refused member for `schema_rejected`; null for the other reasons. */
  field: string | null
  file: string
  mirror: GoalStoreMirror
  resetStep: GoalStoreResetStep
}

/**
 * `error_code: "goal_task_links_unavailable"` — the Goal–Task link registry,
 * a different source outside RFC-0444, which still answers with a rendered
 * line.
 */
export interface GoalTaskLinksUnavailable {
  kind: 'links_unavailable'
  detail: string
}

export type GoalSourceUnavailable = GoalStoreUnavailable | GoalTaskLinksUnavailable
