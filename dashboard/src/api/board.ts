import { currentDashboardActor, get, post, del, put, runRequest, defaultBoardVoter } from './core'
import { isRecord, asNullableString, asString, asNumber, asInt, asStringList } from '../components/common/normalize'
import { normalizePendingConfirmation } from '../pending-confirm'
import { timeBoardRequest } from '../board-metrics'
import type {
  BoardActorIdentity, BoardPost, BoardPostOrigin, BoardComment, BoardReactionSummary,
  BoardReactionState, BoardReactionTargetType, BoardReactionToggleResult, BoardSortMode,
  BoardVoteDirection,
    BoardAttachmentDecode, BoardAttachmentKind,
    BoardCurationSnapshot, BoardKarmaLedger, BoardKarmaLedgerEvent, BoardKarmaTotal,
    KeeperApprovalQueueItem, KeeperExactAttemptState,
    KeeperExactAttemptStatus, KeeperExactAttemptQuarantineCause,
    KeeperSummaryAttemptDisposition,
  GateJudgment, HitlContextSummary, HitlSummaryStatus,
  SubBoard, SubBoardAccess,
} from '../types'

export interface BoardHearth {
  name: string
  count: number
}

export interface BoardFlair {
  name: string
  emoji: string
  label: string
}

export type BoardContextInferenceTargetSource = 'explicit_target' | 'post_author'

export interface BoardContextInferenceSubmission {
  ok: true
  requestId: string
  keeperName: string
  postId: string
  status: string
  targetSource?: BoardContextInferenceTargetSource
  message?: string
}

function toIsoTimestamp(value: unknown): string | null {
  if (typeof value === 'string' && value.trim()) return value
  if (typeof value !== 'number' || Number.isNaN(value)) return null
  const ms = value < 1_000_000_000_000 ? value * 1000 : value
  return new Date(ms).toISOString()
}

export function asNullableIsoTimestamp(value: unknown): string | null {
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed ? trimmed : null
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    const ms = value < 1_000_000_000_000 ? value * 1000 : value
    return new Date(ms).toISOString()
  }
  return null
}

function normalizeBoardActorSource(raw: unknown): BoardActorIdentity['source'] {
  const source = asString(raw, '').trim()
  switch (source) {
    case 'keeper_registry_name':
    case 'raw_agent':
      return source
    default:
      return undefined
  }
}

function normalizeBoardKarmaTargetKind(raw: unknown): BoardKarmaLedgerEvent['target_kind'] | null {
  const kind = asString(raw, '').trim().toLowerCase()
  return kind === 'post' || kind === 'comment' ? kind : null
}

// normalizePendingConfirmation re-exported from pending-confirm.ts (SSOT)
export { normalizePendingConfirmation }

function normalizeGateJudgment(raw: unknown): GateJudgment | null {
  return raw === 'approve' || raw === 'deny' || raw === 'require_human' ? raw : null
}

const CURRENT_HITL_CONTEXT_SUMMARY_VERSION = 2

function normalizeHitlContextSummary(raw: unknown): HitlContextSummary | null {
  if (
    !isRecord(raw)
    || !hasOnlyKeys(raw, [
      'summary_version',
      'generated_at',
      'model_run_id',
      'context_summary',
      'key_questions',
      'judgment',
      'rationale',
    ])
  ) return null
  const summaryVersion = asInt(raw.summary_version)
  const generatedAt = asNullableIsoTimestamp(raw.generated_at)
  const modelRunId = asString(raw.model_run_id, '').trim()
  const summaryText = asString(raw.context_summary, '').trim()
  const judgment = normalizeGateJudgment(raw.judgment)
  const keyQuestions = Array.isArray(raw.key_questions)
    && raw.key_questions.every(value => typeof value === 'string')
    ? raw.key_questions
    : null
  const rationale = typeof raw.rationale === 'string' ? raw.rationale.trim() : null
  if (
    summaryVersion !== CURRENT_HITL_CONTEXT_SUMMARY_VERSION
    || generatedAt === null
    || !modelRunId
    || !summaryText
    || !judgment
    || keyQuestions === null
    || rationale === null
  ) return null
  return {
    summary_version: summaryVersion,
    generated_at: generatedAt,
    model_run_id: modelRunId,
    context_summary: summaryText,
    key_questions: keyQuestions,
    judgment,
    rationale,
  }
}

/** Parse the backend `summary_status` wire value into the typed union. Returns
 *  `null` for an absent or contract-violating shape — a malformed status must
 *  not silently read as `not_requested`, which would hide a wiring fault. */
export function normalizeHitlSummaryStatus(raw: unknown): HitlSummaryStatus | null {
  if (raw === 'not_requested') return { status: 'not_requested' }
  if (raw === 'pending') return { status: 'pending' }
  if (!isRecord(raw)) return null
  switch (raw.status) {
    case 'available': {
      if (!hasOnlyKeys(raw, ['status', 'summary'])) return null
      const summary = normalizeHitlContextSummary(raw.summary)
      return summary ? { status: 'available', summary } : null
    }
    case 'failed': {
      // `retryable` was removed producer-side (#26094): it was write-only
      // `false` in OCaml, and requiring that exact value here turned one
      // drifted row into a blank approval queue. The server no longer sends
      // the field, so its presence is a contract violation for this row.
      if (!hasOnlyKeys(raw, ['status', 'reason'])) return null
      const reason = asString(raw.reason, '').trim()
      return reason ? { status: 'failed', reason } : null
    }
    default:
      return null
  }
}

const EXACT_ATTEMPT_STATUSES: ReadonlySet<string> = new Set([
  'dispatch_uncertain',
  'released_before_dispatch',
  'released_recovery_required',
  'quarantined',
  'restart_quarantined',
  'completed',
])

