import type { OperatorRecommendedAction, RouteState } from './types'
import { isRecord, asNullableString, asRecord } from './components/common/normalize'
import { isRootTarget } from './components/ops/helpers'

function asDisplayString(value: unknown): string | null {
  const text = asNullableString(value)
  if (text) return text
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
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

export function extractActionPayload(
  action?: OperatorRecommendedAction | null,
): Record<string, unknown> | null {
  if (!action) return null
  const direct = asRecord(action.suggested_payload)
  if (direct) return direct
  if (isRecord(action.preview)) {
    const previewPayload = asRecord(action.preview.payload)
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

export function workflowContextForRoute(routeState: Pick<RouteState, 'params'>): DashboardWorkflowContext | null {
  const { params } = routeState
  if (params.source !== 'mission' && params.source !== 'execution') return null
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
    case 'workspace_pause':
      return 'Pause Namespace'
    case 'namespace_resume':
    case 'workspace_resume':
      return 'Resume Namespace'
    case 'task_inject':
      return 'Inject Task'
    case 'keeper_msg':
    case 'keeper_message':
      return 'Keeper Message'
    case 'keeper_probe':
      return 'Keeper Probe'
    case 'keeper_recover':
      return 'Keeper Recover'
    default:
      return actionType?.trim() || 'Recommended Action'
  }
}
