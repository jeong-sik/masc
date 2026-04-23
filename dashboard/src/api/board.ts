import { get, post, withRetries, defaultBoardVoter } from './core'
import { isRecord, asNullableString, asString, asNumber, asInt, asStringList } from '../components/common/normalize'
import type {
  BoardPost, BoardComment, BoardSortMode,
  GovernanceContextRef,
  GovernanceDecisionItem, GovernanceExecutedRoute,
  GovernanceGuardrailState, GovernanceJudgeSummary, GovernanceJudgment,
  KeeperApprovalQueueItem,
  GovernanceResolvedAction, GovernanceTimelineEvent, PendingConfirmation,
} from '../types'

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

export function normalizePendingConfirmation(raw: unknown): PendingConfirmation | null {
  if (!isRecord(raw)) return null
  const confirmToken = asString(raw.confirm_token ?? raw.token, '').trim()
  if (!confirmToken) return null
  return {
    confirm_token: confirmToken,
    actor: asNullableString(raw.actor) ?? undefined,
    action_type: asNullableString(raw.action_type) ?? undefined,
    target_type: asNullableString(raw.target_type) ?? undefined,
    target_id: asNullableString(raw.target_id),
    delegated_tool: asNullableString(raw.delegated_tool) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at) ?? undefined,
    preview: raw.preview,
  }
}

export function normalizeKeeperApprovalQueueItem(raw: unknown): KeeperApprovalQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  const riskLevel = asString(raw.risk_level, '').trim()
  if (!id || !keeperName || !toolName || !riskLevel) return null
  const runtimeContract = isRecord(raw.runtime_contract)
    ? {
        sandbox_profile: asNullableString(raw.runtime_contract.sandbox_profile),
        network_mode: asNullableString(raw.runtime_contract.network_mode),
        shared_memory_scope: asNullableString(raw.runtime_contract.shared_memory_scope),
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
    selected_model: asNullableString(raw.selected_model),
    disposition: asNullableString(raw.disposition),
    disposition_reason: asNullableString(raw.disposition_reason),
    rule_match: ruleMatch,
    input: raw.input,
    input_preview: asNullableString(raw.input_preview),
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
    model_used: asNullableString(raw.model_used),
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
    kind: asString(raw.kind, 'case'),
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
    status: asNullableString(raw.status) ?? undefined,
    degraded_reason: asNullableString(raw.degraded_reason),
    cached_judgments_visible: typeof raw.cached_judgments_visible === 'boolean'
      ? raw.cached_judgments_visible
      : undefined,
    generated_at: asNullableIsoTimestamp(raw.generated_at),
    expires_at: asNullableIsoTimestamp(raw.expires_at),
    model_used: asNullableString(raw.model_used),
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

  return 'Untitled post'
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
  const stateBlock = asString(raw.state_block, '').trim()
  const classificationReason = asString(raw.classification_reason, '').trim()
  if (source) next.source = source
  if (stateBlock) next.state_block = stateBlock
  if (classificationReason) next.classification_reason = classificationReason
  return Object.keys(next).length > 0 ? next : null
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
  const tags = Array.isArray(raw.tags)
    ? raw.tags.filter((item): item is string => typeof item === 'string' && item.trim() !== '')
    : []

  return {
    id,
    author,
    post_kind:
      (() => {
        const rawKind = asString(raw.post_kind, '').trim().toLowerCase()
        if (rawKind === 'human' || rawKind === 'direct') return 'direct'
        return rawKind === 'automation' || rawKind === 'system' ? rawKind : undefined
      })(),
    classification_reason: asString(raw.classification_reason, '').trim() || null,
    title,
    body,
    content,
    meta: normalizeBoardMeta(raw.meta),
    tags,
    votes,
    vote_balance: score,
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
  }
}

function normalizeBoardComment(raw: unknown): BoardComment | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const postId = asString(raw.post_id, '').trim()
  const author = asString(raw.author, '').trim()
  if (!id || !author) return null
  const parentId = asString(raw.parent_id, '').trim() || null
  return {
    id,
    post_id: postId,
    parent_id: parentId,
    author,
    content: asString(raw.content, ''),
    created_at: toIsoTimestamp(raw.created_at) ?? '',
  }
}

export async function fetchBoard(
  sortBy?: BoardSortMode,
  options?: { excludeSystem?: boolean; excludeAutomation?: boolean; author?: string },
): Promise<{ posts: BoardPost[] }> {
  return withRetries('fetchBoard', async () => {
    const params = new URLSearchParams()
    if (sortBy) params.set('sort_by', sortBy)
    if (options?.excludeSystem) params.set('exclude_system', 'true')
    if (options?.excludeAutomation) params.set('exclude_automation', 'true')
    if (options?.author) params.set('author', options.author)
    params.set('limit', options?.excludeSystem || options?.excludeAutomation || options?.author ? '150' : '100')
    const qs = params.toString()
    const raw = await get<{ posts?: unknown[] }>(`/api/v1/board${qs ? `?${qs}` : ''}`)
    const posts = Array.isArray(raw.posts)
      ? raw.posts.map(normalizeBoardPost).filter((row): row is BoardPost => row !== null)
      : []
    return { posts }
  })
}
export async function fetchBoardPost(postId: string): Promise<BoardPost & { comments: BoardComment[] }> {
  return withRetries('fetchBoardPost', async () => {
    const raw = await get<Record<string, unknown>>(`/api/v1/board/${postId}?format=flat`)
    const postRaw = isRecord(raw.post) ? raw.post : raw
    const post = normalizeBoardPost(postRaw) ?? {
      id: postId,
      author: 'unknown',
      post_kind: 'direct',
      classification_reason: null,
      title: 'Post',
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
  })
}

export function votePost(postId: string, direction: 'up' | 'down'): Promise<unknown> {
  return post('/api/v1/tools/masc_board_vote', {
    post_id: postId,
    direction,
    vote: direction,
    voter: defaultBoardVoter(),
  })
}

export function createPost(title: string, content: string, author: string): Promise<unknown> {
  return post(`/api/v1/tools/masc_board_post`, {
    title,
    content,
    author,
  })
}

export function commentPost(postId: string, author: string, content: string, parentId?: string): Promise<unknown> {
  const body: Record<string, string> = { post_id: postId, author, content }
  if (parentId) body.parent_id = parentId
  return post(`/api/v1/tools/masc_board_comment`, body)
}
