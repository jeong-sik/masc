import { signal } from '@preact/signals'
import type { OperatorRecommendedAction, RouteState } from './types'
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
      sourceSurface === 'execution' ? 'Continue execution' : 'Continue mission board',
      params.action_type ?? null,
      params.target_type ?? null,
      params.target_id ?? null,
      params.focus_kind ?? null,
      params.operation_id ?? null,
      createdAt,
    ),
    source_surface: sourceSurface,
    source_label: sourceSurface === 'execution' ? 'Continue execution' : 'Continue mission board',
    action_type: params.action_type ?? null,
    target_type: params.target_type ?? null,
    target_id: params.target_id ?? null,
    focus_kind: params.focus_kind ?? params.action_type ?? null,
    operation_id: params.operation_id ?? null,
    summary:
      sourceSurface === 'execution'
        ? (params.focus_kind
            ? `Execution context opened from ${params.focus_kind}.`
            : 'Context continued from Execution.')
        : (params.focus_kind
            ? `Context opened from ${params.focus_kind}.`
            : 'Context continued from Mission Board.'),
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
  if (!context?.target_type) return 'No target'
  const targetType = isRootTarget(context.target_type) ? 'Namespace' : context.target_type
  return context.target_id ? `${targetType} · ${context.target_id}` : targetType
}

export function workflowActionLabel(actionType?: string | null): string {
  switch (actionType) {
    case 'broadcast':
      return 'Broadcast'
    case 'namespace_pause':
    case 'room_pause':
      return 'Pause Namespace'
    case 'namespace_resume':
    case 'room_resume':
      return 'Resume Namespace'
    case 'task_inject':
      return 'Inject Task'
    case 'social_sweep':
      return 'Social Sweep'
    case 'team_turn':
      return 'Session Update'
    case 'team_note':
      return 'Session Note'
    case 'team_broadcast':
      return 'Session Broadcast'
    case 'team_task_inject':
      return 'Session Task'
    case 'team_stop':
      return 'Stop Session'
    case 'keeper_msg':
    case 'keeper_message':
      return 'Keeper Message'
    case 'keeper_probe':
      return 'Keeper Probe'
    case 'keeper_recover':
      return 'Keeper Recover'
    case 'keeper_github_identity_status':
      return 'GitHub Identity Status'
    case 'keeper_github_identity_login_prepare':
      return 'GitHub Login Prep'
    default:
      return actionType?.trim() || 'Recommended Action'
  }
}
