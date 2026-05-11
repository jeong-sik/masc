import { describe, expect, it } from 'vitest'
import {
  parseWorktreeSSE,
  prLabel,
  workspaceLabelForAgent,
  type WorktreeEntry,
} from './ide-presence-strip'

const sampleWorktrees: WorktreeEntry[] = [
  {
    worktree_path: '/repo/.worktrees/nick0cave-wt-run-47',
    branch: 'nick0cave/wt-run-47',
    changed_count: 3,
    staged_count: 1,
    head_sha: 'abc1234',
    pr_number: 88,
    pr_state: 'open',
    keeper_attached: true,
  },
  {
    worktree_path: '/repo/.worktrees/improver-p0a-worktree-status-sse',
    branch: 'improver/p0a-worktree-status-sse',
    changed_count: 0,
    staged_count: 0,
    head_sha: 'def5678',
    pr_number: null,
    pr_state: null,
    keeper_attached: false,
  },
]

describe('workspaceLabelForAgent', () => {
  it('returns the task-id segment when a matching worktree branch exists', () => {
    expect(workspaceLabelForAgent('nick0cave', sampleWorktrees)).toBe('wt-run-47')
    expect(workspaceLabelForAgent('improver', sampleWorktrees)).toBe('p0a-worktree-status-sse')
  })

  it('falls back to the agent name when no worktree matches', () => {
    expect(workspaceLabelForAgent('sangsu', sampleWorktrees)).toBe('sangsu')
  })

  it('returns agent name for empty worktrees list', () => {
    expect(workspaceLabelForAgent('nick0cave', [])).toBe('nick0cave')
  })
})

describe('parseWorktreeSSE', () => {
  it('parses valid SSE data lines into WorktreeEntry objects', () => {
    const body = [
      `data: ${JSON.stringify(sampleWorktrees[0])}`,
      '',
      `data: ${JSON.stringify(sampleWorktrees[1])}`,
      '',
      'event: done',
      'data: {}',
      '',
    ].join('\n')

    const result = parseWorktreeSSE(body)
    expect(result).toHaveLength(2)
    expect(result[0]?.branch).toBe('nick0cave/wt-run-47')
    expect(result[1]?.branch).toBe('improver/p0a-worktree-status-sse')
  })

  it('skips empty data payload and non-data lines', () => {
    const body = [
      ': keepalive',
      'retry: 3000',
      'event: done',
      'data: {}',
    ].join('\n')

    expect(parseWorktreeSSE(body)).toEqual([])
  })

  it('skips malformed JSON without throwing', () => {
    const body = 'data: {not valid json}\ndata: ' + JSON.stringify(sampleWorktrees[0])
    const result = parseWorktreeSSE(body)
    expect(result).toHaveLength(1)
    expect(result[0]?.branch).toBe('nick0cave/wt-run-47')
  })

  it('workspace_label is populated from workspaceLabelForAgent using parsed SSE', () => {
    const body = sampleWorktrees
      .map(wt => `data: ${JSON.stringify(wt)}`)
      .join('\n\n')
    const entries = parseWorktreeSSE(body)

    // Verify that the parsed entries carry enough information to derive workspace labels
    const label = workspaceLabelForAgent('nick0cave', entries)
    expect(label).toBe('wt-run-47')
  })
})

describe('prLabel', () => {
  it('formats open PR with no decoration', () => {
    expect(prLabel(123, 'open')).toBe('#123')
  })

  it('formats closed PR with ✕ suffix', () => {
    expect(prLabel(456, 'closed')).toBe('#456✕')
  })

  it('formats merged PR with ✓ suffix', () => {
    expect(prLabel(789, 'merged')).toBe('#789✓')
  })

  it('falls back to plain "#N" for unknown state strings', () => {
    expect(prLabel(42, 'draft')).toBe('#42')
    expect(prLabel(42, 'unknown')).toBe('#42')
    expect(prLabel(42, '')).toBe('#42')
  })

  it('falls back to plain "#N" when state is null', () => {
    expect(prLabel(7, null)).toBe('#7')
  })
})
