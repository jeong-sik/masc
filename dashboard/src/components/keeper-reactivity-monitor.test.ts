import { html } from 'htm/preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { isKeeperPaused } from '../lib/keeper-predicates'
import type { DashboardKeeperReactionLedgerHealth, Keeper } from '../types'
import { ReactionLedgerPanel } from './keeper-reactivity-monitor'

function reactionLedger(
  overrides: Partial<DashboardKeeperReactionLedgerHealth> = {},
): DashboardKeeperReactionLedgerHealth {
  return {
    schema: 'masc.keeper_reaction_ledger.fleet_summary.v3',
    status: 'ok',
    status_reasons: [],
    operator_action_required: false,
    empty: false,
    keeper_count: 1,
    keeper_names: ['sangsu'],
    keeper_name_discovery_error_count: 0,
    keeper_name_discovery_errors: [],
    counts_complete: true,
    pending_id_display_limit_per_keeper: 4,
    row_count: 8,
    stimulus_count: 2,
    reaction_count: 6,
    turn_started_count: 1,
    event_queue_ack_count: 1,
    event_queue_requeue_count: 0,
    event_queue_escalation_count: 0,
    event_queue_external_input_count: 0,
    cursor_ack_count: 1,
    cursor_swept_stimulus_count: 0,
    orphan_reaction_stimulus_count: 0,
    in_progress_stimulus_count: 0,
    acked_stimulus_count: 1,
    escalated_stimulus_count: 0,
    external_input_requested_stimulus_count: 0,
    pending_stimulus_count: 1,
    reaction_store_discovered_keeper_count: 1,
    reaction_store_discovered_keeper_names: ['sangsu'],
    reaction_store_discovery_error_count: 0,
    reaction_store_discovery_errors: [],
    read_error_count: 0,
    pending_by_keeper: [{
      keeper_name: 'sangsu',
      pending_stimulus_count: 1,
      pending_ids_truncated: false,
      pending_stimulus_ids: ['stimulus-pending'],
    }],
    keepers: [{
      schema: 'masc.keeper_reaction_ledger.summary.v3',
      keeper_name: 'sangsu',
      status: 'degraded',
      operator_action_required: true,
      counts_complete: true,
      pending_id_display_limit: 4,
      row_count: 8,
      stimulus_count: 2,
      reaction_count: 6,
      turn_started_count: 1,
      event_queue_ack_count: 1,
      event_queue_requeue_count: 0,
      event_queue_escalation_count: 0,
      event_queue_external_input_count: 0,
      cursor_ack_count: 1,
      cursor_swept_stimulus_count: 0,
      orphan_reaction_stimulus_count: 0,
      in_progress_stimulus_count: 0,
      acked_stimulus_count: 1,
      escalated_stimulus_count: 0,
      external_input_requested_stimulus_count: 0,
      pending_stimulus_count: 1,
      pending_ids_truncated: false,
      pending_stimulus_ids: ['stimulus-pending'],
      latest_recorded_at_unix: 1_700_000_000,
      latest_stimulus_id: 'stimulus-latest',
      read_error: null,
    }],
    ...overrides,
    decode_errors: overrides.decode_errors ?? [],
  }
}

afterEach(() => {
  cleanup()
})

describe('isKeeperPaused', () => {
  function keeper(overrides: Partial<Keeper>): Keeper {
    return { name: 'test', status: 'active', ...overrides } satisfies Keeper
  }

  it('returns true when paused flag is set', () => {
    expect(isKeeperPaused(keeper({ paused: true }))).toBe(true)
  })

  it('returns true when phase is Paused', () => {
    expect(isKeeperPaused(keeper({ phase: 'Paused' }))).toBe(true)
  })

  it('returns true when pipeline_stage is paused', () => {
    expect(isKeeperPaused(keeper({ pipeline_stage: 'paused' }))).toBe(true)
  })

  it('returns false for a running keeper', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running', paused: false }))).toBe(false)
  })

  it('returns false when paused is false and phase is Running', () => {
    expect(isKeeperPaused(keeper({ paused: false, phase: 'Running', pipeline_stage: 'idle' }))).toBe(false)
  })

  it('returns false when paused is undefined', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running' }))).toBe(false)
  })
})

describe('ReactionLedgerPanel', () => {
  it('renders unavailable observation explicitly instead of treating it as zero', () => {
    render(html`<${ReactionLedgerPanel} ledger=${null} />`)

    expect(screen.getByText(/반응 ledger 관측값을 사용할 수 없습니다/)).toBeTruthy()
    expect(document.querySelector('[data-keeper-reaction-ledger-unavailable]')).toBeTruthy()
  })

  it('renders fleet to keeper to stimulus hierarchy from the durable ledger projection', () => {
    render(html`<${ReactionLedgerPanel} ledger=${reactionLedger()} />`)

    expect(screen.getByText('Durable reaction ledger')).toBeTruthy()
    expect(document.querySelector('[data-keeper-reaction-ledger-row="sangsu"]')).toBeTruthy()
    expect(screen.getByText('stimulus-latest')).toBeTruthy()
    expect(screen.getByText('stimulus-pending')).toBeTruthy()
    expect(screen.queryByText('재시작 예산 게이지')).toBeNull()
  })

  it('keeps unknown counts and discovery/read failures visible', () => {
    const keeper = reactionLedger().keepers[0]
    if (keeper == null) throw new Error('reaction ledger fixture must contain one keeper')
    const ledger = reactionLedger({
      status: null,
      counts_complete: null,
      pending_stimulus_count: null,
      keeper_name_discovery_error_count: 1,
      keeper_name_discovery_errors: ['metadata directory unavailable'],
      reaction_store_discovery_error_count: 1,
      reaction_store_discovery_errors: ['snapshot inventory unreadable'],
      read_error_count: 1,
      keepers: [{
        ...keeper,
        counts_complete: false,
        row_count: null,
        stimulus_count: null,
        reaction_count: null,
        turn_started_count: null,
        event_queue_ack_count: null,
        event_queue_requeue_count: null,
        event_queue_escalation_count: null,
        event_queue_external_input_count: null,
        cursor_ack_count: null,
        cursor_swept_stimulus_count: null,
        orphan_reaction_stimulus_count: null,
        in_progress_stimulus_count: null,
        acked_stimulus_count: null,
        escalated_stimulus_count: null,
        external_input_requested_stimulus_count: null,
        pending_stimulus_count: null,
        pending_ids_truncated: null,
        read_error: 'sqlite schema mismatch',
      }],
    })

    render(html`<${ReactionLedgerPanel} ledger=${ledger} />`)

    expect(screen.getAllByText('알 수 없음').length).toBeGreaterThan(0)
    expect(screen.getByText(/아래의 알 수 없음 값을 0으로 해석하지 마세요/)).toBeTruthy()
    expect(screen.getByText(/metadata directory unavailable/)).toBeTruthy()
    expect(screen.getByText(/snapshot inventory unreadable/)).toBeTruthy()
    expect(screen.getByText(/sqlite schema mismatch/)).toBeTruthy()
    const failedKeeper = document.querySelector('[data-keeper-reaction-ledger-row="sangsu"]')
    expect(failedKeeper?.textContent?.match(/알 수 없음/g)?.length).toBeGreaterThan(8)
  })
})
