import { describe, expect, it } from 'vitest'
import { orderByWait, queueWaitText, waitingSinceAskedAt, waitingSinceGateRead } from './inbox-queue'
import type { GatePendingItem, GoalItem, InboxEntry, KeeperAskItem, ToolApprovalWait } from './types'

const NOW_MS = 1_800_000_000_000
const MINUTE_MS = 60_000

const approval = (askedAt: number | null, timeoutSec: number | null = null): ToolApprovalWait => ({
  approvalId: `approval-${askedAt}`,
  toolCallId: 'call-1',
  keeper: 'sample-keeper',
  tool: 'sample_tool',
  argsPreview: '{}',
  question: '',
  because: null,
  askedAt,
  timeoutSec,
  revision: 'r1',
})

const toolEntry = (key: string, sinceMs: number | null, timeoutSec: number | null = null): InboxEntry => ({
  kind: 'tool_approval',
  key,
  waitingSinceMs: sinceMs,
  item: approval(sinceMs === null ? null : sinceMs / 1000, timeoutSec),
})

const askEntry = (key: string, sinceMs: number | null): InboxEntry => ({
  kind: 'keeper_ask', key, waitingSinceMs: sinceMs, item: { askId: key } as KeeperAskItem,
})

const gateEntry = (key: string, sinceMs: number | null): InboxEntry => ({
  kind: 'channel_gate', key, waitingSinceMs: sinceMs, item: { id: key } as GatePendingItem,
})

const goalEntry = (key: string): InboxEntry => ({
  kind: 'goal_confirmation', key, waitingSinceMs: null, goal: { id: key } as GoalItem,
})

describe('workspaces/work inbox queue', () => {
  it('counts a wait from the time a row was asked, and a Gate row back from its read', () => {
    expect(waitingSinceAskedAt(1_800_000_000)).toBe(NOW_MS)
    expect(waitingSinceAskedAt(null)).toBeNull()
    expect(waitingSinceGateRead(90, NOW_MS)).toBe(NOW_MS - 90_000)
    // Neither half alone says when the row began to wait.
    expect(waitingSinceGateRead(null, NOW_MS)).toBeNull()
    expect(waitingSinceGateRead(90, null)).toBeNull()
  })

  it('puts the longest wait first, whatever the kind', () => {
    const ordered = orderByWait([
      toolEntry('tool-new', NOW_MS - 1 * MINUTE_MS),
      askEntry('ask-old', NOW_MS - 50 * MINUTE_MS),
      gateEntry('gate-mid', NOW_MS - 10 * MINUTE_MS),
    ])

    expect(ordered.map((entry) => entry.key)).toEqual(['ask-old', 'gate-mid', 'tool-new'])
  })

  it('keeps an entry with no time after the timed ones, in the place it had', () => {
    const ordered = orderByWait([
      toolEntry('tool-untimed', null),
      goalEntry('goal-a'),
      askEntry('ask-new', NOW_MS - 2 * MINUTE_MS),
      goalEntry('goal-b'),
      gateEntry('gate-old', NOW_MS - 30 * MINUTE_MS),
    ])

    expect(ordered.map((entry) => entry.key)).toEqual(['gate-old', 'ask-new', 'tool-untimed', 'goal-a', 'goal-b'])
  })

  it('keeps the order of two entries asked at the same moment', () => {
    const ordered = orderByWait([askEntry('first', NOW_MS), gateEntry('second', NOW_MS), toolEntry('third', NOW_MS)])

    expect(ordered.map((entry) => entry.key)).toEqual(['first', 'second', 'third'])
  })

  it('says how long a row has waited', () => {
    expect(queueWaitText(askEntry('a', NOW_MS - 45_000), NOW_MS)).toBe('45초째 대기')
    expect(queueWaitText(gateEntry('g', NOW_MS - 12 * MINUTE_MS), NOW_MS)).toBe('12분째 대기')
    expect(queueWaitText(askEntry('a', NOW_MS - 3 * 60 * MINUTE_MS), NOW_MS)).toBe('3시간째 대기')
    // A clock a little behind the server's must not say a negative wait.
    expect(queueWaitText(askEntry('a', NOW_MS + 2_000), NOW_MS)).toBe('0초째 대기')
  })

  it('says nothing of a wait it cannot count', () => {
    expect(queueWaitText(goalEntry('goal'), NOW_MS)).toBeNull()
    expect(queueWaitText(toolEntry('tool', null, 300), NOW_MS)).toBeNull()
  })

  it('says first when a held tool call gives up', () => {
    const asked = NOW_MS - 3 * MINUTE_MS

    expect(queueWaitText(toolEntry('pending', asked, 300), NOW_MS)).toBe('2분 뒤 시간 초과 · 3분째 대기')
    expect(queueWaitText(toolEntry('expired', asked, 120), NOW_MS)).toBe('대기 한도 지남 · 3분째 대기')
    expect(queueWaitText(toolEntry('no-limit', asked, null), NOW_MS)).toBe('3분째 대기')
  })
})
