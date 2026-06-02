import { isRecord, asString, asInt, asNullableString, asNumber } from '../../components/common/normalize'

export type AnnotationKind = 'Comment' | 'Decision' | 'Question' | 'Bookmark'

export interface IdeAnnotation {
  readonly id: string
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly kind: AnnotationKind
  readonly content: string
  readonly goal_id: string | null
  readonly task_id: string | null
  readonly board_post_id?: string | null
  readonly comment_id?: string | null
  readonly pr_id?: string | null
  readonly git_ref?: string | null
  readonly log_id?: string | null
  readonly session_id?: string | null
  readonly operation_id?: string | null
  readonly worker_run_id?: string | null
  readonly created_at_ms: number
  readonly updated_at_ms: number
}

export type RegionSourceType = 'tool_call' | 'manual'

export interface IdeCodeRegion {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly source_type: RegionSourceType
  readonly source_tool_name: string | null
  readonly source_turn: number | null
  readonly source_note: string | null
  readonly timestamp_ms: number
}

function asAnnotationKind(value: unknown): AnnotationKind {
  const s = asString(value, '')
  switch (s) {
    case 'Decision':
    case 'Question':
    case 'Bookmark':
      return s
    default:
      return 'Comment'
  }
}

export function parseIdeAnnotation(value: unknown): IdeAnnotation | null {
  if (!isRecord(value)) return null
  return {
    id: asString(value.id, ''),
    file_path: asString(value.file_path, ''),
    line_start: (asInt(value.line_start) ?? 0),
    line_end: (asInt(value.line_end) ?? 0),
    keeper_id: asString(value.keeper_id, ''),
    kind: asAnnotationKind(value.kind),
    content: asString(value.content, ''),
    goal_id: asNullableString(value.goal_id),
    task_id: asNullableString(value.task_id),
    board_post_id: asNullableString(value.board_post_id),
    comment_id: asNullableString(value.comment_id),
    pr_id: asNullableString(value.pr_id),
    git_ref: asNullableString(value.git_ref),
    log_id: asNullableString(value.log_id),
    session_id: asNullableString(value.session_id),
    operation_id: asNullableString(value.operation_id),
    worker_run_id: asNullableString(value.worker_run_id),
    created_at_ms: asNumber(value.created_at_ms, 0),
    updated_at_ms: asNumber(value.updated_at_ms, 0),
  }
}

export function parseIdeAnnotations(value: unknown): ReadonlyArray<IdeAnnotation> {
  if (!Array.isArray(value)) return []
  return value.map(parseIdeAnnotation).filter((a): a is IdeAnnotation => a !== null)
}

export function parseIdeCodeRegion(value: unknown): IdeCodeRegion | null {
  if (!isRecord(value)) return null
  const source = isRecord(value.source) ? value.source : {}
  const sourceType = asString(source.type, '')
  return {
    file_path: asString(value.file_path, ''),
    line_start: (asInt(value.line_start) ?? 0),
    line_end: (asInt(value.line_end) ?? 0),
    keeper_id: asString(value.keeper_id, ''),
    source_type: sourceType === 'tool_call' || sourceType === 'manual' ? sourceType : 'manual',
    source_tool_name: asNullableString(source.tool_name),
    source_turn: sourceType === 'tool_call' ? (asInt(source.turn) ?? 0) : null,
    source_note: sourceType === 'manual' ? asNullableString(source.note) : null,
    timestamp_ms: asNumber(value.timestamp_ms, 0),
  }
}

export function parseIdeCodeRegions(value: unknown): ReadonlyArray<IdeCodeRegion> {
  if (!Array.isArray(value)) return []
  return value.map(parseIdeCodeRegion).filter((r): r is IdeCodeRegion => r !== null)
}
