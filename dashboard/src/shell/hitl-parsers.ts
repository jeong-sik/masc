/**
 * HITL wire payload decoders for shell-state.
 *
 * Kept in a dedicated module so `refreshPendingHitl` loads the decoders
 * concurrently with its HTTP requests instead of bloating the initial boot chunk,
 * while `shell-state.ts` still re-exports the pure parsers for tests.
 */

import {
  decodeGateQueueStrict,
  decodeKeeperAsksWire,
  decodeToolApprovalsWire,
} from '../api/hitl-decoders'
import { decodeVerificationCoverage } from '../lib/verification-coverage'
import type {
  PendingApprovalItem,
  PendingAskItem,
  PendingGateItem,
  PendingGoalConfirmItem,
  PendingVerificationItem,
} from './shell-state'

export { decodeGateQueueStrict, decodeKeeperAsksWire, decodeVerificationCoverage }

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNonEmptyString(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

export function parseToolApprovalsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingApprovalItem[] {
  const items: PendingApprovalItem[] = []
  for (const row of decodeToolApprovalsWire(raw)) {
    if (!row.hasExplicitApprovalId || !row.toolCallId) continue
    items.push({
      approvalId: row.approvalId,
      keeper: row.keeper,
      toolCallId: row.toolCallId,
      tool: row.tool,
      args: row.args,
      question: row.question,
      because: row.because,
      askedAt: row.askedAt,
      workspaceId,
      revision: row.revision,
    })
  }
  return items
}

export function parseKeeperAsksPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingAskItem[] {
  const decoded = decodeKeeperAsksWire(raw)
  if (!decoded.ok) return []
  return decoded.asks.map((ask) => ({
    askId: ask.askId,
    keeper: ask.keeper,
    prompt: ask.promptSummary ?? 'Keeper awaiting operator answer',
    askedAt: ask.askedAt,
    workspaceId,
    revision: ask.revision,
  }))
}

export function parseGateQueuePayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingGateItem[] {
  const decoded = decodeGateQueueStrict(raw)
  if (!decoded.ok) return []
  return decoded.rows.map((row) => ({
    id: row.id,
    keeper: row.keeper,
    toolName: row.toolName,
    phase: row.phase ?? 'unknown',
    waitingSec: row.waitingSec,
    workspaceId,
  }))
}

export function parseAwaitingGoalsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingGoalConfirmItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.goals)) return []
  const items: PendingGoalConfirmItem[] = []
  for (const row of raw.goals) {
    if (!isRecord(row)) continue
    const phase = asNonEmptyString(row.phase)
    if (!phase || phase.toLowerCase() !== 'awaiting_confirmation') continue
    const goalId = asNonEmptyString(row.id)
    const title = asNonEmptyString(row.title)
    if (!goalId || !title) continue
    items.push({
      goalId,
      title,
      updatedAt: asNonEmptyString(row.updated_at),
      workspaceId,
    })
  }
  return items
}

export function parsePendingVerificationsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingVerificationItem[] {
  if (!isRecord(raw)) return []
  const list = Array.isArray(raw.requests)
    ? raw.requests
    : Array.isArray(raw.items)
      ? raw.items
      : []
  const items: PendingVerificationItem[] = []
  for (const row of list) {
    if (!isRecord(row)) continue
    const requestId = asNonEmptyString(row.request_id) ?? asNonEmptyString(row.id)
    const taskId = asNonEmptyString(row.task_id)
    if (!requestId || !taskId) continue
    items.push({
      requestId,
      taskId,
      title: asNonEmptyString(row.task_title) ?? asNonEmptyString(row.title) ?? taskId,
      worker: asNonEmptyString(row.submitted_by) ?? asNonEmptyString(row.worker) ?? asNonEmptyString(row.producer),
      workspaceId,
    })
  }
  return items
}
