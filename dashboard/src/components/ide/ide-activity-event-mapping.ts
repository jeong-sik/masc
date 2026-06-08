import { get } from '../../api/core'
import { fetchIdeEvents, type IdeBridgeEvent } from '../../api/ide'
import { asRecord, isPositiveSafeInteger } from '../common/normalize'
import { isRecord } from '../../lib/type-guards'
import { normalizeIdeContextFilePath } from './ide-state'
import type { RunActivityContext, RunActivityEvent, RunActivityVerb } from './run-activity-store'

const FALLBACK_VERB_MAP: Readonly<Record<string, RunActivityVerb>> = {
  approved: 'approved',
  committed: 'committed',
  flagged: 'flagged',
}
const DEFAULT_VERB: RunActivityVerb = 'noted'

export interface ApiActivityEvent {
  readonly seq: number
  readonly ts_ms: number
  readonly ts_iso: string
  readonly workspace_id: string
  readonly kind: string
  readonly actor?: { readonly kind: string; readonly id: string } | null
  readonly subject?: { readonly kind: string; readonly id: string } | null
  readonly payload?: unknown
  readonly tags?: ReadonlyArray<string>
  readonly context?: RunActivityContext
}

export interface ApiActivityResponse {
  readonly events?: ReadonlyArray<ApiActivityEvent>
  readonly latest_seq?: number
}

export interface ActivityFetchResult {
  readonly events: ReadonlyArray<RunActivityEvent>
  readonly workspaceId: string
  readonly ok: boolean
}

export const DEFAULT_WORKSPACE_ID = 'run-default'
type MutableRunActivityContext = {
  -readonly [K in keyof RunActivityContext]?: RunActivityContext[K]
}

export function verbFromKind(kind: string): RunActivityVerb {
  const tail = kind.includes('.') ? kind.slice(kind.lastIndexOf('.') + 1) : kind
  return FALLBACK_VERB_MAP[tail] ?? DEFAULT_VERB
}

export function targetFromSubject(subject: ApiActivityEvent['subject'], kind: string): string {
  if (!subject) return kind
  return `${subject.kind}:${subject.id}`
}

export function detailFromPayload(payload: unknown, kind: string): string | undefined {
  if (isRecord(payload)) {
    const summary = payload['summary'] ?? payload['title'] ?? payload['body'] ?? payload['reason']
    if (typeof summary === 'string' && summary.trim() !== '') {
      const truncated = summary.length > 120 ? summary.slice(0, 117) + '...' : summary
      return truncated
    }
  }
  return kind
}

export function mapApiEvent(event: ApiActivityEvent, workspaceId: string): RunActivityEvent {
  return {
    id: `evt-${event.seq}`,
    run_id: workspaceId,
    timestamp_ms: event.ts_ms,
    keeper_id: event.actor?.id ?? 'system',
    verb: verbFromKind(event.kind),
    target: targetFromSubject(event.subject, event.kind),
    detail: detailFromPayload(event.payload, event.kind),
    kind: event.kind,
    tags: event.tags ?? [],
    context: event.context ?? contextFromPayloadAndTags(event.payload, event.tags ?? []),
  }
}

export async function fetchActivityEvents(): Promise<ActivityFetchResult> {
  const graph = await fetchActivityGraphEvents()
  const bridgeEvents = await fetchIdeBridgeRunActivityEvents(graph.workspaceId)
  return {
    ...graph,
    events: mergeRunActivityEvents(graph.events, bridgeEvents),
  }
}

async function fetchActivityGraphEvents(): Promise<ActivityFetchResult> {
  try {
    const data = await get<ApiActivityResponse>('/api/v1/activity/events?limit=50')
    const rawEvents = data.events
    if (!Array.isArray(rawEvents) || rawEvents.length === 0) {
      return { events: [], workspaceId: DEFAULT_WORKSPACE_ID, ok: true }
    }
    const workspaceId = rawEvents[0].workspace_id || DEFAULT_WORKSPACE_ID
    const mapped = rawEvents.map(e => mapApiEvent(e, workspaceId))
    return { events: mapped, workspaceId, ok: true }
  } catch {
    return { events: [], workspaceId: DEFAULT_WORKSPACE_ID, ok: false }
  }
}

