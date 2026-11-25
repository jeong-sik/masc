/**
 * Shared SSOT wire decoders for HITL tool-approval and Keeper Ask payloads
 * consumed across Shell (`shell-state`), Pulse (`pulse-data`), and Work Inbox (`inbox-tab`).
 */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function formatArgsWire(value: unknown): string {
  if (typeof value === 'string') return value
  if (value === undefined || value === null) return ''
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return ''
  }
}

export interface DecodedToolApprovalWire {
  readonly approvalId: string
  readonly hasExplicitApprovalId: boolean
  readonly toolCallId: string
  readonly keeper: string
  readonly tool: string
  readonly args: string
  readonly question: string
  readonly because: string
  readonly askedAt: number | null
  readonly timeoutSec: number | null
  readonly revision: string
}

/**
 * Decode `/api/v1/tool-approvals` (`{ pending: [...] }`) once across all views.
 *
 * Rows without a `keeper` or without either `approval_id` or `tool_call_id` are
 * dropped. Callers that require both `approval_id` and `tool_call_id` (or fall
 * back when only one is present) inspect `hasExplicitApprovalId` / `toolCallId`.
 */
export function decodeToolApprovalsWire(raw: unknown): readonly DecodedToolApprovalWire[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) return []
  const items: DecodedToolApprovalWire[] = []
  for (const row of raw.pending) {
    if (!isRecord(row)) continue
    const explicitApprovalId = asNonEmptyString(row.approval_id)
    const toolCallId = asNonEmptyString(row.tool_call_id) ?? ''
    const keeper = asNonEmptyString(row.keeper)
    const approvalId = explicitApprovalId ?? (toolCallId || null)
    if (!approvalId || !keeper) continue
    const askedAt = asFiniteNumber(row.asked_at)
    const revision =
      asNonEmptyString(row.revision)
      ?? (typeof row.revision === 'number' && Number.isFinite(row.revision)
        ? String(row.revision)
        : `${approvalId}:${askedAt ?? 0}`)
    items.push({
      approvalId,
      hasExplicitApprovalId: explicitApprovalId !== null,
      toolCallId,
      keeper,
      tool: typeof row.tool === 'string' ? row.tool : '',
      args: formatArgsWire(row.args),
      question: typeof row.question === 'string' ? row.question : '',
      because: asNonEmptyString(row.because) ?? '',
      askedAt,
      timeoutSec: asFiniteNumber(row.timeout_sec),
      revision,
    })
  }
  return items
}

const CLOSED_ASK_STATES = new Set([
  'answered',
  'resolved',
  'closed',
  'withdrawn',
  'expired',
  'cancelled',
])

/**
 * Closed-set SSOT check for whether a raw Keeper Ask row is still open.
 * - If `row.resolution.state` is present, only `'open'` is considered open.
 * - Otherwise, `row.state` is open unless it is in `CLOSED_ASK_STATES`.
 */
export function isOpenKeeperAskRow(row: Record<string, unknown>): boolean {
  if (isRecord(row.resolution) && typeof row.resolution.state === 'string') {
    const normalized = row.resolution.state.trim().toLowerCase()
    return normalized === '' || normalized === 'open'
  }
  if (typeof row.state === 'string') {
    const normalized = row.state.trim().toLowerCase()
    return normalized === '' || normalized === 'open' || !CLOSED_ASK_STATES.has(normalized)
  }
  return true
}
