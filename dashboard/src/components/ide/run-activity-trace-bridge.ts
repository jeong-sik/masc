import { pushTrace } from './keeper-trace-store'
import { normalizeIdeContextFilePath, normalizeIdeContextLine } from './ide-state'
import type { RunActivityEvent } from './run-activity-store'

/**
 * Bridge normalized run activity into the keeper-trace store so activity
 * events with trusted file+line context become visible in the IDE line gutter.
 *
 * The caller owns `alreadyEmitted`; keeping the set outside this module avoids
 * leaking component lifecycle across remounts while still deduping refreshes.
 */
export function bridgeRunActivityEventsToTrace(
  events: ReadonlyArray<RunActivityEvent>,
  alreadyEmitted: ReadonlySet<string>,
): ReadonlySet<string> {
  if (events.length === 0) return alreadyEmitted
  const next = new Set(alreadyEmitted)
  for (const event of events) {
    const key = `activity:${event.run_id}:${event.id}`
    if (next.has(key)) continue
    const filePath = event.context?.file_path
      ? normalizeIdeContextFilePath(event.context.file_path)
      : null
    const line = normalizeIdeContextLine(event.context?.line)
    if (filePath === null || line === undefined) continue
    if (!Number.isFinite(event.timestamp_ms)) continue
    pushTrace({
      id: key,
      tsMs: event.timestamp_ms,
      keeperName: event.keeper_id,
      source: 'activity-event',
      eventId: event.id,
      filePath,
      line,
      surface: activityTraceSurface(event),
      taskId: event.context?.task_id,
      boardPostId: event.context?.board_post_id,
      commentId: event.context?.comment_id,
      prId: event.context?.pr_id,
      gitRef: event.context?.git_ref,
      logId: event.context?.log_id,
      sessionId: event.context?.session_id,
      operationId: event.context?.operation_id,
      workerRunId: event.context?.worker_run_id,
    })
    next.add(key)
  }
  return next
}

function activityTraceSurface(event: RunActivityEvent): string {
  if (event.context?.pr_id) return 'PR'
  if (event.context?.board_post_id) return 'Board'
  if (event.context?.task_id) return 'Task'
  if (event.context?.git_ref) return 'Git'
  if (event.context?.log_id) return 'Log'
  if (event.context?.comment_id) return 'Comment'
  if (event.context?.session_id || event.context?.operation_id || event.context?.worker_run_id) {
    return 'Runtime'
  }
  return event.kind?.trim() || 'Activity'
}
