import { describe, expect, it } from 'vitest'
import { parseWorktreeResponse } from './worktrees'

describe('parseWorktreeResponse', () => {
  it('parses the current JSON contract that uses path fields', () => {
    const raw = JSON.stringify({
      worktrees: [
        {
          path: '/repo/.worktrees/fix/dashboard-worktree-listing',
          branch: 'refs/heads/fix/dashboard-worktree-listing',
        },
        {
          path: '/repo/.worktrees/feat/dir-local-runtime',
          branch: 'refs/heads/feat/dir-local-runtime',
        },
      ],
    })

    expect(parseWorktreeResponse(raw)).toEqual([
      {
        id: 'fix/dashboard-worktree-listing:/repo/.worktrees/fix/dashboard-worktree-listing:0',
        branch: 'fix/dashboard-worktree-listing',
        path: '/repo/.worktrees/fix/dashboard-worktree-listing',
        agent: undefined,
        task_id: undefined,
        created_at: undefined,
      },
      {
        id: 'feat/dir-local-runtime:/repo/.worktrees/feat/dir-local-runtime:1',
        branch: 'feat/dir-local-runtime',
        path: '/repo/.worktrees/feat/dir-local-runtime',
        agent: undefined,
        task_id: undefined,
        created_at: undefined,
      },
    ])
  })

  it('accepts the legacy worktree field name', () => {
    const raw = JSON.stringify({
      worktrees: [
        {
          worktree: '/repo/.worktrees/legacy-entry',
          branch: 'legacy-entry',
        },
      ],
    })

    expect(parseWorktreeResponse(raw)).toEqual([
      {
        id: 'legacy-entry:/repo/.worktrees/legacy-entry:0',
        branch: 'legacy-entry',
        path: '/repo/.worktrees/legacy-entry',
        agent: undefined,
        task_id: undefined,
        created_at: undefined,
      },
    ])
  })

  it('keeps an empty worktree collection empty instead of showing a raw card', () => {
    expect(parseWorktreeResponse(JSON.stringify({ worktrees: [] }))).toEqual([])
  })

  it('recovers multiple entries from raw git worktree porcelain output', () => {
    const raw = [
      'worktree /repo/main',
      'HEAD abc123',
      'branch refs/heads/main',
      '',
      'worktree /repo/.worktrees/fix/dashboard-worktree-listing',
      'HEAD def456',
      'branch refs/heads/fix/dashboard-worktree-listing',
      '',
      'worktree /repo/.worktrees/fix/detached-check',
      'HEAD fedcba',
      'detached',
    ].join('\n')

    expect(parseWorktreeResponse(raw)).toEqual([
      {
        id: 'main:/repo/main:0',
        branch: 'main',
        path: '/repo/main',
      },
      {
        id: 'fix/dashboard-worktree-listing:/repo/.worktrees/fix/dashboard-worktree-listing:1',
        branch: 'fix/dashboard-worktree-listing',
        path: '/repo/.worktrees/fix/dashboard-worktree-listing',
      },
      {
        id: '(detached):/repo/.worktrees/fix/detached-check:2',
        branch: '(detached)',
        path: '/repo/.worktrees/fix/detached-check',
      },
    ])
  })

  it('keeps the raw response when nothing else can be parsed', () => {
    expect(parseWorktreeResponse('not-json-and-not-porcelain')).toEqual([
      {
        id: 'raw',
        branch: 'Unknown',
        path: 'not-json-and-not-porcelain',
      },
    ])
  })
})
