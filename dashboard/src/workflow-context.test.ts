import { describe, it, expect } from 'vitest'
import {
  summarizePayloadPreview,
  extractActionPayload,
  workflowInterveneParams,
  missionInterveneParams,
  workflowTargetLabel,
  workflowActionLabel,
} from './workflow-context'
import type { DashboardWorkflowContext } from './workflow-context'
import type { OperatorRecommendedAction } from './types'

function makeContext(overrides: Partial<DashboardWorkflowContext> = {}): DashboardWorkflowContext {
  return {
    id: 'test-id',
    source_surface: 'mission',
    source_label: 'Test',
    action_type: null,
    target_type: null,
    target_id: null,
    focus_kind: null,
    operation_id: null,
    summary: 'Test summary',
    payload_preview: null,
    suggested_payload: null,
    preview: null,
    evidence: null,
    created_at: new Date().toISOString(),
    ...overrides,
  }
}

// ================================================================
// summarizePayloadPreview
// ================================================================

describe('summarizePayloadPreview', () => {
  it('returns null for null', () => {
    expect(summarizePayloadPreview(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(summarizePayloadPreview(undefined)).toBeNull()
  })

  it('returns message when present', () => {
    expect(summarizePayloadPreview({ message: 'Hello world' })).toBe('Hello world')
  })

  it('returns title · description when both present', () => {
    expect(summarizePayloadPreview({ title: 'Task', description: 'Do it' })).toBe('Task · Do it')
  })

  it('returns task_title · task_description variant', () => {
    expect(summarizePayloadPreview({ task_title: 'T', task_description: 'D' })).toBe('T · D')
  })

  it('returns title · priority when title present but no description', () => {
    expect(summarizePayloadPreview({ title: 'Task', priority: '3' })).toBe('Task · P3')
  })

  it('returns title · task_priority variant', () => {
    expect(summarizePayloadPreview({ title: 'Task', task_priority: '1' })).toBe('Task · P1')
  })

  it('returns title alone when no description or priority', () => {
    expect(summarizePayloadPreview({ title: 'Solo' })).toBe('Solo')
  })

  it('returns description when no title', () => {
    expect(summarizePayloadPreview({ description: 'Only desc' })).toBe('Only desc')
  })

  it('returns reason as fallback', () => {
    expect(summarizePayloadPreview({ reason: 'Because' })).toBe('Because')
  })

  it('returns null when no matching fields', () => {
    expect(summarizePayloadPreview({ foo: 'bar' })).toBeNull()
  })

  it('trims whitespace from values', () => {
    expect(summarizePayloadPreview({ message: '  hello  ' })).toBe('hello')
  })

  it('ignores empty string values', () => {
    expect(summarizePayloadPreview({ message: '', title: 'Fallback' })).toBe('Fallback')
  })

  it('handles number values via asDisplayString', () => {
    expect(summarizePayloadPreview({ priority: 3 })).toBeNull() // no title to pair with
  })
})

// ================================================================
// extractActionPayload
// ================================================================

describe('extractActionPayload', () => {
  it('returns null for null', () => {
    expect(extractActionPayload(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(extractActionPayload(undefined)).toBeNull()
  })

  it('returns null when no suggested_payload or preview', () => {
    const action: OperatorRecommendedAction = { action_type: 'x', target_type: 'y', severity: 'high', reason: 'test' }
    expect(extractActionPayload(action)).toBeNull()
  })

  it('extracts suggested_payload as record', () => {
    const payload = { key: 'value' }
    expect(extractActionPayload({ action_type: 'x', target_type: 'y', severity: 'high', reason: 'test', suggested_payload: payload })).toEqual(payload)
  })

  it('returns null when suggested_payload is not a record', () => {
    expect(extractActionPayload({ action_type: 'x', target_type: 'y', severity: 'high', reason: 'test', suggested_payload: 'string' })).toBeNull()
  })

  it('extracts from preview.payload when no suggested_payload', () => {
    const payload = { nested: true }
    expect(extractActionPayload({ action_type: 'x', target_type: 'y', severity: 'high', reason: 'test', preview: { payload } })).toEqual(payload)
  })

  it('prefers suggested_payload over preview.payload', () => {
    const direct = { source: 'direct' }
    const preview = { source: 'preview' }
    expect(extractActionPayload({
      action_type: 'x',
      target_type: 'y',
      severity: 'high',
      reason: 'test',
      suggested_payload: direct,
      preview: { payload: preview },
    })).toEqual(direct)
  })
})

// ================================================================
// workflowInterveneParams
// ================================================================

describe('workflowInterveneParams', () => {
  it('returns source surface as minimum', () => {
    const params = workflowInterveneParams(makeContext())
    expect(params.source).toBe('mission')
    expect(Object.keys(params)).toEqual(['source'])
  })

  it('includes action_type when present', () => {
    const params = workflowInterveneParams(makeContext({ action_type: 'broadcast' }))
    expect(params.action_type).toBe('broadcast')
  })

  it('includes target_type and target_id when present', () => {
    const params = workflowInterveneParams(makeContext({ target_type: 'keeper', target_id: 'janitor' }))
    expect(params.target_type).toBe('keeper')
    expect(params.target_id).toBe('janitor')
  })

  it('includes focus_kind when present', () => {
    const params = workflowInterveneParams(makeContext({ focus_kind: 'high_cpu' }))
    expect(params.focus_kind).toBe('high_cpu')
  })

  it('includes operation_id when present', () => {
    const params = workflowInterveneParams(makeContext({ operation_id: 'op-1' }))
    expect(params.operation_id).toBe('op-1')
  })

  it('omits null fields', () => {
    const params = workflowInterveneParams(makeContext({ action_type: null }))
    expect(params).not.toHaveProperty('action_type')
  })

  it('returns execution source for execution context', () => {
    const params = workflowInterveneParams(makeContext({ source_surface: 'execution' }))
    expect(params.source).toBe('execution')
  })
})

// ================================================================
// missionInterveneParams
// ================================================================

describe('missionInterveneParams', () => {
  it('delegates to workflowInterveneParams', () => {
    const ctx = makeContext({ target_type: 'agent', target_id: 'dreamer' })
    expect(missionInterveneParams(ctx)).toEqual(workflowInterveneParams(ctx))
  })
})

// ================================================================
// workflowTargetLabel
// ================================================================

describe('workflowTargetLabel', () => {
  it('returns default label for null', () => {
    expect(workflowTargetLabel(null)).toBe('No target')
  })

  it('returns default label for undefined', () => {
    expect(workflowTargetLabel(undefined)).toBe('No target')
  })

  it('returns default label when target_type is null', () => {
    expect(workflowTargetLabel(makeContext({ target_type: null }))).toBe('No target')
  })

  it('returns Namespace for root target', () => {
    expect(workflowTargetLabel(makeContext({ target_type: 'root' }))).toBe('Namespace')
  })

  it('returns Namespace for namespace target', () => {
    expect(workflowTargetLabel(makeContext({ target_type: 'namespace' }))).toBe('Namespace')
  })

  it('returns Namespace for room target', () => {
    expect(workflowTargetLabel(makeContext({ target_type: 'room' }))).toBe('Namespace')
  })

  it('returns type · id for non-root with id', () => {
    expect(workflowTargetLabel(makeContext({ target_type: 'keeper', target_id: 'janitor' }))).toBe('keeper · janitor')
  })

  it('returns type alone for non-root without id', () => {
    expect(workflowTargetLabel(makeContext({ target_type: 'keeper', target_id: null }))).toBe('keeper')
  })
})

// ================================================================
// workflowActionLabel
// ================================================================

describe('workflowActionLabel', () => {
  it('returns "Broadcast" for broadcast', () => {
    expect(workflowActionLabel('broadcast')).toBe('Broadcast')
  })

  it('returns "Pause Namespace" for namespace_pause', () => {
    expect(workflowActionLabel('namespace_pause')).toBe('Pause Namespace')
  })

  it('returns "Pause Namespace" for room_pause', () => {
    expect(workflowActionLabel('room_pause')).toBe('Pause Namespace')
  })

  it('returns "Resume Namespace" for namespace_resume', () => {
    expect(workflowActionLabel('namespace_resume')).toBe('Resume Namespace')
  })

  it('returns "Resume Namespace" for room_resume', () => {
    expect(workflowActionLabel('room_resume')).toBe('Resume Namespace')
  })

  it('returns "Inject Task" for task_inject', () => {
    expect(workflowActionLabel('task_inject')).toBe('Inject Task')
  })

  it('returns "Social Sweep" for social_sweep', () => {
    expect(workflowActionLabel('social_sweep')).toBe('Social Sweep')
  })

  it('returns "Session Update" for team_turn', () => {
    expect(workflowActionLabel('team_turn')).toBe('Session Update')
  })

  it('returns "Session Note" for team_note', () => {
    expect(workflowActionLabel('team_note')).toBe('Session Note')
  })

  it('returns "Session Broadcast" for team_broadcast', () => {
    expect(workflowActionLabel('team_broadcast')).toBe('Session Broadcast')
  })

  it('returns "Session Task" for team_task_inject', () => {
    expect(workflowActionLabel('team_task_inject')).toBe('Session Task')
  })

  it('returns "Stop Session" for team_stop', () => {
    expect(workflowActionLabel('team_stop')).toBe('Stop Session')
  })

  it('returns "Keeper Message" for keeper_msg', () => {
    expect(workflowActionLabel('keeper_msg')).toBe('Keeper Message')
  })

  it('returns "Keeper Message" for keeper_message', () => {
    expect(workflowActionLabel('keeper_message')).toBe('Keeper Message')
  })

  it('returns "keeper probe" for keeper_probe', () => {
    expect(workflowActionLabel('keeper_probe')).toBe('keeper probe')
  })

  it('returns "keeper recover" for keeper_recover', () => {
    expect(workflowActionLabel('keeper_recover')).toBe('keeper recover')
  })

  it('returns raw actionType for unknown values', () => {
    expect(workflowActionLabel('custom_action')).toBe('custom_action')
  })

  it('returns "Recommended Action" for null', () => {
    expect(workflowActionLabel(null)).toBe('Recommended Action')
  })

  it('returns "Recommended Action" for undefined', () => {
    expect(workflowActionLabel(undefined)).toBe('Recommended Action')
  })

  it('returns "Recommended Action" for empty string', () => {
    expect(workflowActionLabel('')).toBe('Recommended Action')
  })
})