const EXACT_ATTEMPT_QUARANTINE_CAUSES: ReadonlySet<string> = new Set([
  'flow_execution_failed',
  'cancellation',
  'attempt_replay',
  'domain_invalid_output',
  'terminal_persistence_failure',
])

function exactAttemptQuarantineSummaryReason(cause: string): string {
  return `Auto Judge exact attempt quarantined: ${cause}`
}

function hasOnlyKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

export function normalizeKeeperExactAttempt(raw: unknown): KeeperExactAttemptState | null {
  if (!isRecord(raw)) return null
  if (raw.state === 'unbound') {
    return hasOnlyKeys(raw, ['state']) ? { state: 'unbound' } : null
  }
  if (
    raw.state !== 'bound'
    || !hasOnlyKeys(raw, [
      'state',
      'approval_id',
      'input_hash',
      'sequence',
      'slot_id',
      'call_id',
      'plan_fingerprint',
      'request_body_sha256',
      'status',
      'quarantine_cause',
    ])
  ) return null
  const approvalId = asString(raw.approval_id, '').trim()
  const inputHash = asString(raw.input_hash, '').trim()
  const sequence = asInt(raw.sequence)
  const slotId = asString(raw.slot_id, '').trim()
  const callId = asString(raw.call_id, '').trim()
  const planFingerprint = asString(raw.plan_fingerprint, '').trim()
  const requestBodySha256 = asString(raw.request_body_sha256, '').trim()
  const status = typeof raw.status === 'string' && EXACT_ATTEMPT_STATUSES.has(raw.status)
    ? raw.status as KeeperExactAttemptStatus
    : null
  const quarantineCause =
    typeof raw.quarantine_cause === 'string'
    && EXACT_ATTEMPT_QUARANTINE_CAUSES.has(raw.quarantine_cause)
      ? raw.quarantine_cause as KeeperExactAttemptQuarantineCause
      : null
  if (
    !approvalId
    || !/^[0-9a-f]{64}$/.test(inputHash)
    || typeof sequence !== 'number'
    || sequence <= 0
    || !slotId
    || !callId
    || !planFingerprint
    || !/^[0-9a-f]{64}$/.test(requestBodySha256)
    || !status
    || (status === 'quarantined'
      ? quarantineCause === null
      : raw.quarantine_cause !== null)
  ) return null
  return {
    state: 'bound',
    approval_id: approvalId,
    input_hash: inputHash,
    sequence,
    slot_id: slotId,
    call_id: callId,
    plan_fingerprint: planFingerprint,
    request_body_sha256: requestBodySha256,
    status,
    quarantine_cause: quarantineCause,
  }
}

function normalizeKeeperSummaryAttemptDisposition(
  raw: unknown,
): KeeperSummaryAttemptDisposition | null {
  if (!isRecord(raw) || typeof raw.code !== 'string') return null
  switch (raw.code) {
    case 'ready':
    case 'in_flight':
    case 'settled':
      return hasOnlyKeys(raw, ['code']) ? { code: raw.code } : null
    case 'identity_unbound':
    case 'persistence_uncertain': {
      const operatorDetail = asString(raw.operator_detail, '').trim()
      const expectedDetail = raw.code === 'identity_unbound'
        ? 'Exact-output terminalization stopped before an attempt identity was bound.'
        : 'Exact-output terminalization durability is not confirmed.'
      return operatorDetail === expectedDetail
        && hasOnlyKeys(raw, ['code', 'operator_detail'])
        ? { code: raw.code, operator_detail: operatorDetail }
        : null
    }
    case 'pre_worker_unavailable': {
      const reasonCode = raw.reason_code
      const operatorDetail = raw.operator_detail
      return (
        reasonCode === 'auto_judge_unavailable'
        || reasonCode === 'mode_state_invalid'
        || reasonCode === 'start_reserved'
      )
        && typeof operatorDetail === 'string'
        && operatorDetail.length > 0
        && operatorDetail.trim() === operatorDetail
        && hasOnlyKeys(raw, ['code', 'reason_code', 'operator_detail'])
        ? {
            code: raw.code,
            reason_code: reasonCode,
            operator_detail: operatorDetail,
          }
        : null
    }
    default:
      return null
  }
}

