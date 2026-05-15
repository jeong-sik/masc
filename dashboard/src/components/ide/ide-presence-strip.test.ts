import { describe, expect, it } from 'vitest'
import {
  agentsToPresence,
  parseWorktreeSSE,
  presenceContextAnchor,
  presenceContextSummary,
  prLabel,
  workspaceLabelForAgent,
  type ApiAgent,
  type ApiStatus,
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

describe('agentsToPresence', () => {
  const sampleAgent: ApiAgent = {
    name: 'nick0cave',
    status: 'idle',
    current_task: null,
    model: null,
  }

  it('returns disconnected snapshot when cluster is undefined', () => {
    const status: ApiStatus = { cluster: undefined }
    const snap = agentsToPresence([sampleAgent], status, [])
    expect(snap.kind).toBe('disconnected')
  })

  // Regression: prior code only checked `status.cluster === undefined`, so a
  // JSON payload with `cluster: null` (the wire form of OCaml's [None]) hit
  // `null.trim()` and crashed the entire CODE / IDE-shell surface render.
  it('returns disconnected snapshot when cluster is null', () => {
    const status: ApiStatus = { cluster: null }
    const snap = agentsToPresence([sampleAgent], status, [])
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('runtime_unknown')
    }
  })

  it('returns disconnected snapshot when cluster is whitespace only', () => {
    const status: ApiStatus = { cluster: '   ' }
    const snap = agentsToPresence([sampleAgent], status, [])
    expect(snap.kind).toBe('disconnected')
  })

  it('returns disconnected snapshot when cluster is set but no agents present', () => {
    const status: ApiStatus = { cluster: 'masc-local' }
    const snap = agentsToPresence([], status, [])
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('no_agents')
    }
  })

  it('returns live snapshot with trimmed cluster id when both cluster and agents present', () => {
    const status: ApiStatus = { cluster: '  masc-local  ' }
    const snap = agentsToPresence([sampleAgent], status, [])
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') {
      expect(snap.runtime_id).toBe('masc-local')
      expect(snap.entries).toHaveLength(1)
    }
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

describe('presenceContextAnchor', () => {
  const entry = {
    keeper_id: 'nick0cave',
    workspace_label: 'wt-run-47',
    branch: 'main',
    role: 'agent',
    status: 'active',
    last_seen_ms: 123,
  } as const

  it('builds code, PR, Git, telemetry, and keeper route links from a focused keeper chip', () => {
    const anchor = presenceContextAnchor({
      entry,
      worktree: sampleWorktrees[0]!,
      cursor: {
        keeper_id: 'nick0cave',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 7,
        focus_mode: 'editing',
        last_update: 123,
        tool_name: 'ocamllsp',
      },
    })

    expect(anchor).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'Keeper',
      label: 'nick0cave@wt-run-47',
      source_id: 'presence:nick0cave',
      keeper_id: 'nick0cave',
    })
    expect(anchor?.route_links?.map(link => link.label)).toEqual([
      'Code',
      'PR',
      'Git',
      'Telemetry',
      'Keeper',
    ])
    expect(anchor?.route_links?.find(link => link.label === 'PR')?.params).toMatchObject({
      section: 'repositories',
      view: 'graph',
      pr: '88',
    })
    expect(anchor?.route_links?.find(link => link.label === 'Git')?.params).toMatchObject({
      section: 'repositories',
      ref: 'nick0cave/wt-run-47',
    })
    expect(anchor?.route_links?.find(link => link.label === 'Telemetry')?.params).toMatchObject({
      section: 'fleet-health',
      view: 'event-log',
      q: 'nick0cave',
    })
  })

  it('does not create a focus anchor for keepers without cursor file context', () => {
    expect(presenceContextAnchor({
      entry,
      worktree: sampleWorktrees[0]!,
      cursor: undefined,
    })).toBeNull()
  })

  it('summarizes visible context coverage for keeper presence chips', () => {
    const anchor = presenceContextAnchor({
      entry,
      worktree: sampleWorktrees[0]!,
      cursor: {
        keeper_id: 'nick0cave',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 7,
        focus_mode: 'editing',
        last_update: 123,
        tool_name: 'ocamllsp',
      },
    })

    expect(presenceContextSummary(anchor)).toEqual({
      label: 'CTX 5',
      title: 'Linked context: Code, PR, Git, Telemetry, Keeper',
    })
  })

  it('omits context coverage when no route links are available', () => {
    expect(presenceContextSummary(null)).toBeNull()
  })
})