async function fetchIdeBridgeRunActivityEvents(
  workspaceId: string,
): Promise<ReadonlyArray<RunActivityEvent>> {
  try {
    const events = await fetchIdeEvents({ limit: 50 })
    return events.map((event, index) => mapIdeBridgeEvent(event, workspaceId, index))
  } catch {
    return []
  }
}

export function mergeRunActivityEvents(
  graphEvents: ReadonlyArray<RunActivityEvent>,
  bridgeEvents: ReadonlyArray<RunActivityEvent>,
): ReadonlyArray<RunActivityEvent> {
  if (bridgeEvents.length === 0) return graphEvents
  if (graphEvents.length === 0) return bridgeEvents
  return [...graphEvents, ...bridgeEvents].sort(compareRunActivityEvents)
}

export function mapIdeBridgeEvent(
  event: IdeBridgeEvent,
  workspaceId: string,
  index: number,
): RunActivityEvent {
  return {
    id: `ide-${event.type}-${event.turn_id}-${event.timestamp_ms}-${index}`,
    run_id: workspaceId,
    timestamp_ms: event.timestamp_ms,
    keeper_id: event.keeper_id,
    verb: 'noted',
    target: bridgeEventTarget(event),
    detail: bridgeEventDetail(event),
    kind: `ide.bridge.${event.type}`,
    tags: [`ide:${event.type}`, `turn:${event.turn_id}`],
    context: bridgeEventContext(event),
  }
}

function bridgeEventTarget(event: IdeBridgeEvent): string {
  if (event.type === 'tool') return `tool:${event.tool_name}`
  if (event.type === 'turn') return `turn:${event.phase}`
  return `pr:${event.pr_number}`
}

function bridgeEventDetail(event: IdeBridgeEvent): string {
  if (event.type === 'tool') {
    const outcome = event.typed_outcome || event.outcome
    return `${outcome}: ${event.summary}`
  }
  if (event.type === 'turn') {
    return [event.phase, event.model_used, event.stop_reason]
      .filter((item): item is string => typeof item === 'string' && item.trim() !== '')
      .join(' · ') || event.phase
  }
  return event.pr_title || event.pull_request_url || event.pr_state || `PR ${event.pr_number}`
}

function bridgeEventContext(event: IdeBridgeEvent): RunActivityContext | undefined {
  const context: MutableRunActivityContext = {}
  if (event.turn_id) context.log_id = event.turn_id
  if (event.type === 'tool') {
    const filePath = event.file_path ? normalizeIdeContextFilePath(event.file_path) : null
    if (filePath) context.file_path = filePath
    mergeCommandDescriptorContext(context, event.command_descriptor)
  } else if (event.type === 'pr') {
    if (event.pr_number > 0) context.pr_id = String(event.pr_number)
  }
  return Object.keys(context).length === 0 ? undefined : context
}

function mergeCommandDescriptorContext(
  context: MutableRunActivityContext,
  descriptor: unknown,
): void {
  if (!isRecord(descriptor)) return
  const prNumber = positiveInteger(descriptor.pr_number)
  if (prNumber !== undefined) context.pr_id = String(prNumber)
  const branch = stringValue(descriptor.branch)
  if (branch) context.git_ref = branch
}

function contextFromPayloadAndTags(
  payload: unknown,
  tags: ReadonlyArray<string>,
): RunActivityContext | undefined {
  const next: MutableRunActivityContext = {}
  mergePayloadContext(next, payload)
  for (const tag of tags) mergeTagContext(next, tag)
  return Object.keys(next).length === 0 ? undefined : next
}

function mergePayloadContext(next: MutableRunActivityContext, payload: unknown): void {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return
  const record = payload as Record<string, unknown>
  mergeContextRecord(next, asRecord(record.context))
  mergeContextRecord(next, asRecord(record.evidence_ref))
  const failureEnvelope = asRecord(record.failure_envelope)
  mergeContextRecord(next, asRecord(failureEnvelope?.evidence_ref))
  mergeContextRecord(next, asRecord(record.tool_args))
  mergeContextRecord(next, asRecord(record.input))
  mergeContextRecord(next, record, true)
}