export function normalizeKeeperApprovalQueueItem(raw: unknown): KeeperApprovalQueueItem | null {
  if (!isRecord(raw)) return null
  const canonicalKeys = [
    'id',
    'keeper_name',
    'tool_name',
    'input_hash',
    'sequence',
    'requested_at',
    'waiting_s',
    'turn_id',
    'task_id',
    'goal_id',
    'goal_ids',
    'summary_status',
    'exact_attempt',
    'summary_attempt_disposition',
  ]
  const hasInput = Object.prototype.hasOwnProperty.call(raw, 'input')
  const hasInputPreview = Object.prototype.hasOwnProperty.call(raw, 'input_preview')
  if (hasInput !== hasInputPreview) return null
  if (
    !hasOnlyKeys(
      raw,
      hasInput ? [...canonicalKeys, 'input', 'input_preview'] : canonicalKeys,
    )
  ) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  const inputHash = asString(raw.input_hash, '').trim()
  const sequence = asInt(raw.sequence)
  if (
    !id
    || !keeperName
    || !toolName
    || !/^[0-9a-f]{64}$/.test(inputHash)
    || typeof sequence !== 'number'
    || sequence <= 0
  ) return null
  const summaryStatus = normalizeHitlSummaryStatus(raw.summary_status)
  const exactAttempt = normalizeKeeperExactAttempt(raw.exact_attempt)
  const disposition =
    normalizeKeeperSummaryAttemptDisposition(raw.summary_attempt_disposition)
  if (!summaryStatus || !exactAttempt || !disposition) return null
  if (
    exactAttempt.state === 'bound'
    && (
      exactAttempt.approval_id !== id
      || exactAttempt.input_hash !== inputHash
      || exactAttempt.sequence !== sequence
    )
  ) return null
  const validPair = (() => {
    switch (disposition.code) {
      case 'ready':
        return exactAttempt.state === 'unbound'
          && (summaryStatus.status === 'not_requested' || summaryStatus.status === 'pending')
      case 'identity_unbound':
        return exactAttempt.state === 'unbound'
          && summaryStatus.status === 'pending'
      case 'pre_worker_unavailable':
        return exactAttempt.state === 'unbound'
          && (
            summaryStatus.status === 'not_requested'
            || summaryStatus.status === 'pending'
          )
      case 'in_flight':
        return exactAttempt.state === 'bound'
          && summaryStatus.status === 'pending'
          && (
            exactAttempt.status === 'dispatch_uncertain'
            || exactAttempt.status === 'released_before_dispatch'
          )
      case 'settled':
        return exactAttempt.state === 'bound'
          && (
            (exactAttempt.status === 'completed' && summaryStatus.status === 'available')
            || (
              exactAttempt.status === 'quarantined'
              && exactAttempt.quarantine_cause !== null
              && summaryStatus.status === 'failed'
              && summaryStatus.reason
                === exactAttemptQuarantineSummaryReason(exactAttempt.quarantine_cause)
            )
          )
      case 'persistence_uncertain':
        if (exactAttempt.state === 'unbound') return summaryStatus.status === 'pending'
        if (exactAttempt.status === 'completed') return summaryStatus.status === 'available'
        if (exactAttempt.status === 'quarantined') {
          return exactAttempt.quarantine_cause !== null
            && summaryStatus.status === 'failed'
            && summaryStatus.reason
              === exactAttemptQuarantineSummaryReason(exactAttempt.quarantine_cause)
        }
        return summaryStatus.status === 'pending'
          && (
            exactAttempt.status === 'dispatch_uncertain'
            || exactAttempt.status === 'released_before_dispatch'
            || exactAttempt.status === 'released_recovery_required'
            || exactAttempt.status === 'restart_quarantined'
          )
      default: {
        const _never: never = disposition
        return _never
      }
    }
  })()
  if (!validPair) return null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    input_hash: inputHash,
    sequence,
    requested_at: asNullableIsoTimestamp(raw.requested_at),
    waiting_s: asNumber(raw.waiting_s),
    turn_id: asInt(raw.turn_id),
    task_id: asNullableString(raw.task_id),
    goal_id: asNullableString(raw.goal_id),
    goal_ids: asStringList(raw.goal_ids),
    input: raw.input,
    input_preview: asNullableString(raw.input_preview),
    summary_status: summaryStatus,
    exact_attempt: exactAttempt,
    summary_attempt_disposition: disposition,
  }
}

function truncatePostTitle(title: string): string {
  const chars = Array.from(title)
  if (chars.length <= 96) return title
  return `${chars.slice(0, 93).join('')}...`
}

