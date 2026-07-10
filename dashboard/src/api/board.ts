import { currentDashboardActor, get, post, del, put, withRetries, defaultBoardVoter } from './core'
import { isRecord, asNullableString, asString, asNumber, asInt, asStringList, asBoolean } from '../components/common/normalize'
import { asKeeperApprovalRiskLevel } from '../lib/governance-risk-level'
import { normalizePendingConfirmation } from '../pending-confirm'
import { timeBoardRequest } from '../board-metrics'
import type {
  BoardActorIdentity, BoardPost, BoardPostOrigin, BoardComment, BoardReactionSummary,
  BoardReactionState, BoardReactionTargetType, BoardReactionToggleResult, BoardSortMode,
  BoardVoteDirection, BoardModerationStatus, BoardContributorQuality,
  BoardClaimEvidenceProjection, BoardClaimEvidenceState,
  BoardCurationSnapshot, BoardKarmaLedger, BoardKarmaLedgerEvent, BoardKarmaTotal,
  GovernanceContextRef,
  GovernanceDecisionItem, GovernanceExecutedRoute,
  GovernanceGuardrailState, GovernanceJudgeSummary, GovernanceJudgment,
  KeeperApprovalQueueItem,
  HitlContextSummary, HitlSuggestedOption, HitlSummaryStatus,
  GovernanceResolvedAction, GovernanceTimelineEvent,
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

function normalizeGovernanceDecisionKind(raw: unknown): GovernanceDecisionItem['kind'] {
  return asString(raw, '').trim().toLowerCase() === 'petition' ? 'petition' : 'case'
}

function normalizeGovernanceJudgeStatus(raw: unknown): GovernanceJudgeSummary['status'] {
  const status = asNullableString(raw)?.trim().toLowerCase()
  switch (status) {
    case 'online':
    case 'refreshing':
    case 'stale_visible':
    case 'offline':
    case 'backoff':
      return status
    default:
      return undefined
  }
}

function normalizeGovernanceJudgeDegradedReason(raw: unknown): GovernanceJudgeSummary['degraded_reason'] {
  const reason = asNullableString(raw)?.trim().toLowerCase()
  switch (reason) {
    case 'timeout':
    case 'error':
    case 'backoff':
      return reason
    default:
      return reason == null ? null : undefined
  }
}

function normalizeBoardActorSource(raw: unknown): BoardActorIdentity['source'] {
  const source = asString(raw, '').trim()
  switch (source) {
    case 'keeper_registry_agent_name':
    case 'keeper_registry_name':
    case 'keeper_alias_contract':
    case 'raw_agent':
      return source
    default:
      return undefined
  }
}

function normalizeBoardContributorBand(raw: unknown): BoardContributorQuality['band'] {
  const band = asString(raw, '').trim().toLowerCase()
  switch (band) {
    case 'low':
    case 'watch':
    case 'strong':
    case 'excellent':
      return band
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

function normalizeHitlSuggestedOption(raw: unknown): HitlSuggestedOption | null {
  if (!isRecord(raw)) return null
  const label = asString(raw.label, '').trim()
  if (!label) return null
  return {
    label,
    rationale: asString(raw.rationale, '').trim(),
    estimated_risk_delta: asKeeperApprovalRiskLevel(raw.estimated_risk_delta) ?? null,
  }
}

function normalizeHitlContextSummary(raw: unknown): HitlContextSummary | null {
  if (!isRecord(raw)) return null
  const summaryText = asString(raw.context_summary, '').trim()
  // A summary with no body carries no operator value; treat it as absent rather
  // than rendering an empty briefing card.
  if (!summaryText) return null
  return {
    summary_version: asInt(raw.summary_version) ?? 0,
    generated_at_iso: asNullableString(raw.generated_at_iso),
    model_run_id: asNullableString(raw.model_run_id),
    context_summary: summaryText,
    key_questions: asStringList(raw.key_questions),
    suggested_options: Array.isArray(raw.suggested_options)
      ? raw.suggested_options
          .map(normalizeHitlSuggestedOption)
          .filter((o): o is HitlSuggestedOption => o !== null)
      : [],
    risk_rationale: asNullableString(raw.risk_rationale),
    uncertainty: asNumber(raw.uncertainty) ?? null,
  }
}

/** Parse the backend `summary_status` wire value into the typed union. Returns
 *  `null` for an absent or contract-violating shape — a malformed status must
 *  not silently read as `not_requested`, which would hide a wiring fault. */
function normalizeHitlSummaryStatus(raw: unknown): HitlSummaryStatus | null {
  if (raw === 'not_requested') return { status: 'not_requested' }
  if (raw === 'pending') return { status: 'pending' }
  if (!isRecord(raw)) return null
  switch (raw.status) {
    case 'available': {
      const summary = normalizeHitlContextSummary(raw.summary)
      return summary ? { status: 'available', summary } : null
    }
    case 'failed':
      return {
        status: 'failed',
        reason: asString(raw.reason, '').trim(),
        retryable: asBoolean(raw.retryable, false),
      }
    default:
      return null
  }
}

export function normalizeKeeperApprovalQueueItem(raw: unknown): KeeperApprovalQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  const riskLevel = asKeeperApprovalRiskLevel(raw.risk_level)
  if (!id || !keeperName || !toolName || !riskLevel) return null
  const runtimeContract = isRecord(raw.runtime_contract)
    ? {
        sandbox_profile: asNullableString(raw.runtime_contract.sandbox_profile),
        network_mode: asNullableString(raw.runtime_contract.network_mode),
        backend: asNullableString(raw.runtime_contract.backend),
        task_id: asNullableString(raw.runtime_contract.task_id),
        goal_id: asNullableString(raw.runtime_contract.goal_id),
        goal_ids: asStringList(raw.runtime_contract.goal_ids),
      }
    : null
  const ruleMatch = isRecord(raw.rule_match)
    ? {
        rule_id: asNullableString(raw.rule_match.rule_id),
        matched_by: asNullableString(raw.rule_match.matched_by),
      }
    : null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    action_key: asNullableString(raw.action_key),
    sandbox_target: asNullableString(raw.sandbox_target),
    risk_level: riskLevel,
    requested_at: asNullableIsoTimestamp(raw.requested_at_iso ?? raw.requested_at),
    waiting_s: asNumber(raw.waiting_s),
    turn_id: asInt(raw.turn_id),
    task_id: asNullableString(raw.task_id),
    goal_id: asNullableString(raw.goal_id),
    goal_ids: asStringList(raw.goal_ids),
    runtime_contract: runtimeContract,
    selected_model: null,
    disposition: asNullableString(raw.disposition),
    disposition_reason: asNullableString(raw.disposition_reason),
    decision: asNullableString(raw.decision),
    rule_match: ruleMatch,
    input: raw.input,
    input_preview: asNullableString(raw.input_preview),
    summary_status: normalizeHitlSummaryStatus(raw.summary_status),
  }
}

function normalizeGovernanceContextRef(raw: unknown): GovernanceContextRef {
  if (!isRecord(raw)) return {}
  return {
    board_post_id: asNullableString(raw.board_post_id),
    task_id: asNullableString(raw.task_id),
    operation_id: asNullableString(raw.operation_id),
  }
}

function normalizeGovernanceResolvedAction(raw: unknown): GovernanceResolvedAction | null {
  if (!isRecord(raw)) return null
  const actionKind = asNullableString(raw.action_kind)
  const resolvedTool = asNullableString(raw.resolved_tool)
  const targetType = asNullableString(raw.target_type)
  const targetId = asNullableString(raw.target_id)
  const reason = asNullableString(raw.reason)
  if (!actionKind && !resolvedTool && !targetType && !reason) return null
  return {
    action_kind: actionKind ?? undefined,
    resolved_tool: resolvedTool,
    target_type: targetType,
    target_id: targetId,
    reason: reason ?? undefined,
    payload_preview: raw.payload_preview,
  }
}

function normalizeGovernanceExecutedRoute(raw: unknown): GovernanceExecutedRoute | null {
  if (!isRecord(raw)) return null
  const actionType = asNullableString(raw.action_type)
  const toolName = asNullableString(raw.tool_name) ?? asNullableString(raw.delegated_tool)
  const confirmationState = asNullableString(raw.confirmation_state)
  const createdAt = asNullableIsoTimestamp(raw.created_at)
  if (!actionType && !toolName && !confirmationState && !createdAt) return null
  return {
    action_type: actionType ?? undefined,
    tool_name: toolName,
    confirmation_state: confirmationState ?? undefined,
    created_at: createdAt,
  }
}

function normalizeGovernanceGuardrailState(raw: unknown): GovernanceGuardrailState | null {
  if (!isRecord(raw)) return null
  const pendingConfirm = normalizePendingConfirmation(raw.pending_confirm)
  const pendingConfirmToken =
    asNullableString(raw.pending_confirm_token) ?? pendingConfirm?.confirm_token ?? null
  return {
    requires_human_gate:
      typeof raw.requires_human_gate === 'boolean' ? raw.requires_human_gate : undefined,
    pending_confirm: pendingConfirm,
    pending_confirm_token: pendingConfirmToken,
    ready_to_execute:
      typeof raw.ready_to_execute === 'boolean' ? raw.ready_to_execute : undefined,
  }
}

export function normalizeGovernanceJudgment(raw: unknown): GovernanceJudgment | null {
  if (!isRecord(raw)) return null
  const summary = asNullableString(raw.summary)
  const targetId = asNullableString(raw.target_id)
  if (!summary && !targetId) return null
  return {
    judgment_id: asNullableString(raw.judgment_id) ?? undefined,
    target_kind: asNullableString(raw.target_kind) ?? undefined,
    target_id: targetId ?? undefined,
    status: asNullableString(raw.status) ?? undefined,
    summary: summary ?? undefined,
    confidence: typeof raw.confidence === 'number' ? raw.confidence : null,
    generated_at: asNullableIsoTimestamp(raw.generated_at),
    expires_at: asNullableIsoTimestamp(raw.expires_at),
    model_used: null,
    keeper_name: asNullableString(raw.keeper_name),
    evidence_refs: asStringList(raw.evidence_refs),
    recommended_action: normalizeGovernanceResolvedAction(raw.recommended_action),
    guardrail_state: normalizeGovernanceGuardrailState(raw.guardrail_state),
    executed_route: normalizeGovernanceExecutedRoute(raw.executed_route),
  }
}

export function normalizeGovernanceDecisionItem(raw: unknown): GovernanceDecisionItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const topic = asString(raw.topic ?? raw.title, '').trim()
  if (!id || !topic) return null
  const context = normalizeGovernanceContextRef(raw.context)
  return {
    kind: normalizeGovernanceDecisionKind(raw.kind),
    id,
    topic,
    status: asString(raw.status ?? raw.state, 'open'),
    origin: asNullableString(raw.origin),
    subject_type: asNullableString(raw.subject_type),
    risk_class: asNullableString(raw.risk_class),
    provenance: asNullableString(raw.provenance),
    auto_execution_state: asNullableString(raw.auto_execution_state),
    petition_count: asInt(raw.petition_count),
    brief_count: asInt(raw.brief_count),
    last_activity_at: asNullableIsoTimestamp(raw.last_activity_at),
    truth_summary: asNullableString(raw.truth_summary) ?? undefined,
    judgment_summary: asNullableString(raw.judgment_summary),
    confidence: typeof raw.confidence === 'number' ? raw.confidence : null,
    related_agents: asStringList(raw.related_agents),
    context,
    linked_board_post_id: asNullableString(raw.linked_board_post_id) ?? context.board_post_id ?? null,
    linked_task_id: asNullableString(raw.linked_task_id) ?? context.task_id ?? null,
    linked_operation_id: asNullableString(raw.linked_operation_id) ?? context.operation_id ?? null,
    linked_session_id: asNullableString(raw.linked_session_id) ?? null,
    recommended_action: normalizeGovernanceResolvedAction(raw.recommended_action),
    executed_route: normalizeGovernanceExecutedRoute(raw.executed_route),
    guardrail_state: normalizeGovernanceGuardrailState(raw.guardrail_state),
    evidence_refs: asStringList(raw.evidence_refs),
  }
}

