import { signal } from '@preact/signals'
import type { OperatorAttentionItem, OperatorRecommendedAction, RouteState } from './types'
import { isRecord } from './components/common/normalize'
import { isRootTarget } from './components/ops/helpers'

const STORAGE_KEY = 'masc_dashboard_workflow_context'
const CONTEXT_TTL_MS = 15 * 60 * 1000

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function asDisplayString(value: unknown): string | null {
  const text = asString(value)
  if (text) return text
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

function safeStorage(): Storage | null {
  if (typeof window === 'undefined') return null
  try {
    return window.sessionStorage
  }
  catch {
    return null
  }
}

export interface DashboardWorkflowContext {
  id: string
  source_surface: 'mission' | 'execution'
  source_label: string
  action_type: string | null
  target_type: string | null
  target_id: string | null
  focus_kind: string | null
  operation_id: string | null
  summary: string
  payload_preview: string | null
  suggested_payload: Record<string, unknown> | null
  preview: unknown
  evidence: unknown
  created_at: string
}

function normalizePayload(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null
}

function serializeContext(value: DashboardWorkflowContext | null): string | null {
  if (!value) return null
  try {
    return JSON.stringify(value)
  }
  catch {
    return null
  }
}

function parseStoredContext(raw: string | null): DashboardWorkflowContext | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as unknown
    if (!isRecord(parsed)) return null
    const id = asString(parsed.id)
    const sourceSurface = asString(parsed.source_surface)
    const sourceLabel = asString(parsed.source_label)
    const summary = asString(parsed.summary)
    const createdAt = asString(parsed.created_at)
    if (!id || (sourceSurface !== 'mission' && sourceSurface !== 'execution') || !sourceLabel || !summary || !createdAt) return null
    return {
      id,
      source_surface: sourceSurface,
      source_label: sourceLabel,
      action_type: asString(parsed.action_type),
      target_type: asString(parsed.target_type),
      target_id: asString(parsed.target_id),
      focus_kind: asString(parsed.focus_kind),
      operation_id: asString(parsed.operation_id),
      summary,
      payload_preview: asString(parsed.payload_preview),
      suggested_payload: normalizePayload(parsed.suggested_payload),
      preview: parsed.preview ?? null,
      evidence: parsed.evidence ?? null,
      created_at: createdAt,
    }
  }
  catch {
    return null
  }
}

function contextIsFresh(context: DashboardWorkflowContext): boolean {
  const ts = Date.parse(context.created_at)
  if (Number.isNaN(ts)) return false
  return Date.now() - ts <= CONTEXT_TTL_MS
}

function initialContext(): DashboardWorkflowContext | null {
  const storage = safeStorage()
  const parsed = parseStoredContext(storage?.getItem(STORAGE_KEY) ?? null)
  if (!parsed) return null
  if (contextIsFresh(parsed)) return parsed
  storage?.removeItem(STORAGE_KEY)
  return null
}

export const dashboardWorkflowContext = signal<DashboardWorkflowContext | null>(initialContext())

export function persistWorkflowContext(context: DashboardWorkflowContext | null): void {
  const freshContext = context && contextIsFresh(context) ? context : null
  dashboardWorkflowContext.value = freshContext
  const storage = safeStorage()
  if (!storage) return
  if (!freshContext) {
    storage.removeItem(STORAGE_KEY)
    return
  }
  const serialized = serializeContext(freshContext)
  if (!serialized) return
  storage.setItem(STORAGE_KEY, serialized)
}

export function extractActionPayload(
  action?: OperatorRecommendedAction | null,
): Record<string, unknown> | null {
  if (!action) return null
  const direct = normalizePayload(action.suggested_payload)
  if (direct) return direct
  if (isRecord(action.preview)) {
    const previewPayload = normalizePayload(action.preview.payload)
    if (previewPayload) return previewPayload
  }
  return null
}

export function summarizePayloadPreview(payload?: Record<string, unknown> | null): string | null {
  if (!payload) return null
  const message = asDisplayString(payload.message)
  if (message) return message
  const title = asDisplayString(payload.task_title) ?? asDisplayString(payload.title)
  const description = asDisplayString(payload.task_description) ?? asDisplayString(payload.description)
  const reason = asDisplayString(payload.reason)
  const priority = asDisplayString(payload.priority) ?? asDisplayString(payload.task_priority)
  if (title && description) return `${title} · ${description}`
  if (title && priority) return `${title} · P${priority}`
  if (title) return title
  if (description) return description
  if (reason) return reason
  return null
}

function workflowContextId(
  sourceSurface: DashboardWorkflowContext['source_surface'],
  sourceLabel: string,
  actionType: string | null,
  targetType: string | null,
  targetId: string | null,
  focusKind: string | null,
  operationId: string | null,
  createdAt: string,
): string {
  return [
    sourceSurface,
    sourceLabel,
    actionType ?? 'action',
    targetType ?? 'target',
    targetId ?? 'namespace',
    focusKind ?? 'focus',
    operationId ?? 'operation',
    createdAt,
  ].join(':')
}

