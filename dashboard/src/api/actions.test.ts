import { describe, it, expect, vi, beforeEach } from 'vitest'

// claimTask must reach the server. The pre-existing Work-board bug was that a
// claim only touched local React state and vanished on refresh (#46); this
// test pins the contract that a claim is routed through the persisted
// masc_transition FSM tool.
vi.mock('./mcp', () => ({ callMcpTool: vi.fn(() => Promise.resolve('{}')) }))
vi.mock('./core', () => ({ get: vi.fn(), post: vi.fn(() => Promise.resolve({ ok: true })) }))

import { callMcpTool } from './mcp'
import { claimTask, deleteTask } from './actions'

describe('claimTask', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('routes an operator claim through masc_transition (todo -> claimed)', async () => {
    await claimTask('task-123')
    expect(callMcpTool).toHaveBeenCalledTimes(1)
    expect(callMcpTool).toHaveBeenCalledWith('masc_transition', {
      task_id: 'task-123',
      action: 'claim',
    })
  })

  it('propagates a transition failure so the caller can roll back the optimistic flag', async () => {
    vi.mocked(callMcpTool).mockRejectedValueOnce(new Error('todo -> claimed rejected'))
    await expect(claimTask('task-err')).rejects.toThrow('todo -> claimed rejected')
  })
})

describe('deleteTask (unchanged path, regression guard)', () => {
  it('posts to the dashboard delete route', async () => {
    const ok = await deleteTask('task-9')
    expect(ok).toBe(true)
  })
})
