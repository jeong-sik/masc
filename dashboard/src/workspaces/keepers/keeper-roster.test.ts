// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { resetAuthStateForTests } from '../../core/auth'
import { observedValue } from '../../core/resource-cache'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import { NO_FLEET_TURN_PREVIEWS, retainFleetTurnPreview, type FleetTurnPreviews } from './fleet-turn-previews'
import { KeeperRoster } from './keeper-roster'
import type {
  KeeperActiveTurn, KeeperActiveTurnPreview, KeeperRosterItem, KeeperTurnPreparation, KeeperWaitingSummary, TurnOpenActivity,
} from './types'

const keeper = (name: string, more: Partial<KeeperRosterItem> = {}): KeeperRosterItem => ({
  name, status: 'running', phase: 'running', health: 'healthy', paused: false, keepalive_running: true,
  activation_mode: 'autonomous', runtime_id: 'rt-1', sandbox_profile: 'microvm', company: 'co',
  context_ratio: 0.4, context_tokens: 1, context_max: 2, context_unavailable_reason: null,
  runtime_blocker_summary: null, last_failure: null, directory_issue: null, turns_24h: 3,
  candle_balance_milli: '0', portrait_equipment: null, chat_control_token: null, active_turn: null,
  ...more,
})
const tool = (name: string, stage: 'requested' | 'executing'): TurnOpenActivity => ({
  kind: 'tool', tool_use_id: null, name, stage, started_at_unix: 11, since_unix: 12, cohort: null, reach: null,
})
const preview = (
  open: readonly TurnOpenActivity[] | null,
  preparation: KeeperTurnPreparation | null = null,
  activity: string = preparation ? 'preparing' : 'tool',
  revision = 1,
): KeeperActiveTurnPreview => ({
  status_text: 'rt-1 · said by the server', activity, preparation, work_context: null,
  open_activities: open, text_tail: '', last_tool: null, updated_at_unix: 20, revision,
})
const turn = (...of: Parameters<typeof preview>): KeeperActiveTurn => ({
  lane: 'autonomous', owner_key: 'A', started_at_unix: 10, preview_observed_through: 1, preview: preview(...of),
})
const waiting = (count: number): KeeperWaitingSummary => ({ state: 'waiting', count, primary_reason: null, due_at: null, heads: [] })