export function createMissionWorkflowContext(
  action?: OperatorRecommendedAction | null,
  incident?: OperatorAttentionItem | null,
  sourceLabel = '상황판 추천 액션',
): DashboardWorkflowContext {
  const createdAt = new Date().toISOString()
  const payload = extractActionPayload(action)
  const targetType = action?.target_type ?? incident?.target_type ?? null
  const targetId = action?.target_id ?? incident?.target_id ?? null
  const focusKind = incident?.kind ?? action?.action_type ?? null
  const summary = action?.reason ?? incident?.summary ?? sourceLabel
  return {
    id: workflowContextId('mission', sourceLabel, action?.action_type ?? null, targetType, targetId, focusKind, null, createdAt),
    source_surface: 'mission',
    source_label: sourceLabel,
    action_type: action?.action_type ?? null,
    target_type: targetType,
    target_id: targetId,
    focus_kind: focusKind,
    operation_id: null,
    summary,
    payload_preview: summarizePayloadPreview(payload),
    suggested_payload: payload,
    preview: action?.preview ?? null,
    evidence: incident?.evidence ?? null,
    created_at: createdAt,
  }
}


function matchesRouteParams(
  context: DashboardWorkflowContext,
  params: Record<string, string>,
): boolean {
  return (
    (params.source === 'mission' || params.source === 'execution')
    && (params.action_type ?? null) === (context.action_type ?? null)
    && (params.target_type ?? null) === (context.target_type ?? null)
    && (params.target_id ?? null) === (context.target_id ?? null)
    && (params.focus_kind ?? null) === (context.focus_kind ?? null)
    && (params.operation_id ?? null) === (context.operation_id ?? null)
  )
}

export function workflowContextForRoute(routeState: Pick<RouteState, 'params'>): DashboardWorkflowContext | null {
  const { params } = routeState
  if (params.source !== 'mission' && params.source !== 'execution') return null
  const stored = dashboardWorkflowContext.value
  if (stored && contextIsFresh(stored) && matchesRouteParams(stored, params)) return stored
  const createdAt = new Date().toISOString()
  const sourceSurface = params.source === 'execution' ? 'execution' : 'mission'
  return {
    id: workflowContextId(
      sourceSurface,
      sourceSurface === 'execution' ? 'Execution 이어보기' : '상황판 이어보기',
      params.action_type ?? null,
      params.target_type ?? null,
      params.target_id ?? null,
      params.focus_kind ?? null,
      params.operation_id ?? null,
      createdAt,
    ),
    source_surface: sourceSurface,
    source_label: sourceSurface === 'execution' ? 'Execution 이어보기' : '상황판 이어보기',
    action_type: params.action_type ?? null,
    target_type: params.target_type ?? null,
    target_id: params.target_id ?? null,
    focus_kind: params.focus_kind ?? params.action_type ?? null,
    operation_id: params.operation_id ?? null,
    summary:
      sourceSurface === 'execution'
        ? (params.focus_kind
            ? `${params.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`
            : 'Execution에서 이어진 컨텍스트입니다.')
        : (params.focus_kind
            ? `${params.focus_kind} 기준으로 열린 컨텍스트입니다.`
            : '상황판에서 이어진 컨텍스트입니다.'),
    payload_preview: null,
    suggested_payload: null,
    preview: null,
    evidence: null,
    created_at: createdAt,
  }
}

export function workflowInterveneParams(context: DashboardWorkflowContext): Record<string, string> {
  return {
    source: context.source_surface,
    ...(context.action_type ? { action_type: context.action_type } : {}),
    ...(context.target_type ? { target_type: context.target_type } : {}),
    ...(context.target_id ? { target_id: context.target_id } : {}),
    ...(context.focus_kind ? { focus_kind: context.focus_kind } : {}),
    ...(context.operation_id ? { operation_id: context.operation_id } : {}),
  }
}

export function missionInterveneParams(context: DashboardWorkflowContext): Record<string, string> {
  return workflowInterveneParams(context)
}

export function workflowTargetLabel(context?: DashboardWorkflowContext | null): string {
  if (!context?.target_type) return '대상 정보 없음'
  const targetType = isRootTarget(context.target_type) ? '프로젝트' : context.target_type
  return context.target_id ? `${targetType} · ${context.target_id}` : targetType
}

export function workflowActionLabel(actionType?: string | null): string {
  switch (actionType) {
    case 'broadcast':
      return '전체 공지'
    case 'namespace_pause':
    case 'room_pause':
      return '프로젝트 일시정지'
    case 'namespace_resume':
    case 'room_resume':
      return '프로젝트 재개'
    case 'task_inject':
      return '프로젝트 작업 주입'
    case 'team_turn':
      return 'session 업데이트'
    case 'team_note':
      return 'session 노트'
    case 'team_broadcast':
      return 'session 방송'
    case 'team_task_inject':
      return 'session 작업'
    case 'team_stop':
      return 'session 중지'
    case 'keeper_msg':
    case 'keeper_message':
      return 'keeper 메시지'
    case 'keeper_probe':
      return 'keeper probe'
    case 'keeper_recover':
      return 'keeper recover'
    default:
      return actionType?.trim() || '추천 액션'
  }
}