export function normalizeGovernanceTimelineEvent(raw: unknown): GovernanceTimelineEvent | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind, '').trim()
  if (!kind) return null
  return {
    kind,
    item_kind: asNullableString(raw.item_kind) ?? undefined,
    item_id: asNullableString(raw.item_id) ?? undefined,
    topic: asNullableString(raw.topic) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at),
    summary: asNullableString(raw.summary) ?? undefined,
    actor: asNullableString(raw.actor),
    index: asInt(raw.index),
    decision: asNullableString(raw.decision),
  }
}


export function normalizeGovernanceJudgeSummary(raw: unknown): GovernanceJudgeSummary | undefined {
  if (!isRecord(raw)) return undefined
  return {
    judge_online: typeof raw.judge_online === 'boolean' ? raw.judge_online : undefined,
    refreshing: typeof raw.refreshing === 'boolean' ? raw.refreshing : undefined,
    status: normalizeGovernanceJudgeStatus(raw.status),
    degraded_reason: normalizeGovernanceJudgeDegradedReason(raw.degraded_reason),
    cached_judgments_visible: typeof raw.cached_judgments_visible === 'boolean'
      ? raw.cached_judgments_visible
      : undefined,
    generated_at: asNullableIsoTimestamp(raw.generated_at),
    expires_at: asNullableIsoTimestamp(raw.expires_at),
    model_used: null,
    keeper_name: asNullableString(raw.keeper_name),
    last_error: asNullableString(raw.last_error),
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
  const runtimeAgentName = asString(raw.runtime_agent_name, '').trim()
  return {
    kind,
    id,
    key,
    display_name: displayName,
    raw: original,
    source: normalizeBoardActorSource(raw.source),
    runtime_agent_name: runtimeAgentName || undefined,
  }
}

function normalizeBoardVoteDirection(raw: unknown): BoardVoteDirection | null {
  const direction = asString(raw, '').trim().toLowerCase()
  return direction === 'up' || direction === 'down' ? direction : null
}

function normalizeBoardModerationStatus(raw: unknown): BoardModerationStatus {
  const status = asString(raw, '').trim().toLowerCase()
  switch (status) {
    case 'flagged':
    case 'approved':
    case 'removed':
    case 'hidden':
    case 'warned':
      return status
    default:
      return 'none'
  }
}

function normalizeBoardContributorQuality(raw: unknown): BoardContributorQuality | null {
  if (!isRecord(raw)) return null
  const score = asNumber(raw.score)
  const completionRate = asNumber(raw.completion_rate)
  const responseRate = asNumber(raw.response_rate)
  const boardPosts = asNumber(raw.board_posts)
  const boardComments = asNumber(raw.board_comments)
  const accountabilityScore = asNumber(raw.accountability_score)
  const thompsonConfidence = asNumber(raw.thompson_confidence)
  const source = asString(raw.source, '').trim() || undefined
  const band = normalizeBoardContributorBand(raw.band)
  const autonomyLevel = asString(raw.autonomy_level, '').trim() || undefined
  const rawEvidenceState = asString(raw.evidence_state, '').trim()
  const evidenceState = rawEvidenceState === 'measured' || rawEvidenceState === 'default'
    ? rawEvidenceState
    : undefined

  if (
    score === undefined
    && completionRate === undefined
    && responseRate === undefined
    && boardPosts === undefined
    && boardComments === undefined
    && accountabilityScore === undefined
    && thompsonConfidence === undefined
    && source === undefined
    && band === undefined
    && autonomyLevel === undefined
    && evidenceState === undefined
  ) return null
  return {
    score,
    band,
    source,
    completion_rate: completionRate,
    response_rate: responseRate,
    board_posts: boardPosts,
    board_comments: boardComments,
    accountability_score: accountabilityScore,
    autonomy_level: autonomyLevel,
    thompson_confidence: thompsonConfidence,
    evidence_state: evidenceState,
  }
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
  const body = (asString(raw.body, '').trim() || asString(raw.content, '').trim())
  const content = body
  if (!id || !author) return null

  const score = asNumber(raw.score, 0)
  const votesUp = asNumber(raw.votes_up, 0)
  const votesDown = asNumber(raw.votes_down, 0)
  const votes = asNumber(raw.votes, score || (votesUp - votesDown))
  const currentVote = normalizeBoardVoteDirection(raw.current_vote)
  const hasVoted = typeof raw.has_voted === 'boolean' ? raw.has_voted : currentVote !== null
  const voteBlind = raw.vote_blind === true
  const voteBlindReason = asString(raw.vote_blind_reason, '').trim() || undefined
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
    content,
    meta: normalizeBoardMeta(raw.meta),
    tags,
    votes,
    vote_balance: score,
    vote_blind: voteBlind,
    ...(voteBlindReason ? { vote_blind_reason: voteBlindReason } : {}),
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
    report_count: Math.max(0, Math.trunc(asNumber(raw.report_count, 0))),
    moderation_status: normalizeBoardModerationStatus(raw.moderation_status),
    contributor_quality: normalizeBoardContributorQuality(raw.contributor_quality),
    claim_evidence: normalizeBoardClaimEvidence(raw.claim_evidence),
    ...(reactions !== undefined ? { reactions } : {}),
    ...(supportedReactionEmojis !== undefined
      ? { supported_reaction_emojis: supportedReactionEmojis }
      : {}),
    origin: normalizeBoardPostOrigin(raw.origin),
  }
}