describe('a roster row', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetPortraitCacheForTests()
    // jsdom lays nothing out: the virtual list needs a height to keep its rows.
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(260)
  })

  afterEach(() => {
    cleanup()
    resetPortraitCacheForTests()
    vi.restoreAllMocks()
  })

  const rows = (keepers: readonly KeeperRosterItem[], turnPreviews?: FleetTurnPreviews) => {
    const view = render(html`<${KeeperRoster}
      roster=${observedValue(keepers, Date.now())} turnPreviews=${turnPreviews}
      selectedKeeper=${null} onSelectKeeper=${vi.fn()} onCreatedKeeper=${vi.fn()}
    />`)
    const seen = new Map([...view.container.querySelectorAll('.kp-roster-row')].map((row) => {
      const state = row.querySelector('[data-roster-state]')
      const turnLine = row.querySelector('.kp-roster-turn')
      return [row.getAttribute('data-keeper'), {
        line: state?.textContent ?? null,
        hover: state?.getAttribute('title') ?? null,
        // The parts of a turn's line, in the order a narrow row leaves them out from the end.
        parts: turnLine ? [...turnLine.children].map((part) => part.textContent) : null,
        unreadMarker: turnLine?.querySelector('.kp-roster-waiting-unread')?.getAttribute('title') ?? null,
        waitingUnread: turnLine?.getAttribute('data-waiting-unread') ?? null,
        trailingWaiting: turnLine?.querySelector('.kp-roster-waiting')?.textContent ?? null,
        // Of a tool's name, the front that gives way and the end that stays.
        name: turnLine?.querySelector('.kp-roster-tool')
          ? [...(turnLine.querySelector('.kp-roster-tool')?.children ?? [])].map((part) => part.textContent)
          : null,
        words: turnLine?.querySelector('.kp-roster-words')?.textContent ?? null,
        lines: [...row.querySelectorAll('.kp-roster-line')].map((line) => [...line.children].map((part) => part.className.split(' ')[0])),
      }]
    }))
    view.unmount()
    return seen
  }

  it('puts the name beside the context pill and the state beside the small label', () => {
    const seen = rows([keeper('a-idle'), keeper('b-turn', { active_turn: turn([tool('Execute', 'executing')]) })])
    // The state stands in its own box, where a turn's elapsed time goes before it.
    const twoLines = [['kp-roster-name', 'kp-pill'], ['kp-roster-state', 'kp-roster-sub']]
    expect(seen.get('a-idle')?.lines).toEqual(twoLines)
    expect(seen.get('b-turn')?.lines).toEqual(twoLines)
  })

  it('says only the settings of a Keeper that is in no turn', () => {
    const seen = rows([
      keeper('a-idle'),
      keeper('b-waiting', { waiting_summary: waiting(3) }),
      keeper('c-unread', { waiting_summary: { unavailable: true, reason: null } }),
      keeper('d-none-waiting', { waiting_summary: waiting(0) }),
    ])
    expect(seen.get('a-idle')).toMatchObject({ line: 'rt-1', hover: 'rt-1', parts: null })
    // A list that was read and holds nothing is not a count to show.
    expect(seen.get('d-none-waiting')).toMatchObject({ line: 'rt-1', hover: 'rt-1', parts: null })
    expect(seen.get('b-waiting')).toMatchObject({ line: '대기 3 · rt-1', hover: '대기 3 · rt-1', parts: null })
    // A waiting list that could not be read is said as that, not as nothing waiting.
    expect(seen.get('c-unread')).toMatchObject({ line: '대기 목록 읽기 실패 · rt-1', parts: null })
  })

  it('says what an open turn is doing, then how much waits, and keeps a waiting read failure first', () => {
    const seen = rows([
      keeper('a-turn', { active_turn: turn([tool('Execute', 'executing')]) }),
      keeper('b-turn-waiting', { active_turn: turn([tool('Execute', 'executing')]), waiting_summary: waiting(3) }),
      keeper('c-turn-unread', { active_turn: turn([tool('Execute', 'executing')]), waiting_summary: { unavailable: true, reason: null } }),
      keeper('d-turn-none-waiting', { active_turn: turn([tool('Execute', 'executing')]), waiting_summary: waiting(0) }),
      keeper('e-turn-words-unread', {
        active_turn: turn([], { state: 'active', phase: 'workspace_memory', started_at_unix: 15 }),
        waiting_summary: { unavailable: true, reason: 'store locked' },
      }),
    ])
    expect(seen.get('a-turn')).toMatchObject({ line: 'Execute', parts: ['Execute'], hover: 'Execute · 실행 중 · rt-1', waitingUnread: null })
    expect(seen.get('d-turn-none-waiting')).toMatchObject({ line: 'Execute', parts: ['Execute'], hover: 'Execute · 실행 중 · rt-1', waitingUnread: null })
    expect(seen.get('b-turn-waiting')).toMatchObject({
      line: 'Execute · 대기 3', parts: ['Execute', ' · 대기 3'], trailingWaiting: ' · 대기 3', waitingUnread: null,
      hover: 'Execute · 실행 중 · 대기 3 · rt-1',
    })
    // A waiting read failure stays first so a narrow row cannot drop it and look like 0 waiting.
    expect(seen.get('c-turn-unread')).toMatchObject({
      line: '대기 ? · Execute',
      parts: ['대기 ? · ', 'Execute'],
      waitingUnread: 'true',
      unreadMarker: '대기 목록 읽기 실패',
      trailingWaiting: null,
      hover: 'Execute · 실행 중 · 대기 목록 읽기 실패 · rt-1',
    })
    expect(seen.get('e-turn-words-unread')).toMatchObject({
      line: '대기 ? · 준비 중 · 작업공간 메모리',
      parts: ['대기 ? · ', '준비 중 · 작업공간 메모리'],
      waitingUnread: 'true',
      unreadMarker: '대기 목록 읽기 실패: store locked',
      trailingWaiting: null,
      hover: '준비 중 · 작업공간 메모리 · 대기 목록 읽기 실패 · rt-1',
    })
  })

  it('names one open tool and counts the rest, each a part of its own, and leaves where the call stands to the hover', () => {
    const seen = rows([
      keeper('a-several', {
        active_turn: turn([tool('Read', 'requested'), tool('Execute', 'executing'), tool('Grep', 'requested')]),
        waiting_summary: waiting(3),
      }),
      keeper('b-not-started', { active_turn: turn([tool('Read', 'requested'), tool('Grep', 'requested')]) }),
    ])
    expect(seen.get('a-several')).toMatchObject({
      line: 'Execute 외 2건 · 대기 3', parts: ['Execute', ' 외 2건', ' · 대기 3'], hover: 'Execute 외 2건 · 실행 중 · 대기 3 · rt-1',
    })
    expect(seen.get('b-not-started')).toMatchObject({
      line: 'Read 외 1건', parts: ['Read', ' 외 1건'], hover: 'Read 외 1건 · 호출 준비 · rt-1',
    })
  })

  it('keeps the end of a tool name apart from the front that gives way', () => {
    const seen = rows([
      keeper('a-qualified', { active_turn: turn([tool('mcp__masc__masc_board_search', 'executing')]) }),
      keeper('b-short', { active_turn: turn([tool('masc_fusion', 'executing')]) }),
      keeper('c-twelve', { active_turn: turn([tool('abcdefghijkl', 'executing')]) }),
      keeper('d-thirteen', { active_turn: turn([tool('abcdefghijklm', 'executing')]) }),
    ])
    expect(seen.get('a-qualified')).toMatchObject({ line: 'mcp__masc__masc_board_search', name: ['mcp__masc__masc_', 'board_search'] })
    expect(seen.get('b-short')?.name).toEqual(['masc_fusion'])
    expect(seen.get('c-twelve')?.name).toEqual(['abcdefghijkl'])
    expect(seen.get('d-thirteen')?.name).toEqual(['a', 'bcdefghijklm'])
  })

  it('says a turn that names no tool in the words of the sentence, as one part', () => {
    const seen = rows([
      keeper('a-no-list', { active_turn: turn(null) }),
      keeper('b-thinking', { active_turn: turn([{ kind: 'response', channel: 'thinking', started_at_unix: 11, since_unix: 12 }], null, 'streaming') }),
      keeper('c-preparing', {
        active_turn: turn([], { state: 'active', phase: 'workspace_memory', started_at_unix: 15 }),
        waiting_summary: waiting(2),
      }),
      keeper('d-step-stopped', { active_turn: turn([], { state: 'raised', phase: 'tools', started_at_unix: 15 }) }),
      keeper('e-attempt-failed', { active_turn: turn([tool('Execute', 'executing')], null, 'failed') }),
      keeper('f-unseen', { active_turn: { lane: 'autonomous', started_at_unix: 10, preview: null } }),
    ])
    expect(seen.get('a-no-list')).toMatchObject({ line: '도구 실행 중', words: '도구 실행 중', name: null })
    expect(seen.get('b-thinking')).toMatchObject({ line: '추론 중', words: '추론 중' })
    expect(seen.get('c-preparing')).toMatchObject({
      line: '준비 중 · 작업공간 메모리 · 대기 2', parts: ['준비 중 · 작업공간 메모리', ' · 대기 2'],
      hover: '준비 중 · 작업공간 메모리 · 대기 2 · rt-1',
    })
    expect(seen.get('d-step-stopped')).toMatchObject({ line: '도구 준비 중 예외', words: '도구 준비 중 예외' })
    expect(seen.get('e-attempt-failed')).toMatchObject({ line: '시도 실패', words: '시도 실패', name: null })
    expect(seen.get('f-unseen')).toMatchObject({ line: '턴 실행 중', words: '턴 실행 중', hover: '턴 실행 중 · rt-1' })
  })

  it('says a warning or a rest before a turn', () => {
    const inTurn = { active_turn: turn([tool('Execute', 'executing')]) }
    const seen = rows([
      keeper('a-blocked', { ...inTurn, runtime_blocker_summary: 'provider refused the key' }),
      keeper('b-resting', {
        ...inTurn, runtime_path_rest: { status: 'resting', runtime_id: 'rt-rest', release_at: null, release_basis: null },
      }),
    ])
    expect(seen.get('a-blocked')).toMatchObject({ line: '⚠ provider refused the key', parts: null })
    expect(seen.get('b-resting')).toMatchObject({ line: '⏸ 휴식 · rt-rest', parts: null })
  })

  it('lays what a turn sent since the snapshot over its own row and over no other', () => {
    const keepers = [
      keeper('alpha', { active_turn: turn([tool('Grep', 'executing')]) }),
      keeper('beta', { active_turn: turn([tool('Read', 'executing')]) }),
    ]
    const sent = retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'alpha', {
      ownerKey: 'A', receivedAt: 0, live: true,
      preview: preview([tool('Execute', 'executing'), tool('Read', 'requested')], null, 'tool', 2),
    })
    expect(rows(keepers).get('alpha')?.line).toBe('Grep')
    const seen = rows(keepers, sent)
    expect(seen.get('alpha')).toMatchObject({ line: 'Execute 외 1건', hover: 'Execute 외 1건 · 실행 중 · rt-1' })
    // The same owner key on another Keeper's turn is another turn.
    expect(seen.get('beta')?.line).toBe('Read')
  })
})
