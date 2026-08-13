import { beforeEach, describe, expect, it, vi } from 'vitest'

const mcpMocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(() => Promise.resolve('{}')),
  mcpCallFailureDisposition: vi.fn(),
  mcpStructuredContentFromError: vi.fn(),
}))

// claimTask must reach the server. The pre-existing Work-board bug was that a
// claim only touched local React state and vanished on refresh (#46); this
// test pins the contract that a claim is routed through the persisted
// masc_transition FSM tool.
vi.mock('./mcp', () => mcpMocks)
vi.mock('./core', () => ({ get: vi.fn(), post: vi.fn(() => Promise.resolve({ ok: true })) }))

import { claimTask, deleteTask, sendBroadcast } from './actions'

describe('claimTask', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('routes an operator claim through masc_transition (todo -> claimed)', async () => {
    await claimTask('task-123')
    expect(mcpMocks.callMcpTool).toHaveBeenCalledTimes(1)
    expect(mcpMocks.callMcpTool).toHaveBeenCalledWith('masc_transition', {
      task_id: 'task-123',
      action: 'claim',
    })
  })

  it('propagates a transition failure so the caller can roll back the optimistic flag', async () => {
    mcpMocks.callMcpTool.mockRejectedValueOnce(new Error('todo -> claimed rejected'))
    await expect(claimTask('task-err')).rejects.toThrow('todo -> claimed rejected')
  })
})

describe('deleteTask (unchanged path, regression guard)', () => {
  it('posts to the dashboard delete route', async () => {
    const ok = await deleteTask('task-9')
    expect(ok).toBe(true)
  })
})

describe('sendBroadcast delivery truth', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('preserves uncertainty for a malformed executed-tool receipt', async () => {
    const error = new Error('tool response could not be decoded')
    mcpMocks.callMcpTool.mockRejectedValue(error)
    mcpMocks.mcpStructuredContentFromError.mockReturnValue({
      ok: false,
      request_id: 'wmsg-0123456789abcdef0123456789abcdef',
      mention_delivery: { kind: 'accepted' },
    })
    mcpMocks.mcpCallFailureDisposition.mockReturnValue('known_tool_response')

    await expect(sendBroadcast('dashboard', '@gemini check')).resolves.toEqual({
      ok: false,
      requestId: null,
      deliveryKind: 'outcome_unknown',
      reason: 'Broadcast returned a malformed delivery receipt.',
      workspacePersisted: null,
    })
  })
})
