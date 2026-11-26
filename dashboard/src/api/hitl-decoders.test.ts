import { describe, expect, it, vi } from 'vitest'
import {
  decodeGateQueueStrict,
  decodeKeeperAsksWire,
  decodeToolApprovalsStrict,
  decodeToolApprovalsWire,
  isOpenKeeperAskRow,
} from './hitl-decoders'
import {
  hitlSourceStatus,
  parseGateQueuePayload,
  parseKeeperAsksPayload,
  parseToolApprovalsPayload,
  pendingApprovals,
  refreshPendingHitl,
  resetShellStateForTests,
  submitFastToolApproval,
} from '../shell/shell-state'
import { authSession, resetAuthStateForTests } from '../core/auth'

describe('Shared HITL wire decoders (SSOT)', () => {
  it('decodes tool approvals consistently across string/object args, finite asked_at, and numeric revisions', () => {
    const rows = decodeToolApprovalsWire({
      pending: [
        {
          approval_id: 'ap-1',
          tool_call_id: 'tc-1',
          keeper: 'sangsu',
          tool: 'masc_git_push',
          args: { remote: 'origin', branch: 'main' },
          question: 'Allow push?',
          because: 'Protected branch',
          asked_at: 1700000100,
          timeout_sec: 120,
          revision: 7,
        },
        {
          approval_id: 'ap-bad-ts',
          tool_call_id: 'tc-2',
          keeper: 'alpha',
          tool: 'bash',
          asked_at: Number.NaN,
          revision: Number.POSITIVE_INFINITY,
        },
        {
          // Missing approval_id falls back to tool_call_id for inbox consumers, flagged via hasExplicitApprovalId=false
          tool_call_id: 'tc-only',
          keeper: 'beta',
          tool: 'read_file',
        },
        {
          // Missing keeper is dropped
          approval_id: 'ap-no-keeper',
          tool_call_id: 'tc-3',
        },
      ],
    })

    expect(rows).toHaveLength(3)
    expect(rows[0]).toMatchObject({
      approvalId: 'ap-1',
      hasExplicitApprovalId: true,
      toolCallId: 'tc-1',
      keeper: 'sangsu',
      tool: 'masc_git_push',
      askedAt: 1700000100,
      timeoutSec: 120,
      revision: '7',
    })
    expect(rows[0]!.args).toContain('"branch": "main"')
    expect(rows[1]!.askedAt).toBeNull()
    expect(rows[1]!.revision).toBe('ap-bad-ts:0')
    expect(rows[2]!.approvalId).toBe('tc-only')
    expect(rows[2]!.hasExplicitApprovalId).toBe(false)

    // Shell fast-approval parser requires explicit approval_id + tool_call_id and preserves formatted object args
    const shellItems = parseToolApprovalsPayload(
      {
        pending: [
          {
            approval_id: 'ap-1',
            tool_call_id: 'tc-1',
            keeper: 'sangsu',
            tool: 'masc_git_push',
            args: { force: false },
            asked_at: 1700000100,
          },
          { tool_call_id: 'tc-only', keeper: 'beta', tool: 'read_file' },
        ],
      },
      'ws-1',
    )
    expect(shellItems).toHaveLength(1)
    expect(shellItems[0]!.args).toContain('"force": false')
  })

  it('filters answered/resolved/closed/withdrawn/expired asks via closed-set SSOT', () => {
    expect(isOpenKeeperAskRow({ ask_id: 'a1' })).toBe(true)
    expect(isOpenKeeperAskRow({ ask_id: 'a2', state: 'open' })).toBe(true)
    expect(isOpenKeeperAskRow({ ask_id: 'a3', resolution: { state: 'open' } })).toBe(true)
    expect(isOpenKeeperAskRow({ ask_id: 'a4', resolution: { state: 'answered' } })).toBe(false)
    expect(isOpenKeeperAskRow({ ask_id: 'a5', resolution: { state: 'withdrawn' } })).toBe(false)
    expect(isOpenKeeperAskRow({ ask_id: 'a6', state: 'CLOSED' })).toBe(false)
    expect(isOpenKeeperAskRow({ ask_id: 'a7', state: 'expired' })).toBe(false)

    const openShellAsks = parseKeeperAsksPayload(
      {
        asks: [
          { ask_id: 'open-1', keeper: 'alpha', question: 'Deploy?' },
          { ask_id: 'done-1', keeper: 'alpha', question: 'Done', resolution: { state: 'answered' } },
          { ask_id: 'exp-1', keeper: 'alpha', question: 'Old', state: 'expired' },
        ],
      },
      'ws-1',
    )
    expect(openShellAsks.map((a) => a.askId)).toEqual(['open-1'])
  })

  it('enforces strict Channel Gate queue contract across Inbox and Shell and rejects unconfirmed fast approvals', async () => {
    expect(decodeGateQueueStrict({ approval_queue: [{ id: 'g1', keeper_name: 'k', tool_name: 'bash', sequence: 2 }] }).ok).toBe(true)
    expect(decodeGateQueueStrict({ approval_queue: [{ id: 'g1', keeper_name: 'k', tool_name: 'bash' }] }).ok).toBe(false)
    expect(decodeGateQueueStrict({ approval_queue: [{ id: 'g1', keeper_name: 'k', tool_name: 'bash', sequence: 0 }] }).ok).toBe(false)
    expect(parseGateQueuePayload({ approval_queue: [{ id: 'g1', keeper_name: 'k', tool_name: 'bash' }] }, 'default')).toEqual([])

    expect(decodeKeeperAsksWire({ asks: [{ ask_id: 'a1', keeper: 'k1', question: 'ok?' }, { ask_id: 'a2' }] })).toMatchObject({
      ok: true,
      asks: [{ askId: 'a1', keeper: 'k1', promptSummary: 'ok?' }],
    })
    expect(decodeKeeperAsksWire({ open: [] }).ok).toBe(false)
    expect(() => decodeToolApprovalsStrict({ pending: [{ keeper: 'k', tool_call_id: 'tc-1' }] })).toThrow()

    resetAuthStateForTests()
    resetShellStateForTests()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const malformedGateFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (d: unknown) => new Response(JSON.stringify(d), { status: 200, headers: { 'content-type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/gate')) return json({ approval_queue: [{ id: 'g1', keeper_name: 'k', tool_name: 'bash' }] })
      if (url.includes('/api/v1/keepers/tool-approvals')) return json({ pending: [] })
      if (url.includes('/api/v1/keepers/asks')) return json({ asks: [] })
      if (url.includes('/api/v1/dashboard/planning')) return json({ goals: [] })
      if (url.includes('/api/v1/verification/requests')) return json({ requests: [] })
      return json({})
    })
    await refreshPendingHitl(malformedGateFetch as unknown as typeof fetch)
    expect(hitlSourceStatus.value.gate.kind).toBe('failed')

    const item = {
      approvalId: 'ap-1',
      keeper: 'sangsu',
      toolCallId: 'tc-1',
      tool: 'bash',
      args: '{}',
      question: 'Run?',
      because: 'guard',
      askedAt: 1700000000,
      workspaceId: 'default',
      revision: '1',
    }
    pendingApprovals.value = [item]
    const unconfirmedFetch = vi.fn(async () =>
      new Response(JSON.stringify({ settled: false, remembered: false }), { status: 200, headers: { 'content-type': 'application/json' } }),
    )
    const badReceipt = await submitFastToolApproval(item, 'approve', unconfirmedFetch as unknown as typeof fetch)
    expect(badReceipt.ok).toBe(false)
    expect(pendingApprovals.value).toHaveLength(1)

    const rememberedFetch = vi.fn(async () =>
      new Response(JSON.stringify({ settled: false, remembered: true }), { status: 200, headers: { 'content-type': 'application/json' } }),
    )
    const okReceipt = await submitFastToolApproval(item, 'approve', rememberedFetch as unknown as typeof fetch)
    expect(okReceipt.ok).toBe(true)
    expect(pendingApprovals.value).toHaveLength(0)
  })
})