function normalizeBoardClaimEvidenceState(raw: unknown): BoardClaimEvidenceState | null {
  switch (asString(raw, '').trim()) {
    case 'needs_evidence':
    case 'source_snapshot_stale':
    case 'artifact_missing':
    case 'verified':
      return asString(raw, '').trim() as BoardClaimEvidenceState
    default:
      return null
  }
}

function normalizeBoardClaimEvidence(raw: unknown): BoardClaimEvidenceProjection | null {
  if (!isRecord(raw)) return null
  const state = normalizeBoardClaimEvidenceState(raw.state)
  if (!state) return null
  return {
    source: asString(raw.source, '').trim() || undefined,
    target_post_id: asString(raw.target_post_id, '').trim() || undefined,
    state,
    label: asString(raw.label, '').trim() || state,
    total_count: Math.max(0, Math.trunc(asNumber(raw.total_count, 0))),
    allowed_count: Math.max(0, Math.trunc(asNumber(raw.allowed_count, 0))),
    rejected_count: Math.max(0, Math.trunc(asNumber(raw.rejected_count, 0))),
    artifact_missing_count: Math.max(0, Math.trunc(asNumber(raw.artifact_missing_count, 0))),
    artifact_unknown_count: Math.max(0, Math.trunc(asNumber(raw.artifact_unknown_count, 0))),
    missing_source_snapshot_count: Math.max(0, Math.trunc(asNumber(raw.missing_source_snapshot_count, 0))),
    stale_source_snapshot_count: Math.max(0, Math.trunc(asNumber(raw.stale_source_snapshot_count, 0))),
    artifact_not_verified_count: Math.max(0, Math.trunc(asNumber(raw.artifact_not_verified_count, 0))),
    latest_decision: asString(raw.latest_decision, '').trim() || undefined,
    latest_recorded_at: asNumber(raw.latest_recorded_at),
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
  const voteBlind = raw.vote_blind === true
  const voteBlindReason = asString(raw.vote_blind_reason, '').trim() || undefined
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
    vote_blind: voteBlind,
    ...(voteBlindReason ? { vote_blind_reason: voteBlindReason } : {}),
    current_vote: currentVote,
    has_voted: hasVoted,
    report_count: Math.max(0, Math.trunc(asNumber(raw.report_count, 0))),
    moderation_status: normalizeBoardModerationStatus(raw.moderation_status),
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
    blindVotes?: boolean
  },
): Promise<{ posts: BoardPost[] }> {
  return timeBoardRequest('list', () => withRetries('fetchBoard', async () => {
    const params = new URLSearchParams()
    if (sortBy) params.set('sort_by', sortBy)
    if (options?.excludeSystem) params.set('exclude_system', 'true')
    if (options?.excludeAutomation) params.set('exclude_automation', 'true')
    if (options?.author) params.set('author', options.author)
    if (options?.hearth) params.set('hearth', options.hearth)
    params.set('voter', currentDashboardActor())
    if (options?.blindVotes) params.set('blind_votes', 'true')
    params.set('limit', options?.excludeSystem || options?.excludeAutomation || options?.author || options?.hearth ? '150' : '100')
    const qs = params.toString()
    const raw = await get<{ posts?: unknown[] }>(`/api/v1/board${qs ? `?${qs}` : ''}`)
    const posts = Array.isArray(raw.posts)
      ? raw.posts.map(normalizeBoardPost).filter((row): row is BoardPost => row !== null)
      : []
    return { posts }
  }))
}

