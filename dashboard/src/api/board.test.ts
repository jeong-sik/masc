import { describe, expect, it } from 'vitest'
import {
  derivePostTitle,
  sanitizeBoardTitle,
  asNullableIsoTimestamp,
  normalizePendingConfirmation,
  normalizeKeeperApprovalQueueItem,
  normalizeGovernanceJudgment,
  normalizeGovernanceDecisionItem,
  normalizeGovernanceExecutionOrder,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
} from './board'

// ================================================================
// board title helpers (existing)
// ================================================================

describe('board title helpers', () => {
  it('strips markdown headings from derived titles', () => {
    expect(derivePostTitle('## Deploy Plan\n\nBody')).toBe('Deploy Plan')
  })

  it('skips fenced code when deriving fallback titles', () => {
    expect(derivePostTitle('```md\n# sample\n```\n\n## Real Title\ncontent')).toBe('Real Title')
  })

  it('sanitizes explicit board titles before display', () => {
    expect(sanitizeBoardTitle('## Incident Review')).toBe('Incident Review')
  })
})

// ================================================================
// derivePostTitle (expanded)
// ================================================================

describe('derivePostTitle expanded', () => {
  it('extracts first non-empty line', () => {
    expect(derivePostTitle('Hello world')).toBe('Hello world')
  })

  it('skips leading blank lines', () => {
    expect(derivePostTitle('\n\nActual title')).toBe('Actual title')
  })

  it('strips [flair:...] prefix', () => {
    expect(derivePostTitle('[flair:alert] Important notice')).toBe('Important notice')
  })

  it('strips blockquote prefix', () => {
    expect(derivePostTitle('> Quoted text')).toBe('Quoted text')
  })

  it('strips list prefix', () => {
    expect(derivePostTitle('- List item')).toBe('List item')
    expect(derivePostTitle('* Star item')).toBe('Star item')
    expect(derivePostTitle('+ Plus item')).toBe('Plus item')
  })

  it('strips numbered list prefix', () => {
    expect(derivePostTitle('1. First item')).toBe('First item')
  })

  it('returns "Untitled post" for empty content', () => {
    expect(derivePostTitle('')).toBe('Untitled post')
    expect(derivePostTitle('   ')).toBe('Untitled post')
  })

  it('truncates long titles', () => {
    const long = 'a'.repeat(100)
    const result = derivePostTitle(long)
    expect(result!.length).toBeLessThanOrEqual(96)
    expect(result).toContain('...')
  })

  it('skips horizontal rules', () => {
    expect(derivePostTitle('---\nActual title')).toBe('Actual title')
  })
})

// ================================================================
// sanitizeBoardTitle (expanded)
// ================================================================

describe('sanitizeBoardTitle expanded', () => {
  it('uses first line only', () => {
    expect(sanitizeBoardTitle('Line one\nLine two')).toBe('Line one')
  })

  it('falls back to derivePostTitle from body', () => {
    expect(sanitizeBoardTitle('', 'Body title')).toBe('Body title')
  })

  it('falls back for whitespace-only title', () => {
    expect(sanitizeBoardTitle('   ', 'Fallback')).toBe('Fallback')
  })
})

// ================================================================
// asNullableIsoTimestamp
// ================================================================

describe('asNullableIsoTimestamp', () => {
  it('returns null for null', () => {
    expect(asNullableIsoTimestamp(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(asNullableIsoTimestamp(undefined)).toBeNull()
  })

  it('returns trimmed string for valid ISO string', () => {
    expect(asNullableIsoTimestamp('  2026-04-17T12:00:00Z  ')).toBe('2026-04-17T12:00:00Z')
  })

  it('returns null for empty string', () => {
    expect(asNullableIsoTimestamp('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(asNullableIsoTimestamp('   ')).toBeNull()
  })

  it('converts epoch seconds to ISO', () => {
    const result = asNullableIsoTimestamp(1_700_000_000)
    expect(result).not.toBeNull()
  })

  it('converts epoch milliseconds to ISO', () => {
    const result = asNullableIsoTimestamp(1_700_000_000_000)
    expect(result).not.toBeNull()
  })

  it('returns null for NaN', () => {
    expect(asNullableIsoTimestamp(NaN)).toBeNull()
  })

  it('returns null for Infinity', () => {
    expect(asNullableIsoTimestamp(Infinity)).toBeNull()
  })
})

// ================================================================
// normalizePendingConfirmation (board)
// ================================================================

describe('normalizePendingConfirmation (board)', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmation(null)).toBeNull()
  })

  it('returns null when no confirm_token or token', () => {
    expect(normalizePendingConfirmation({ actor: 'a1' })).toBeNull()
  })

  it('extracts confirm_token', () => {
    const result = normalizePendingConfirmation({ confirm_token: 'tok-1' })
    expect(result!.confirm_token).toBe('tok-1')
  })

  it('falls back to token field', () => {
    const result = normalizePendingConfirmation({ token: 'tok-fallback' })
    expect(result!.confirm_token).toBe('tok-fallback')
  })

  it('extracts all optional fields', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'tok-1',
      actor: 'agent-1',
      action_type: 'pause',
      target_type: 'keeper',
      target_id: 'janitor',
      delegated_tool: 'shell',
      created_at: '2026-04-17T12:00:00Z',
      preview: { msg: 'hi' },
    })
    expect(result!.actor).toBe('agent-1')
    expect(result!.target_id).toBe('janitor')
    expect(result!.preview).toEqual({ msg: 'hi' })
  })
})

