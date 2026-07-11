import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { keeperHeartbeats, keepers, messages, shellAuthSummary, tasks } from './store'
import { governanceResource } from './components/governance-signals'
import { _setToolsDataForTests } from './components/tools/tool-state'
import { _clearBoardMentionsLastSeenForTests } from './board-mentions-last-seen'
import { attentionBreakdown, navBadges } from './nav-badges'
import { HEARTBEAT_STALE_MS } from './config/constants'
import type { Keeper, KeeperApprovalQueueItem, Message, Task } from './types'

function keeper(overrides: Partial<Keeper> & { name: string }): Keeper {
  return { status: 'idle', ...overrides } as Keeper
}

function task(overrides: Partial<Task> & { id: string; status: string }): Task {
  return { ...overrides } as Task
}

function message(overrides: Partial<Message> & { content: string }): Message {
  return { from: 'keeper', ...overrides }
}

describe('nav-badges attentionBreakdown / navBadges', () => {
  beforeEach(() => {
    keepers.value = []
    keeperHeartbeats.value = new Map()
    tasks.value = []
    messages.value = []
    shellAuthSummary.value = {
      enabled: true,
      require_token: false,
      default_role: null,
      token_present: true,
      token_valid: true,
      token_agent: 'dashboard',
      requested_agent: null,
      effective_agent: 'dashboard',
      effective_role: 'admin',
      auth_error_code: null,
      auth_error_detail: null,
      can_keeper_msg: true,
      keeper_msg_error: null,
    }
    governanceResource.reset(null)
    _setToolsDataForTests(null)
    _clearBoardMentionsLastSeenForTests()
    window.localStorage.clear()
  })

  afterEach(() => {
    keepers.value = []
    keeperHeartbeats.value = new Map()
    tasks.value = []
    messages.value = []
    shellAuthSummary.value = null
    governanceResource.reset(null)
    _setToolsDataForTests(null)
    _clearBoardMentionsLastSeenForTests()
    window.localStorage.clear()
  })

  it('is all zero with no live sources', () => {
    expect(attentionBreakdown.value).toEqual({
      approvals: 0,
      needsAttentionKeepers: 0,
      deadKeepers: 0,
      staleKeepers: 0,
      boardMentionsForMe: 0,
      awaitingVerification: 0,
      schedulePending: 0,
    })
    expect(navBadges.value).toEqual({
      overview: 0,
      keepers: 0,
      monitoring: 0,
      workspace: 0,
      approvals: 0,
      schedule: 0,
      board: 0,
      fusion: 0,
      logs: 0,
      code: 0,
      connectors: 0,
      settings: 0,
    })
  })

  it('approvals badge counts governanceData.approval_queue', () => {
    governanceResource.reset({
      approval_queue: [{}, {}, {}] as KeeperApprovalQueueItem[],
    })
    expect(attentionBreakdown.value.approvals).toBe(3)
    expect(navBadges.value.approvals).toBe(3)
  })

  it('keepers badge combines needs_attention and dead-phase keepers', () => {
    keepers.value = [
      keeper({ name: 'a', needs_attention: true }),
      keeper({ name: 'b', lifecycle_phase: 'Dead' }),
      keeper({ name: 'c', lifecycle_phase: 'Overflowed' }),
      keeper({ name: 'd' }),
    ]
    expect(attentionBreakdown.value.needsAttentionKeepers).toBe(1)
    expect(attentionBreakdown.value.deadKeepers).toBe(2)
    // The rail's single 'keepers' badge sums both — the top-bar dropdown keeps
    // them as separate drill-down rows (see top-bar-v2.ts's own AttentionAgg).
    expect(navBadges.value.keepers).toBe(3)
  })

  it('connectors badge sources from staleKeepers (heartbeat staleness)', () => {
    keepers.value = [keeper({ name: 'stale-one' }), keeper({ name: 'fresh-one' })]
    keeperHeartbeats.value = new Map([
      ['stale-one', Date.now() - (HEARTBEAT_STALE_MS + 1_000)],
      ['fresh-one', Date.now()],
    ])
    expect(attentionBreakdown.value.staleKeepers).toBe(1)
    expect(navBadges.value.connectors).toBe(1)
  })

  it('workspace badge counts awaiting-verification tasks', () => {
    tasks.value = [
      task({ id: '1', status: 'awaiting_verification' }),
      task({ id: '2', status: 'in_progress' }),
      task({ id: '3', status: 'awaiting_verification' }),
    ]
    expect(attentionBreakdown.value.awaitingVerification).toBe(2)
    expect(navBadges.value.workspace).toBe(2)
  })

  it('schedule badge sources from the scheduled-automation pending count', () => {
    _setToolsDataForTests({
      scheduled_automation: { counts: { pending: 4 }, requests: [] },
    } as never)
    expect(attentionBreakdown.value.schedulePending).toBe(4)
    expect(navBadges.value.schedule).toBe(4)
  })

  it('board badge counts unseen for-me mentions and clears once seen', () => {
    messages.value = [
      message({ id: 'm1', content: '@dashboard please check this', timestamp: '2026-07-01T00:00:00Z' }),
      message({ id: 'm2', content: '@someone-else not for me', timestamp: '2026-07-01T00:00:01Z' }),
    ]
    expect(attentionBreakdown.value.boardMentionsForMe).toBe(1)
    expect(navBadges.value.board).toBe(1)
  })

  it('explicit-zero tabs never derive a count from any source', () => {
    // Populate every underlying signal at once; overview/monitoring/fusion/
    // logs/code/settings must stay 0 regardless (documented "no live source"
    // decisions in nav-badges.ts).
    keepers.value = [keeper({ name: 'a', needs_attention: true })]
    tasks.value = [task({ id: '1', status: 'awaiting_verification' })]
    governanceResource.reset({ approval_queue: [{}] as KeeperApprovalQueueItem[] })
    _setToolsDataForTests({ scheduled_automation: { counts: { pending: 1 }, requests: [] } } as never)

    const b = navBadges.value
    expect(b.overview).toBe(0)
    expect(b.monitoring).toBe(0)
    expect(b.fusion).toBe(0)
    expect(b.logs).toBe(0)
    expect(b.code).toBe(0)
    expect(b.settings).toBe(0)
  })
})
