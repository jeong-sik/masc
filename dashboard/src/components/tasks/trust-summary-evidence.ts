// Helpers for deciding whether the keeper trust summary block has any
// content worth rendering in the task planning surface. Split out from `KeeperCard` so
// the predicate can be unit-tested independently of the Preact render
// path.

type PendingFirst = {
  id?: string | null
  tool_name?: string | null
  task_id?: string | null
  blocker_class?: string | null
}

type ApprovalState = {
  pending_first?: PendingFirst | null
}

/**
 * Returns true when `approval_state.pending_first` carries at least one
 * non-empty identifier/tool/task/blocker field — i.e. there is approval
 * evidence the operator should be able to see, even when the surrounding
 * trust fields (`state`, attention/disposition text, execution flags)
 * are absent.
 *
 * Mirrors the trimming/truthy contract used by `KeeperCard` for the
 * inline `pendingApprovalId/...` locals so the predicate stays aligned
 * with what the rendered cells actually show.
 */
export function trustHasPendingFirstEvidence(
  approvalState: ApprovalState | null | undefined,
): boolean {
  const pending = approvalState?.pending_first
  if (!pending) return false
  const fields = [pending.id, pending.tool_name, pending.task_id, pending.blocker_class]
  return fields.some(value => typeof value === 'string' && value.trim().length > 0)
}