// ================================================================
// normalizeKeeperApprovalQueueItem
// ================================================================

describe('normalizeKeeperApprovalQueueItem', () => {
  it('returns null for null', () => {
    expect(normalizeKeeperApprovalQueueItem(null)).toBeNull()
  })

  it('returns null when id is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ keeper_name: 'k', tool_name: 't', risk_level: 'low' })).toBeNull()
  })

  it('returns null when keeper_name is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', tool_name: 't', risk_level: 'low' })).toBeNull()
  })

  it('returns null when tool_name is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', keeper_name: 'k', risk_level: 'low' })).toBeNull()
  })

  it('returns null when risk_level is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', keeper_name: 'k', tool_name: 't' })).toBeNull()
  })

  it('extracts all fields', () => {
    const result = normalizeKeeperApprovalQueueItem({
      id: 'q-1',
      keeper_name: 'janitor',
      tool_name: 'shell_exec',
      risk_level: 'high',
      requested_at_iso: '2026-04-17T12:00:00Z',
      waiting_s: 30,
      input: { cmd: 'ls' },
      input_preview: 'ls -la',
    })
    expect(result!.id).toBe('q-1')
    expect(result!.keeper_name).toBe('janitor')
    expect(result!.tool_name).toBe('shell_exec')
    expect(result!.risk_level).toBe('high')
    expect(result!.waiting_s).toBe(30)
    expect(result!.input_preview).toBe('ls -la')
  })
})

// ================================================================
// normalizeGovernanceJudgment
// ================================================================

describe('normalizeGovernanceJudgment', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceJudgment(null)).toBeNull()
  })

  it('returns null when no summary or target_id', () => {
    expect(normalizeGovernanceJudgment({})).toBeNull()
  })

  it('extracts judgment with summary', () => {
    const result = normalizeGovernanceJudgment({
      summary: 'All systems healthy',
      confidence: 0.92,
    })
    expect(result!.summary).toBe('All systems healthy')
    expect(result!.confidence).toBe(0.92)
  })

  it('extracts judgment with target_id only', () => {
    const result = normalizeGovernanceJudgment({ target_id: 'keeper:janitor' })
    expect(result!.target_id).toBe('keeper:janitor')
  })

  it('extracts all optional fields', () => {
    const result = normalizeGovernanceJudgment({
      summary: 'Test',
      judgment_id: 'j-1',
      target_kind: 'keeper',
      target_id: 'janitor',
      status: 'complete',
      model_used: 'gpt-4',
      keeper_name: 'janitor',
      evidence_refs: ['e1', 'e2'],
    })
    expect(result!.judgment_id).toBe('j-1')
    expect(result!.model_used).toBe('gpt-4')
    expect(result!.evidence_refs).toEqual(['e1', 'e2'])
  })

  it('returns null confidence for non-number', () => {
    const result = normalizeGovernanceJudgment({ summary: 's', confidence: 'high' })
    expect(result!.confidence).toBeNull()
  })
})

// ================================================================
// normalizeGovernanceDecisionItem
// ================================================================