export async function fetchBoardHearths(): Promise<BoardHearth[]> {
  return withRetries('fetchBoardHearths', async () => {
    const raw = await get<{ hearths?: unknown[] }>('/api/v1/board/hearths')
    return Array.isArray(raw.hearths)
      ? raw.hearths.map(normalizeBoardHearth).filter((row): row is BoardHearth => row !== null)
      : []
  })
}

export async function fetchBoardFlairs(): Promise<BoardFlair[]> {
  return withRetries('fetchBoardFlairs', async () => {
    const raw = await get<{ flairs?: unknown[] }>('/api/v1/board/flairs')
    return Array.isArray(raw.flairs)
      ? raw.flairs.map(normalizeBoardFlair).filter((row): row is BoardFlair => row !== null)
      : []
  })
}

export async function fetchBoardCuration(): Promise<BoardCurationSnapshot | null> {
  return withRetries('fetchBoardCuration', async () => {
    const raw = await get<{ snapshot?: unknown }>('/api/v1/board/curation')
    return raw.snapshot != null ? normalizeBoardCurationSnapshot(raw.snapshot) : null
  })
}

export async function fetchBoardKarmaLedger(options: { agent?: string; limit?: number } = {}): Promise<BoardKarmaLedger> {
  return withRetries('fetchBoardKarmaLedger', async () => {
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
  return timeBoardRequest('reaction_summary', () => withRetries('fetchBoardReactionState', async () => {
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
    const supportedEmojis = normalizeSupportedReactionEmojis(raw.supported_emojis)
    if (!supportedEmojis || supportedEmojis.length === 0) {
      throw new Error('Malformed board reaction state: supported_emojis is required')
    }
    return {
      summaries: summaries as BoardReactionSummary[],
      supportedEmojis,
    }
  }))
}

export async function fetchBoardPost(postId: string): Promise<BoardPost & { comments: BoardComment[] }> {
  return timeBoardRequest('detail', () => withRetries('fetchBoardPost', async () => {
    const params = new URLSearchParams({
      format: 'flat',
      voter: currentDashboardActor(),
      blind_votes: 'true',
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
    vote: direction,
    voter: defaultBoardVoter(),
  })
}

export function voteComment(commentId: string, direction: 'up' | 'down'): Promise<unknown> {
  return post('/api/v1/tools/masc_board_comment_vote', {
    comment_id: commentId,
    direction,
    vote: direction,
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
  const data = await withRetries('fetchSubBoards', () => get('/api/v1/board/sub-boards'))
  if (!isRecord(data)) return []
  const raw = Array.isArray(data.sub_boards) ? data.sub_boards : []
  return raw.flatMap((r: unknown) => {
    const sb = normalizeSubBoard(r)
    return sb ? [sb] : []
  })
}

export async function fetchSubBoard(subBoardId: string): Promise<SubBoard | null> {
  const data = await withRetries('fetchSubBoard', () => get(`/api/v1/board/sub-boards/${encodeURIComponent(subBoardId)}`))
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