function stripTitleMarkdown(line: string): string {
  return line
    .trim()
    .replace(/^#{1,6}\s+/, '')
    .replace(/^>\s+/, '')
    .replace(/^[-*+]\s+/, '')
    .replace(/^\d+\.\s+/, '')
    .trim()
}

export function derivePostTitle(content: string): string {
  const trimmed = content.trim()
  const withoutFlair = trimmed.startsWith('[flair:')
    ? trimmed.replace(/^\[flair:[^\]]+\]\s*/i, '')
    : trimmed
  const lines = withoutFlair.split('\n')
  let inFence = false

  for (const rawLine of lines) {
    const line = rawLine.trim()
    if (!line) continue
    if (/^(`{3,}|~{3,})/.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence || /^(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) continue
    const title = stripTitleMarkdown(line)
    if (title) return truncatePostTitle(title)
  }

  return '제목 없음'
}

export function sanitizeBoardTitle(title: string, fallbackBody = ''): string {
  const firstLine = title.trim().split('\n')[0] ?? ''
  const normalized = stripTitleMarkdown(firstLine)
  if (normalized) return truncatePostTitle(normalized)
  return derivePostTitle(fallbackBody)
}

function normalizeBoardMeta(raw: unknown): BoardPost['meta'] {
  if (!isRecord(raw)) return null
  const next: Record<string, unknown> = { ...raw }
  const source = asString(raw.source, '').trim()
  const classificationReason = asString(raw.classification_reason, '').trim()
  if (source) next.source = source
  if (classificationReason) next.classification_reason = classificationReason
  return Object.keys(next).length > 0 ? next : null
}

// RFC-0000 §3.1: `meta.attachments` carries Board_attachment_meta entries.
// Decode mirrors the OCaml contract (id/kind/origin_url/origin_size_bytes/
// created_at required, width/height nullable). Entries that fail the contract
// are kept as `{ ok: false }` — the surface renders an explicit failure card,
// never a silent skip. A present-but-non-array carrier is itself one invalid
// entry, matching Board_render's Invalid_attachment block on the OCaml side.
const BOARD_ATTACHMENT_KINDS: ReadonlySet<string> = new Set([
  'image',
  'video',
  'youtube',
  'external_link',
])

function normalizeBoardAttachment(raw: unknown): BoardAttachmentDecode {
  if (!isRecord(raw)) return { ok: false, raw }
  const id = asString(raw.id, '').trim()
  const kindRaw = asString(raw.kind, '').trim()
  const originUrl = asString(raw.origin_url, '').trim()
  const originSizeBytes = asNumber(raw.origin_size_bytes)
  const createdAt = asNumber(raw.created_at)
  if (
    !id
    || !BOARD_ATTACHMENT_KINDS.has(kindRaw)
    || !originUrl
    || originSizeBytes === undefined
    || createdAt === undefined
  ) {
    return { ok: false, raw }
  }
  return {
    ok: true,
    attachment: {
      id,
      kind: kindRaw as BoardAttachmentKind,
      origin_url: originUrl,
      origin_name: asString(raw.origin_name, ''),
      origin_size_bytes: originSizeBytes,
      mime_type: asString(raw.mime_type, ''),
      width: asNumber(raw.width) ?? null,
      height: asNumber(raw.height) ?? null,
      created_at: createdAt,
    },
  }
}

export function normalizeBoardAttachments(raw: unknown): BoardAttachmentDecode[] | undefined {
  if (raw === undefined || raw === null) return undefined
  if (!Array.isArray(raw)) return [{ ok: false, raw }]
  const entries = raw.map(normalizeBoardAttachment)
  return entries.length > 0 ? entries : undefined
}

function normalizeBoardActorIdentity(
  raw: unknown,
  fallbackRaw: string,
): BoardActorIdentity | null {
  if (!isRecord(raw)) return null
  const kindRaw = asString(raw.kind, '').trim().toLowerCase()
  const kind = kindRaw === 'keeper' ? 'keeper' : kindRaw === 'agent' ? 'agent' : null
  const id = asString(raw.id, '').trim()
  if (!kind || !id) return null
  const key = asString(raw.key, '').trim() || `${kind}:${id.toLowerCase()}`
  const displayName = asString(raw.display_name, '').trim() || id
  const original = asString(raw.raw, '').trim() || fallbackRaw
  return {
    kind,
    id,
    key,
    display_name: displayName,
    raw: original,
    source: normalizeBoardActorSource(raw.source),
  }
}

function normalizeBoardVoteDirection(raw: unknown): BoardVoteDirection | null {
  const direction = asString(raw, '').trim().toLowerCase()
  return direction === 'up' || direction === 'down' ? direction : null
}

// RFC-0233 §7: parse the typed origin object (post_to_yojson_with_karma emits
// turn_ref / source / fusion_run_id). Parse, don't repair: a non-object or an
// all-absent origin -> null (no empty record); each sub-field degrades
// independently. Never throws, never drops the post.
function normalizeBoardPostOrigin(raw: unknown): BoardPostOrigin | null {
  if (!isRecord(raw)) return null
  const turnRef = asNullableString(raw.turn_ref)
  const source = asNullableString(raw.source)
  const fusionRunId = asNullableString(raw.fusion_run_id)
  if (turnRef === null && source === null && fusionRunId === null) return null
  return {
    ...(turnRef !== null ? { turn_ref: turnRef } : {}),
    ...(source !== null ? { source } : {}),
    ...(fusionRunId !== null ? { fusion_run_id: fusionRunId } : {}),
  }
}

function normalizeBoardPost(raw: unknown): BoardPost | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const author = asString(raw.author, '').trim()
  const body = asString(raw.body, '').trim()
  if (!id || !author) return null

  const votesUp = asNumber(raw.votes_up, 0)
  const votesDown = asNumber(raw.votes_down, 0)
  const score = votesUp - votesDown
  const votes = asNumber(raw.votes, score)
  const currentVote = normalizeBoardVoteDirection(raw.current_vote)
  const hasVoted = typeof raw.has_voted === 'boolean' ? raw.has_voted : currentVote !== null
  const commentCount = asNumber(raw.comment_count, asNumber(raw.reply_count, 0))
  const flairValue = (() => {
    const flair = raw.flair
    if (typeof flair === 'string' && flair.trim()) return flair.trim()
    if (isRecord(flair)) {
      const name = asString(flair.name, '').trim()
      if (name) return name
    }
    const fallback = asString(raw.flair_name, '').trim()
    return fallback || undefined
  })()
  const createdAt =
    asString(raw.created_at_iso, '').trim() || toIsoTimestamp(raw.created_at)
  const updatedAt =
    asString(raw.updated_at_iso, '').trim()
    || (raw.updated_at !== undefined ? toIsoTimestamp(raw.updated_at) : createdAt)
  const titleRaw = asString(raw.title, '').trim()
  const title = sanitizeBoardTitle(titleRaw, body)
  const tags = asStringList(raw.tags)
  const reactions = Array.isArray(raw.reactions)
    ? raw.reactions
        .map(normalizeBoardReactionSummary)
        .filter((row): row is BoardReactionSummary => row !== null)
    : undefined
  const supportedReactionEmojis = normalizeSupportedReactionEmojis(raw.supported_reaction_emojis)
  const meta = normalizeBoardMeta(raw.meta)
  const attachments = normalizeBoardAttachments(meta?.attachments)

  return {
    id,
    author,
    author_identity: normalizeBoardActorIdentity(raw.author_identity, author),
    post_kind:
      (() => {
        const rawKind = asString(raw.post_kind, '').trim().toLowerCase()
        if (rawKind === 'human' || rawKind === 'direct') return 'direct'
        return rawKind === 'automation' || rawKind === 'system' ? rawKind : undefined
      })(),
    pinned: raw.pinned === true,
    classification_reason: asString(raw.classification_reason, '').trim() || null,
    title,
    body,
    meta,
    ...(attachments !== undefined ? { attachments } : {}),
    tags,
    votes,
    vote_balance: score,
    current_vote: currentVote,
    has_voted: hasVoted,
    comment_count: commentCount,
    created_at: createdAt ?? '',
    updated_at: updatedAt ?? '',
    flair: flairValue,
    hearth: asString(raw.hearth, '').trim() || null,
    visibility: asString(raw.visibility, '').trim() || undefined,
    expires_at:
      asString(raw.expires_at_iso, '').trim()
      || (raw.expires_at !== undefined && raw.expires_at !== 0
        ? toIsoTimestamp(raw.expires_at)
        : '')
      || null,
    hearth_count: asNumber(raw.hearth_count, 0),
    ...(reactions !== undefined ? { reactions } : {}),
    ...(supportedReactionEmojis !== undefined
      ? { supported_reaction_emojis: supportedReactionEmojis }
      : {}),
    origin: normalizeBoardPostOrigin(raw.origin),
  }
}

function normalizeBoardComment(raw: unknown): BoardComment | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const postId = asString(raw.post_id, '').trim()
  const author = asString(raw.author, '').trim()
  if (!id || !author) return null
  const parentId = asString(raw.parent_id, '').trim() || null
  const votesUp = asNumber(raw.votes_up, 0)
  const votesDown = asNumber(raw.votes_down, 0)
  const score = asNumber(raw.score, votesUp - votesDown)
  const votes = asNumber(raw.votes, score)
  const currentVote = normalizeBoardVoteDirection(raw.current_vote)
  const hasVoted = typeof raw.has_voted === 'boolean' ? raw.has_voted : currentVote !== null
  const reactions = Array.isArray(raw.reactions)
    ? raw.reactions
        .map(normalizeBoardReactionSummary)
        .filter((row): row is BoardReactionSummary => row !== null)
    : undefined
  const supportedReactionEmojis = normalizeSupportedReactionEmojis(raw.supported_reaction_emojis)
  return {
    id,
    post_id: postId,
    parent_id: parentId,
    author,
    author_identity: normalizeBoardActorIdentity(raw.author_identity, author),
    content: asString(raw.content, ''),
    created_at: toIsoTimestamp(raw.created_at) ?? '',
    votes,
    vote_balance: score,
    votes_up: votesUp,
    votes_down: votesDown,
    current_vote: currentVote,
    has_voted: hasVoted,
    ...(reactions !== undefined ? { reactions } : {}),
    ...(supportedReactionEmojis !== undefined
      ? { supported_reaction_emojis: supportedReactionEmojis }
      : {}),
  }
}

function normalizeBoardHearth(raw: unknown): BoardHearth | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name, '').trim()
  if (!name) return null
  return {
    name,
    count: asNumber(raw.count, 0),
  }
}

function normalizeBoardFlair(raw: unknown): BoardFlair | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name, '').trim()
  if (!name) return null
  const emoji = asString(raw.emoji, '').trim()
  const label = asString(raw.label, '').trim()
  return {
    name,
    emoji,
    label: label || name,
  }
}

function asStrictStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .filter((item): item is string => typeof item === 'string')
    .map(item => item.trim())
    .filter(Boolean)
}

function normalizeBoardCurationSnapshot(raw: unknown): BoardCurationSnapshot | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const generated_at = asNullableIsoTimestamp(raw.generated_at)
  const submitted_by = asString(raw.submitted_by, '').trim()
  if (!id || !generated_at || !submitted_by) return null
  const ordering = asStrictStringArray(raw.ordering)
  const highlights = asStrictStringArray(raw.highlights)
  const rationale = asString(raw.rationale, '')
  const model = asNullableString(raw.model)
  const healthScore = asNumber(raw.health_score)
  return {
    id,
    generated_at,
    submitted_by,
    model,
    summary: asNullableString(raw.summary),
    ordering,
    highlights,
    tag_suggestions: normalizeBoardCurationTagSuggestions(raw.tag_suggestions),
    answer_matches: normalizeBoardCurationAnswerMatches(raw.answer_matches),
    health_score: healthScore ?? null,
    health_components: normalizeBoardCurationHealthComponents(raw.health_components),
    rationale,
    provenance: raw.provenance,
  }
}

function normalizeBoardCurationTagSuggestions(raw: unknown): BoardCurationSnapshot['tag_suggestions'] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item) => {
    if (!isRecord(item)) return []
    const post_id = asString(item.post_id, '').trim()
    if (!post_id) return []
    return [{
      post_id,
      tags: asStrictStringArray(item.tags),
      rationale: asString(item.rationale, ''),
    }]
  })
}

function normalizeBoardCurationAnswerMatches(raw: unknown): BoardCurationSnapshot['answer_matches'] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item) => {
    if (!isRecord(item)) return []
    const question_post_id = asString(item.question_post_id, '').trim()
    const answer_post_id = asString(item.answer_post_id, '').trim()
    if (!question_post_id || !answer_post_id) return []
    return [{
      question_post_id,
      answer_post_id,
      score: asNumber(item.score, 0),
      rationale: asString(item.rationale, ''),
    }]
  })
}

function normalizeBoardCurationHealthComponents(raw: unknown): BoardCurationSnapshot['health_components'] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item) => {
    if (!isRecord(item)) return []
    const name = asString(item.name, '').trim()
    if (!name) return []
    return [{
      name,
      score: asNumber(item.score, 0),
      weight: asNumber(item.weight, 0),
      rationale: asString(item.rationale, ''),
    }]
  })
}

function normalizeBoardKarmaLedgerEvent(raw: unknown): BoardKarmaLedgerEvent | null {
  if (!isRecord(raw)) return null
  const recipient = asString(raw.recipient, '').trim()
  const voter = asString(raw.voter, '').trim()
  const targetKind = normalizeBoardKarmaTargetKind(raw.target_kind)
  const targetId = asString(raw.target_id, '').trim()
  const tsIso = asNullableIsoTimestamp(raw.ts_iso ?? raw.ts)
  if (!recipient || !voter || !targetKind || !targetId || !tsIso) return null
  return {
    recipient,
    voter,
    target_kind: targetKind,
    target_id: targetId,
    delta: asNumber(raw.delta, 0),
    ts: asNumber(raw.ts, 0),
    ts_iso: tsIso,
  }
}

function normalizeBoardKarmaTotal(raw: unknown): BoardKarmaTotal | null {
  if (!isRecord(raw)) return null
  const agent = asString(raw.agent, '').trim()
  if (!agent) return null
  return {
    agent,
    karma: asNumber(raw.karma, 0),
  }
}

export function normalizeBoardKarmaLedger(raw: unknown): BoardKarmaLedger {
  if (!isRecord(raw)) {
    return { events: [], count: 0, scoring_rule: '', totals: [] }
  }
  const events = Array.isArray(raw.events)
    ? raw.events.map(normalizeBoardKarmaLedgerEvent).filter((row): row is BoardKarmaLedgerEvent => row !== null)
    : []
  const totals = Array.isArray(raw.totals)
    ? raw.totals.map(normalizeBoardKarmaTotal).filter((row): row is BoardKarmaTotal => row !== null)
    : []
  return {
    events,
    count: asInt(raw.count) ?? events.length,
    scoring_rule: asString(raw.scoring_rule, ''),
    totals,
  }
}

function normalizeBoardReactionSummary(raw: unknown): BoardReactionSummary | null {
  if (!isRecord(raw)) return null
  const emoji = asString(raw.emoji, '').trim()
  if (!emoji) return null
  const hasReacted = raw.has_reacted === true || raw.reacted === true
  const recentUserIds = Array.isArray(raw.recent_user_ids)
    ? raw.recent_user_ids
        .map(value => asString(value, '').trim())
        .filter(value => value !== '')
    : []
  return {
    emoji,
    count: asNumber(raw.count, 0),
    reacted: hasReacted,
    has_reacted: hasReacted,
    recent_user_ids: recentUserIds,
  }
}

function normalizeSupportedReactionEmojis(raw: unknown): string[] | undefined {
  if (!Array.isArray(raw)) return undefined
  const values: string[] = []
  const seen = new Set<string>()
  for (const item of raw) {
    if (typeof item !== 'string') return undefined
    const emoji = item.trim()
    if (!emoji || seen.has(emoji)) return undefined
    seen.add(emoji)
    values.push(emoji)
  }
  return values.length > 0 ? values : undefined
}

function normalizeBoardReactionToggleResult(raw: unknown): BoardReactionToggleResult | null {
  if (!isRecord(raw)) return null
  const targetType = asString(raw.target_type, '').trim()
  const targetId = asString(raw.target_id, '').trim()
  const userId = asString(raw.user_id, '').trim()
  const emoji = asString(raw.emoji, '').trim()
  if ((targetType !== 'post' && targetType !== 'comment') || !targetId || !userId || !emoji) {
    return null
  }
  const summary = Array.isArray(raw.summary)
    ? raw.summary.map(normalizeBoardReactionSummary).filter((row): row is BoardReactionSummary => row !== null)
    : []
  return {
    target_type: targetType,
    target_id: targetId,
    user_id: userId,
    emoji,
    reacted: raw.reacted === true,
    summary,
  }
}

function normalizeBoardContextInferenceTargetSource(raw: unknown): BoardContextInferenceTargetSource | undefined {
  const source = asString(raw, '').trim()
  return source === 'explicit_target' || source === 'post_author' ? source : undefined
}

export function normalizeBoardContextInferenceSubmission(raw: unknown): BoardContextInferenceSubmission | null {
  if (!isRecord(raw) || raw.ok !== true) return null
  const requestId = asString(raw.request_id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const postId = asString(raw.post_id, '').trim()
  const status = asString(raw.status, '').trim()
  if (!requestId || !keeperName || !postId || !status) return null
  const message = asString(raw.message, '').trim()
  return {
    ok: true,
    requestId,
    keeperName,
    postId,
    status,
    targetSource: normalizeBoardContextInferenceTargetSource(raw.target_source),
    message: message || undefined,
  }
}

export async function fetchBoard(
  sortBy?: BoardSortMode,
  options?: {
    excludeSystem?: boolean
    excludeAutomation?: boolean
    author?: string
    hearth?: string
  },
): Promise<{ posts: BoardPost[] }> {
  return timeBoardRequest('list', () => runRequest('fetchBoard', async () => {
    const params = new URLSearchParams()
    if (sortBy) params.set('sort_by', sortBy)
    if (options?.excludeSystem) params.set('exclude_system', 'true')
    if (options?.excludeAutomation) params.set('exclude_automation', 'true')
    if (options?.author) params.set('author', options.author)
    if (options?.hearth) params.set('hearth', options.hearth)
    params.set('voter', currentDashboardActor())
    params.set('limit', options?.excludeSystem || options?.excludeAutomation || options?.author || options?.hearth ? '150' : '100')
    const qs = params.toString()
    const raw = await get<{ posts?: unknown[] }>(`/api/v1/board${qs ? `?${qs}` : ''}`)
    const posts = Array.isArray(raw.posts)
      ? raw.posts.map(normalizeBoardPost).filter((row): row is BoardPost => row !== null)
      : []
    return { posts }
  }))
}

export async function fetchBoardHearths(options: {
  excludeSystem?: boolean
  excludeAutomation?: boolean
} = {}): Promise<BoardHearth[]> {
  return runRequest('fetchBoardHearths', async () => {
    const params = new URLSearchParams()
    if (options.excludeSystem) params.set('exclude_system', 'true')
    if (options.excludeAutomation) params.set('exclude_automation', 'true')
    const qs = params.toString()
    const raw = await get<{ hearths?: unknown[] }>(`/api/v1/board/hearths${qs ? `?${qs}` : ''}`)
    return Array.isArray(raw.hearths)
      ? raw.hearths.map(normalizeBoardHearth).filter((row): row is BoardHearth => row !== null)
      : []
  })
}

export async function fetchBoardFlairs(): Promise<BoardFlair[]> {
  return runRequest('fetchBoardFlairs', async () => {
    const raw = await get<{ flairs?: unknown[] }>('/api/v1/board/flairs')
    return Array.isArray(raw.flairs)
      ? raw.flairs.map(normalizeBoardFlair).filter((row): row is BoardFlair => row !== null)
      : []
  })
}

export async function fetchBoardCuration(): Promise<BoardCurationSnapshot | null> {
  return runRequest('fetchBoardCuration', async () => {
    const raw = await get<{ snapshot?: unknown }>('/api/v1/board/curation')
    return raw.snapshot != null ? normalizeBoardCurationSnapshot(raw.snapshot) : null
  })
}

export async function fetchBoardKarmaLedger(options: { agent?: string; limit?: number } = {}): Promise<BoardKarmaLedger> {
  return runRequest('fetchBoardKarmaLedger', async () => {
    const params = new URLSearchParams()
    const agent = options.agent?.trim()
    if (agent) params.set('agent', agent)
    if (typeof options.limit === 'number' && Number.isFinite(options.limit)) {
      params.set('limit', String(Math.trunc(options.limit)))
    }
    const qs = params.toString()
    const raw = await get<unknown>(`/api/v1/board/karma/ledger${qs ? `?${qs}` : ''}`)
    return normalizeBoardKarmaLedger(raw)
  })
}

export async function fetchBoardReactionState(
  targetType: BoardReactionTargetType,
  targetId: string,
): Promise<BoardReactionState> {
  return timeBoardRequest('reaction_summary', () => runRequest('fetchBoardReactionState', async () => {
    const params = new URLSearchParams({
      target_type: targetType,
      target_id: targetId,
    })
    const raw = await get<unknown>(`/api/v1/board/reactions?${params}`)
    if (!isRecord(raw) || !Array.isArray(raw.reactions)) {
      throw new Error('Malformed board reaction state: reactions must be an array')
    }
    const summaries = raw.reactions.map(normalizeBoardReactionSummary)
    if (summaries.some(row => row === null)) {
      throw new Error('Malformed board reaction state: invalid reaction summary')
    }
    const supportedEmojis = normalizeSupportedReactionEmojis(raw.supported_reaction_emojis)
    if (!supportedEmojis || supportedEmojis.length === 0) {
      throw new Error('Malformed board reaction state: supported_reaction_emojis is required')
    }
    return {
      summaries: summaries as BoardReactionSummary[],
      supportedEmojis,
    }
  }))
}

/**
 * Reaction state for a page of targets in one request.
 *
 * The board list is a public, cached projection and reaction state is per
 * viewer -- whether *you* reacted -- so the two cannot travel together. Asking
 * per row made twenty of the twenty-three requests that opening the board sent.
 */
export async function fetchBoardReactionsBatch(
  targetType: BoardReactionTargetType,
  targetIds: readonly string[],
): Promise<{ byTargetId: Map<string, BoardReactionSummary[]>; supportedEmojis: string[] }> {
  const wanted = targetIds.filter(id => id !== '')
  if (wanted.length === 0) return { byTargetId: new Map(), supportedEmojis: [] }
  return timeBoardRequest('reaction_summary', () => runRequest('fetchBoardReactionsBatch', async () => {
    const params = new URLSearchParams({
      target_type: targetType,
      target_ids: wanted.join(','),
    })
    const raw = await get<unknown>(`/api/v1/board/reactions/batch?${params}`)
    if (!isRecord(raw) || !Array.isArray(raw.targets)) {
      throw new Error('Malformed board reaction batch: targets must be an array')
    }
    const supportedEmojis = normalizeSupportedReactionEmojis(raw.supported_reaction_emojis)
    if (!supportedEmojis || supportedEmojis.length === 0) {
      throw new Error('Malformed board reaction batch: supported_reaction_emojis is required')
    }
    const byTargetId = new Map<string, BoardReactionSummary[]>()
    for (const row of raw.targets) {
      if (!isRecord(row) || typeof row.target_id !== 'string' || !Array.isArray(row.reactions)) {
        throw new Error('Malformed board reaction batch: each target needs an id and reactions')
      }
      const summaries = row.reactions.map(normalizeBoardReactionSummary)
      if (summaries.some(entry => entry === null)) {
        throw new Error('Malformed board reaction batch: invalid reaction summary')
      }
      byTargetId.set(row.target_id, summaries as BoardReactionSummary[])
    }
    return { byTargetId, supportedEmojis }
  }))
}

export async function fetchBoardPost(postId: string): Promise<BoardPost & { comments: BoardComment[] }> {
  return timeBoardRequest('detail', () => runRequest('fetchBoardPost', async () => {
    const params = new URLSearchParams({
      format: 'flat',
      voter: currentDashboardActor(),
    })
    const raw = await get<Record<string, unknown>>(`/api/v1/board/${postId}?${params}`)
    const postRaw = isRecord(raw.post) ? raw.post : raw
    const post = normalizeBoardPost(postRaw) ?? {
      id: postId,
      author: 'unknown',
      post_kind: 'direct',
      classification_reason: null,
      title: '게시물',
      body: '',
      content: '',
      meta: null,
      tags: [],
      votes: 0,
      comment_count: 0,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      hearth: null,
      visibility: 'internal',
      expires_at: null,
    }
    const commentsRaw = Array.isArray(raw.comments) ? raw.comments : []
    const comments = commentsRaw
      .map(normalizeBoardComment)
      .filter((row): row is BoardComment => row !== null)
    return { ...post, comments }
  }))
}

export function votePost(postId: string, direction: 'up' | 'down'): Promise<unknown> {
  return post('/api/v1/tools/masc_board_vote', {
    post_id: postId,
    direction,
    voter: defaultBoardVoter(),
  })
}

export function voteComment(commentId: string, direction: 'up' | 'down'): Promise<unknown> {
  return post('/api/v1/tools/masc_board_comment_vote', {
    comment_id: commentId,
    direction,
    voter: defaultBoardVoter(),
  })
}

export async function toggleReaction(
  targetType: BoardReactionTargetType,
  targetId: string,
  emoji: string,
): Promise<BoardReactionToggleResult> {
  return timeBoardRequest('reaction_toggle', async () => {
    const raw = await post<unknown>('/api/v1/board/reactions', {
      target_type: targetType,
      target_id: targetId,
      emoji,
    })
    const normalized = normalizeBoardReactionToggleResult(raw)
    if (!normalized) {
      throw new Error('Malformed board reaction response')
    }
    return normalized
  })
}

export async function requestBoardContextInference(
  postId: string,
  targetKeeper?: string,
): Promise<BoardContextInferenceSubmission> {
  const normalizedPostId = postId.trim()
  if (!normalizedPostId) throw new Error('postId is required')
  const body: Record<string, string> = {
    post_id: normalizedPostId,
  }
  const normalizedTargetKeeper = targetKeeper?.trim()
  if (normalizedTargetKeeper) body.target_keeper = normalizedTargetKeeper
  const raw = await post<unknown>('/api/v1/board/context-inference', body)
  const normalized = normalizeBoardContextInferenceSubmission(raw)
  if (!normalized) {
    throw new Error('Malformed board context inference response')
  }
  return normalized
}

export interface CreateBoardPostOptions {
  hearth?: string
  meta?: Record<string, unknown>
}

export function createPost(
  title: string,
  content: string,
  author: string,
  options: CreateBoardPostOptions = {},
): Promise<unknown> {
  const body: Record<string, unknown> = {
    title,
    content,
    author,
  }
  const hearth = options.hearth?.trim()
  if (hearth) body.hearth = hearth
  if (options.meta && Object.keys(options.meta).length > 0) body.meta = options.meta
  return post(`/api/v1/tools/masc_board_post`, body)
}

export function commentPost(postId: string, author: string, content: string, parentId?: string): Promise<unknown> {
  const body: Record<string, string> = { post_id: postId, author, content }
  if (parentId) body.parent_id = parentId
  return post(`/api/v1/tools/masc_board_comment`, body)
}

// --- SubBoard API ---

function normalizeSubBoardAccess(raw: unknown): SubBoardAccess {
  if (raw === 'members_only' || raw === 'owner_only') return raw
  return 'open'
}

export function normalizeSubBoard(raw: unknown): SubBoard | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const slug = asString(raw.slug, '').trim()
  const name = asString(raw.name, '').trim()
  if (!id || !slug) return null
  return {
    id,
    slug,
    name,
    description: asString(raw.description, ''),
    owner: asString(raw.owner, ''),
    members: asStringList(raw.members),
    access: normalizeSubBoardAccess(raw.access),
    created_at: asNullableIsoTimestamp(raw.created_at) ?? new Date(0).toISOString(),
    post_count: asInt(raw.post_count) ?? 0,
  }
}

export async function fetchSubBoards(): Promise<SubBoard[]> {
  const data = await runRequest('fetchSubBoards', () => get('/api/v1/board/sub-boards'))
  if (!isRecord(data)) return []
  const raw = Array.isArray(data.sub_boards) ? data.sub_boards : []
  return raw.flatMap((r: unknown) => {
    const sb = normalizeSubBoard(r)
    return sb ? [sb] : []
  })
}

export async function fetchSubBoard(subBoardId: string): Promise<SubBoard | null> {
  const data = await runRequest('fetchSubBoard', () => get(`/api/v1/board/sub-boards/${encodeURIComponent(subBoardId)}`))
  return normalizeSubBoard(data)
}

export function createSubBoard(
  slug: string,
  name: string,
  description: string,
  access?: SubBoardAccess,
  members: string[] = [],
): Promise<unknown> {
  const body: Record<string, string | string[]> = { slug, name, description }
  if (access) body.access = access
  const normalizedMembers = members.map(member => member.trim()).filter(Boolean)
  if (normalizedMembers.length > 0) body.members = normalizedMembers
  return post('/api/v1/board/sub-boards', body)
}

export function deleteSubBoard(subBoardId: string): Promise<unknown> {
  return del(`/api/v1/board/sub-boards/${encodeURIComponent(subBoardId)}`)
}

export function updateSubBoard(
  subBoardId: string,
  updates: { name?: string; description?: string; access?: SubBoardAccess; members?: string[] },
): Promise<unknown> {
  const body: Record<string, string | string[]> = {}
  if (updates.name !== undefined) body.name = updates.name
  if (updates.description !== undefined) body.description = updates.description
  if (updates.access !== undefined) body.access = updates.access
  if (updates.members !== undefined) {
    const normalizedMembers = updates.members.map(m => m.trim()).filter(Boolean)
    if (normalizedMembers.length > 0) body.members = normalizedMembers
  }
  return put(`/api/v1/board/sub-boards/${encodeURIComponent(subBoardId)}`, body)
}
