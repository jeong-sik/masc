import type { KeeperTraceContextFields } from './keeper-trace-store'
import { normalizeIdeContextFilePath, normalizeIdeContextLine } from './ide-state'

export interface KeeperTraceProducerContextInput {
  readonly file_path?: string | null
  readonly line?: number | null
  readonly task_id?: string
  readonly board_post_id?: string
  readonly comment_id?: string
  readonly pr_id?: string
  readonly git_ref?: string
  readonly log_id?: string
  readonly session_id?: string
  readonly operation_id?: string
  readonly worker_run_id?: string
}

export function normalizeTraceProducerContext(
  context?: KeeperTraceProducerContextInput | null,
): KeeperTraceContextFields {
  if (!context) return {}
  const filePath = context.file_path ? normalizeIdeContextFilePath(context.file_path) : null
  const line = normalizeIdeContextLine(context.line ?? undefined)
  return {
    filePath: filePath ?? undefined,
    line,
    taskId: context.task_id,
    boardPostId: context.board_post_id,
    commentId: context.comment_id,
    prId: context.pr_id,
    gitRef: context.git_ref,
    logId: context.log_id,
    sessionId: context.session_id,
    operationId: context.operation_id,
    workerRunId: context.worker_run_id,
  }
}