describe('normalizeGovernanceDecisionItem', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceDecisionItem(null)).toBeNull()
  })

  it('returns null when id is missing', () => {
    expect(normalizeGovernanceDecisionItem({ topic: 'test' })).toBeNull()
  })

  it('returns null when topic and title are missing', () => {
    expect(normalizeGovernanceDecisionItem({ id: '1' })).toBeNull()
  })

  it('extracts required fields', () => {
    const result = normalizeGovernanceDecisionItem({
      id: 'case-1',
      topic: 'High CPU alert',
    })
    expect(result!.id).toBe('case-1')
    expect(result!.topic).toBe('High CPU alert')
    expect(result!.kind).toBe('case')
    expect(result!.status).toBe('open')
    expect(result!.related_agents).toEqual([])
    expect(result!.evidence_refs).toEqual([])
  })

  it('falls back to title for topic', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      title: 'Fallback title',
    })
    expect(result!.topic).toBe('Fallback title')
  })

  it('falls back to state for status', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      topic: 't',
      state: 'pending_ruling',
    })
    expect(result!.status).toBe('pending_ruling')
  })

  it('extracts context links', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      topic: 't',
      context: {
        board_post_id: 'bp-1',
        task_id: 't-1',
        operation_id: 'op-1',
        team_session_id: 'sess-1',
      },
    })
    expect(result!.linked_board_post_id).toBe('bp-1')
    expect(result!.linked_task_id).toBe('t-1')
    expect(result!.linked_operation_id).toBe('op-1')
    expect(result!.linked_session_id).toBe('sess-1')
  })
})

// ================================================================
// normalizeGovernanceExecutionOrder
// ================================================================

describe('normalizeGovernanceExecutionOrder', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceExecutionOrder(null)).toBeNull()
  })

  it('returns null when id is missing', () => {
    expect(normalizeGovernanceExecutionOrder({ case_id: 'c1' })).toBeNull()
  })

  it('returns null when case_id is missing', () => {
    expect(normalizeGovernanceExecutionOrder({ id: '1' })).toBeNull()
  })

  it('extracts all fields', () => {
    const result = normalizeGovernanceExecutionOrder({
      id: 'eo-1',
      case_id: 'case-1',
      status: 'auto_executed',
      risk_class: 'low',
      created_at: '2026-04-17T12:00:00Z',
      actor: 'janitor',
    })
    expect(result!.id).toBe('eo-1')
    expect(result!.case_id).toBe('case-1')
    expect(result!.status).toBe('auto_executed')
    expect(result!.actor).toBe('janitor')
  })

  it('defaults status to blocked', () => {
    const result = normalizeGovernanceExecutionOrder({ id: '1', case_id: 'c1' })
    expect(result!.status).toBe('blocked')
  })
})

// ================================================================
// normalizeGovernanceTimelineEvent
// ================================================================

describe('normalizeGovernanceTimelineEvent', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceTimelineEvent(null)).toBeNull()
  })

  it('returns null when kind is missing', () => {
    expect(normalizeGovernanceTimelineEvent({})).toBeNull()
  })

  it('returns null when kind is empty', () => {
    expect(normalizeGovernanceTimelineEvent({ kind: '  ' })).toBeNull()
  })

  it('extracts kind and optional fields', () => {
    const result = normalizeGovernanceTimelineEvent({
      kind: 'ruling_issued',
      item_kind: 'case',
      item_id: 'case-1',
      topic: 'High CPU',
      summary: 'Ruling: auto-execute',
      actor: 'judge',
      index: 5,
      decision: 'approve',
    })
    expect(result!.kind).toBe('ruling_issued')
    expect(result!.item_kind).toBe('case')
    expect(result!.summary).toBe('Ruling: auto-execute')
    expect(result!.index).toBe(5)
  })
})

// ================================================================
// normalizeGovernanceJudgeSummary
// ================================================================

describe('normalizeGovernanceJudgeSummary', () => {
  it('returns undefined for null', () => {
    expect(normalizeGovernanceJudgeSummary(null)).toBeUndefined()
  })

  it('returns undefined for non-record', () => {
    expect(normalizeGovernanceJudgeSummary('invalid')).toBeUndefined()
  })

  it('extracts all fields', () => {
    const result = normalizeGovernanceJudgeSummary({
      judge_online: true,
      refreshing: false,
      model_used: 'gpt-4',
      keeper_name: 'janitor',
      last_error: null,
    })
    expect(result!.judge_online).toBe(true)
    expect(result!.refreshing).toBe(false)
    expect(result!.model_used).toBe('gpt-4')
    expect(result!.keeper_name).toBe('janitor')
    expect(result!.last_error).toBeNull()
  })

  it('returns undefined for non-boolean judge_online', () => {
    const result = normalizeGovernanceJudgeSummary({ judge_online: 'yes' })
    expect(result!.judge_online).toBeUndefined()
  })
})
