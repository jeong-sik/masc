// @vitest-environment jsdom

// `preact/debug` reports two children under one key. It is loaded for this
// file alone: the dashboard's dev server loads it, a test run does not.
import 'preact/debug'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { KeeperHeader } from './keeper-header'
import type { KeeperRosterItem, KeeperWaitingHead } from './types'

const keeper = (heads: readonly KeeperWaitingHead[]): KeeperRosterItem => ({
  name: 'alpha', status: 'running', phase: 'running', health: 'healthy', paused: false, keepalive_running: true,
  activation_mode: 'autonomous', runtime_id: 'rt-1', sandbox_profile: 'microvm', company: 'co',
  context_ratio: 0.4, context_tokens: 1, context_max: 2, context_unavailable_reason: null,
  runtime_blocker_summary: null, last_failure: null, directory_issue: null, turns_24h: 3,
  candle_balance_milli: '0', portrait_equipment: null, chat_control_token: null, active_turn: null,
  waiting_summary: { state: 'waiting', count: heads.length, primary_reason: heads[0]?.what ?? null, due_at: null, heads },
})
const queued = (what: string): KeeperWaitingHead => ({
  source: 'event_queue_pending', what, next_action: 'keeper_drain_event_queue', due_at: null,
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('the waiting rows of the Keeper header', () => {
  it('draws two rows of one source and one next action as two, each under its own key', () => {
    const complaints = vi.spyOn(console, 'error').mockImplementation(() => {})
    const view = render(html`
      <${KeeperHeader} keeper=${keeper([queued('보드 이벤트 3건'), queued('멘션 1건')])} activeTab="chat"
        onSelectTab=${vi.fn()} onLifecycleMutated=${vi.fn()} onDeleted=${vi.fn()} />
    `)
    const rows = [...view.container.querySelectorAll('.kp-diag-lane-meta')].map((row) => row.firstElementChild?.textContent)
    expect(rows).toEqual(['보드 이벤트 3건', '멘션 1건'])
    expect(complaints.mock.calls.map((call) => String(call[0])).filter((said) => said.includes('same key'))).toEqual([])
  })
})
