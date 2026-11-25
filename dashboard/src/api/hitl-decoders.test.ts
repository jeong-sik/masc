import { describe, expect, it } from 'vitest'
import { decodeToolApprovalsWire, isOpenKeeperAskRow } from './hitl-decoders'
import { parseKeeperAsksPayload, parseToolApprovalsPayload } from '../shell/shell-state'

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
})