function mergeContextRecord(
  next: MutableRunActivityContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const filePath = stringValue(record.file_path)
    ?? stringValue(record.path)
    ?? stringValue(record.file)
  const normalizedFilePath = filePath ? normalizeIdeContextFilePath(filePath) : null
  if (normalizedFilePath && (overwrite || next.file_path === undefined)) next.file_path = normalizedFilePath
  const line = positiveInteger(record.line)
    ?? positiveInteger(record.line_start)
    ?? positiveInteger(record.lineno)
  if (line !== undefined && (overwrite || next.line === undefined)) next.line = line
  const goalId = stringValue(record.goal_id)
  if (goalId && (overwrite || next.goal_id === undefined)) next.goal_id = goalId
  const taskId = stringValue(record.task_id)
  if (taskId && (overwrite || next.task_id === undefined)) next.task_id = taskId
  const boardPostId = stringValue(record.board_post_id) ?? stringValue(record.post_id)
  if (boardPostId && (overwrite || next.board_post_id === undefined)) next.board_post_id = boardPostId
  const commentId = stringValue(record.comment_id)
    ?? stringValue(record.reply_id)
    ?? numberString(record.comment_number)
  if (commentId && (overwrite || next.comment_id === undefined)) next.comment_id = commentId
  const prId = stringValue(record.pr_id)
    ?? stringValue(record.pull_request)
    ?? numberString(record.pr_number)
  if (prId && (overwrite || next.pr_id === undefined)) next.pr_id = prId
  const gitRef = stringValue(record.git_ref)
    ?? stringValue(record.commit)
    ?? stringValue(record.branch)
  if (gitRef && (overwrite || next.git_ref === undefined)) next.git_ref = gitRef
  const logId = stringValue(record.log_id)
  if (logId && (overwrite || next.log_id === undefined)) next.log_id = logId
  const sessionId = stringValue(record.session_id)
  if (sessionId && (overwrite || next.session_id === undefined)) next.session_id = sessionId
  const operationId = stringValue(record.operation_id)
  if (operationId && (overwrite || next.operation_id === undefined)) next.operation_id = operationId
  const workerRunId = stringValue(record.worker_run_id)
  if (workerRunId && (overwrite || next.worker_run_id === undefined)) next.worker_run_id = workerRunId
}

function mergeTagContext(next: MutableRunActivityContext, rawTag: string): void {
  const tag = rawTag.trim()
  if (tag === '') return
  const separator = tag.indexOf(':')
  if (separator <= 0) return
  const key = tag.slice(0, separator).trim().toLowerCase()
  const value = tag.slice(separator + 1).trim()
  if (value === '') return

  if (key === 'file') {
    const match = value.match(/^(.+?)(?::([1-9][0-9]*))?$/)
    const path = match?.[1]
    const normalizedPath = path ? normalizeIdeContextFilePath(path) : null
    if (!normalizedPath) return
    next.file_path = normalizedPath
    if (match?.[2]) next.line = Number.parseInt(match[2], 10)
    return
  }
  if (key === 'line') {
    const line = Number.parseInt(value, 10)
    if (isPositiveSafeInteger(line)) next.line = line
    return
  }
  if (key === 'goal') next.goal_id = value
  else if (key === 'task') next.task_id = value
  else if (key === 'board' || key === 'post') next.board_post_id = value
  else if (key === 'comment' || key === 'reply') next.comment_id = value
  else if (key === 'pr' || key === 'pull_request' || key === 'review') next.pr_id = value
  else if (key === 'git' || key === 'commit' || key === 'branch') next.git_ref = value
  else if (key === 'log' || key === 'telemetry') next.log_id = value
  else if (key === 'session' || key === 'session_id') next.session_id = value
  else if (key === 'operation' || key === 'operation_id' || key === 'op') next.operation_id = value
  else if (key === 'worker_run' || key === 'worker_run_id' || key === 'worker') next.worker_run_id = value
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function numberString(value: unknown): string | undefined {
  return isPositiveSafeInteger(value) ? String(value) : undefined
}

function positiveInteger(value: unknown): number | undefined {
  return isPositiveSafeInteger(value) ? value : undefined
}

function compareRunActivityEvents(left: RunActivityEvent, right: RunActivityEvent): number {
  if (left.timestamp_ms !== right.timestamp_ms) return right.timestamp_ms - left.timestamp_ms
  return left.id.localeCompare(right.id)
}
