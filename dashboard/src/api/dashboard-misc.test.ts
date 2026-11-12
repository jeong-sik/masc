import type { UnreadMessage } from './librarian-unread'
import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import {
  fetchKeeperMemoryHealth,
  type KeeperMemoryChangesByPass,
  type KeeperMemoryHealthLibrarianStalled,
  type KeeperMemoryHealthResponse,
} from './dashboard-misc'

// Every pass and change the server counts, none moved since it started.
function noMemoryChanges(): KeeperMemoryChangesByPass {
  const none = () => ({ added: 0, absorbed: 0, superseded: 0, dropped: 0 })
  return {
    admission: none(),
    durable: none(),
    continuity: none(),
    cleanup: none(),
    keeper_write: none(),
    keeper_delete: none(),
    operator_delete: none(),
  }
}

function keeperMemoryHealthPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v15',
    generated_at: 1_700_000_000,
    keepers: [{
      keeper_id: 'healthy',
      revision: 7,
      updated_at: 1_699_999_900,
      facts: 4,
      observed_facts: 3,
      derived_facts: 1,
      support_invalidations: 0,
      snapshot_bytes: 512,
      added: 1,
      removed: 2,
      snapshot_present: true,
      age_bins: [1, 1, 1, 1, ...Array<number>(20).fill(0)],
      facts_by_hour: [
        { recorded_at: 1_699_996_400, facts: 3 },
        { recorded_at: 1_699_999_900, facts: 4 },
      ],
      changes_since_start: {
        ...noMemoryChanges(),
        durable: { added: 4, absorbed: 3, superseded: 2, dropped: 1 },
      },
      context_cycle: { saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        pending: null, admission_wait: null, operator_action_required: false,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        continuity_unread_atoms: 0,
        last_success_at: null,
        last_failure_kind: null,
        stalled: null,
      },
      librarian_failures: 0,
      vision_ingest_errors: 0,
      vision_ingest_error_reasons: [],
      read_error: null,
      source_revision: 2,
      source_facts: 1,
      source_invalidations: 0,
      source_snapshot_bytes: 128,
      source_snapshot_present: true,
      source_read_error: null,
      alerts: [],
    }, {
      keeper_id: 'broken',
      revision: 0,
      updated_at: null,
      facts: 0,
      observed_facts: 0,
      derived_facts: 0,
      support_invalidations: 0,
      snapshot_bytes: 32,
      added: 0,
      removed: 0,
      snapshot_present: false,
      age_bins: null,
      facts_by_hour: [],
      changes_since_start: noMemoryChanges(),
      context_cycle: { saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        pending: null, admission_wait: null, operator_action_required: false,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        continuity_unread_atoms: 0,
        last_success_at: null,
        last_failure_kind: null,
        stalled: null,
      },
      librarian_failures: 0,
      vision_ingest_errors: 0,
      vision_ingest_error_reasons: [],
      read_error: 'invalid current snapshot',
      source_revision: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
      source_snapshot_present: false,
      source_read_error: null,
      alerts: [{
        code: 'snapshot_read_error',
        severity: 'warn',
        target: 'snapshot_read_error',
        label: '읽기',
        message: 'invalid current snapshot',
      }],
    }],
    totals: {
      facts: 4,
      observed_facts: 3,
      derived_facts: 1,
      support_invalidations: 0,
      snapshot_bytes: 544,
      added: 1,
      removed: 2,
      source_facts: 1,
      source_invalidations: 0,
      source_snapshot_bytes: 128,
      librarian_unread_turns: 0,
      librarian_continuity_unread_atoms: 0,
      librarian_continuity_unmeasured: 0,
      librarian_failures: 0,
      vision_ingest_errors: 0,
      read_errors: 1,
      source_read_errors: 0,
    },
    alert_summary: {
      total_alerts: 1,
      warn_alerts: 1,
      error_alerts: 0,
      keepers_with_alerts: 1,
      snapshot_read_error_keepers: 1,
      source_snapshot_read_error_keepers: 0,
      librarian_stopped_keepers: 0,
      librarian_attention_required_keepers: 0,
      librarian_starving_keepers: 0,
    },
  }
}

function addLibrarianAttention(payload: KeeperMemoryHealthResponse) {
  const keeper = payload.keepers[0]!
  keeper.librarian.operator_action_required = true
  keeper.alerts.push({ code: 'librarian_attention_required', severity: 'warn',
    target: 'librarian_attention_required', label: 'Librarian', message: 'Inspect the original outcome' })
  payload.alert_summary.total_alerts++
  payload.alert_summary.warn_alerts++
  payload.alert_summary.keepers_with_alerts++
  payload.alert_summary.librarian_attention_required_keepers++
}

function starvingKeeperPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v15',
    generated_at: 1_700_000_000,
    keepers: [{
      keeper_id: 'starving',
      revision: 0,
      updated_at: null,
      facts: 0,
      observed_facts: 0,
      derived_facts: 0,
      support_invalidations: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      snapshot_present: false,
      age_bins: null,
      facts_by_hour: [],
      changes_since_start: noMemoryChanges(),
      context_cycle: { saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        pending: null, admission_wait: null, operator_action_required: false,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        continuity_unread_atoms: 0,
        last_success_at: null,
        last_failure_kind: null,
        stalled: null,
      },
      librarian_failures: 4,
      vision_ingest_errors: 0,
      vision_ingest_error_reasons: [],
      read_error: null,
      source_revision: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
      source_snapshot_present: false,
      source_read_error: null,
      alerts: [{
        code: 'librarian_starvation',
        severity: 'error',
        target: 'librarian_starvation',
        label: 'Librarian',
        message: 'Librarian runs failed and no current-memory snapshot exists',
      }],
    }],
    totals: {
      facts: 0,
      observed_facts: 0,
      derived_facts: 0,
      support_invalidations: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
      librarian_unread_turns: 0,
      librarian_continuity_unread_atoms: 0,
      librarian_continuity_unmeasured: 0,
      librarian_failures: 4,
      vision_ingest_errors: 0,
      read_errors: 0,
      source_read_errors: 0,
    },
    alert_summary: {
      total_alerts: 1,
      warn_alerts: 0,
      error_alerts: 1,
      keepers_with_alerts: 1,
      snapshot_read_error_keepers: 0,
      source_snapshot_read_error_keepers: 0,
      librarian_stopped_keepers: 0,
      librarian_attention_required_keepers: 0,
      librarian_starving_keepers: 1,
    },
  }
}

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperMemoryHealth', () => {
  it.each([true, false])('keeps admission waits independent of the durable measurement: %s', async measured => {
    const payload = keeperMemoryHealthPayload()
    const admission_wait = { kind: 'worker' as const, installation_id: 'admission-installation',
      request_id: 'admission-request', wait: 'capacity' as const }
    Object.assign(payload.keepers[0]!.librarian, { admission_wait, ...(measured ? {} : {
      state: null, measured_at: null, unread_atom_turns: null, unread_official_turns: null,
    }) })
    if (!measured) payload.totals.librarian_unread_turns = null
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian.admission_wait).toEqual(admission_wait)
    expect(health.keepers[0]!.librarian.state).toBe(measured ? 'drained' : null)
    expect(health.keepers[0]!.librarian.measured_at).toBe(measured ? 1_699_999_950 : null)
    expect(health.keepers[0]!.librarian.pending).toBeNull()
  })

  it.each([
    undefined,
    { kind: 'publication', request_id: 'original', detail: 'settling' },
    { kind: 'basis_changed', request_id: 'original' },
    { kind: 'local_failure' },
    { kind: 'worker', installation_id: 'installation', request_id: 'original', wait: 'retry_anyway' },
    { kind: 'worker', installation_id: '', request_id: 'original', wait: 'capacity' },
    { kind: 'worker', request_id: 'original', wait: 'capacity' },
    { kind: 'worker', installation_id: 'installation', request_id: 'original', wait: 'capacity', replay: true },
  ])('refuses an admission observation that is neither an exact worker wait nor a failed pass: %o', async admission_wait => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, { admission_wait })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it.each([
    'capacity', 'processing', 'outcome_unknown', 'unreachable', 'missing_after_dispatch', 'journal_recheck',
  ] as const)('preserves the observed original worker wait %s', async wait => {
    const payload = keeperMemoryHealthPayload()
    const pending = { kind: 'worker' as const, installation_id: 'original-installation',
      request_id: 'original-request', wait }
    Object.assign(payload.keepers[0]!.librarian, { state: 'pending', pending })
    if (wait === 'outcome_unknown' || wait === 'missing_after_dispatch') addLibrarianAttention(payload)
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian.pending).toEqual(pending)
    expect(health.alert_summary.librarian_stopped_keepers).toBe(0)
    expect(health.keepers[0]!.librarian.operator_action_required)
      .toBe(wait === 'outcome_unknown' || wait === 'missing_after_dispatch')
  })

  it.each(['durable', 'admission', 'both'] as const)('counts %s attention once and retains both original identities', async source => {
    const payload = keeperMemoryHealthPayload()
    const librarian = payload.keepers[0]!.librarian
    const worker = { kind: 'worker' as const, installation_id: 'original-installation',
      request_id: 'durable-original', wait: 'missing_after_dispatch' as const }
    if (source !== 'admission') Object.assign(librarian, { state: 'pending', pending: worker })
    if (source !== 'durable') librarian.admission_wait = { ...worker, request_id: 'admission-original' }
    addLibrarianAttention(payload)
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian).toEqual(librarian)
    expect(health.alert_summary.librarian_attention_required_keepers).toBe(1)
    expect(health.alert_summary.librarian_stopped_keepers).toBe(0)
  })

  it('carries a failed admission pass as attention beside a drained durable pass', async () => {
    const payload = keeperMemoryHealthPayload()
    const admission_wait = { kind: 'local_failure' as const, detail: 'admission pass refused its records' }
    Object.assign(payload.keepers[0]!.librarian, { admission_wait })
    addLibrarianAttention(payload)
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian.admission_wait).toEqual(admission_wait)
    expect(health.keepers[0]!.librarian.state).toBe('drained')
    expect(health.keepers[0]!.librarian.pending).toBeNull()
    expect(health.alert_summary.librarian_attention_required_keepers).toBe(1)
    expect(health.alert_summary.librarian_stopped_keepers).toBe(0)
  })

  it('refuses a failed admission pass that does not ask for operator action', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, {
      admission_wait: { kind: 'local_failure', detail: 'admission pass refused its records' },
    })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('treats a typed local recovery failure as attention without a stopped pass', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, {
      state: 'pending', pending: { kind: 'local_failure', detail: 'publication read failed' },
    })
    addLibrarianAttention(payload)
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.librarian.operator_action_required).toBe(true)
  })

  it('refuses contradictory attention flags, missing or duplicate alerts, and fleet counts', async () => {
    const mutations: Array<(payload: KeeperMemoryHealthResponse) => void> = [
      payload => { payload.keepers[0]!.librarian.operator_action_required = false },
      payload => { payload.keepers[0]!.alerts = [] },
      payload => { payload.keepers[0]!.alerts.push(payload.keepers[0]!.alerts[0]!) },
      payload => { payload.alert_summary.librarian_attention_required_keepers = 2 },
      payload => { payload.keepers[0]!.librarian.pending = null; payload.keepers[0]!.librarian.state = 'drained' },
    ]
    for (const mutate of mutations) {
      const payload = keeperMemoryHealthPayload()
      Object.assign(payload.keepers[0]!.librarian, { state: 'pending', pending: {
        kind: 'worker', installation_id: 'installation', request_id: 'original', wait: 'outcome_unknown',
      } })
      addLibrarianAttention(payload)
      mutate(payload)
      getMock.mockResolvedValue(payload)
      await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
    }
  })

  it.each([
    { kind: 'worker', installation_id: 'installation', request_id: 'original', wait: 'retry_anyway' },
    { kind: 'worker', installation_id: '', request_id: 'original', wait: 'processing' },
    { kind: 'publication', request_id: 'original', detail: 'settling', replay: true },
    null,
  ])('refuses a pending pass without a supported original observation: %o', async pending => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, { state: 'pending', pending })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('accepts a yielding Librarian without reporting it stopped or caught up', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, {
      state: 'yielded_to_waiting_unit', detail: null, unread_atom_turns: 1,
    })
    payload.totals.librarian_unread_turns = 1
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian.state).toBe('yielded_to_waiting_unit')
    expect(health.keepers[0]!.librarian.unread_atom_turns).toBe(1)
    expect(health.alert_summary.librarian_stopped_keepers).toBe(0)
  })

  it('retains suspended work and unread input without a stopped or drained result', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.librarian, {
      state: 'pending', detail: null, pending: { kind: 'publication', request_id: 'original', detail: 'settling' }, unread_atom_turns: 2, unread_official_turns: 1,
    })
    payload.totals.librarian_unread_turns = 3
    getMock.mockResolvedValue(payload)
    const health = await fetchKeeperMemoryHealth()
    expect(health.keepers[0]!.librarian.state).toBe('pending')
    expect(health.keepers[0]!.librarian.unread_atom_turns).toBe(2)
    expect(health.keepers[0]!.librarian.unread_official_turns).toBe(1)
    expect(health.alert_summary.librarian_stopped_keepers).toBe(0)
  })

  it('keeps saved and prepared frontiers separate without inventing provider success', async () => {
    const payload = keeperMemoryHealthPayload()
    const saved = { trace_id: 'trace-a', end_atom: 12, boundary_line: 8 }
    const prepared = { prepared_at: 1_700_000_000, runtime_id: 'fixture.model',
      input: { kind: 'summarized' as const, frontier: { ...saved, end_atom: 8, boundary_line: 6 } },
      request_bytes: 4096 }
    payload.keepers[0]!.context_cycle = { saved, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared, synthesis: null }
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle).toEqual({
      saved, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared, synthesis: null,
    })
  })

  it('keeps the Librarian read position beside the cut it is read against', async () => {
    const payload = keeperMemoryHealthPayload()
    const saved = { trace_id: 'trace-a', end_atom: 7694, boundary_line: 385 }
    Object.assign(payload.keepers[0]!.context_cycle, {
      saved, read_position: 12887, rewriting_through: 12888,
    })
    getMock.mockResolvedValue(payload)
    const cycle = (await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle
    expect(cycle.read_position).toBe(12887)
    expect(cycle.rewriting_through).toBe(12888)
    expect(cycle.saved?.end_atom).toBe(7694)
  })

  it.each([
    // a marker and a number at once: one of them is wrong
    { saved: null, read_position: 12887, read_position_read_error: 'progress_unreadable', rewriting_through: null },
    // a rewrite target the cut already reached, and one with no cut to be past
    { saved: { trace_id: 'trace-a', end_atom: 7694, boundary_line: 385 }, read_position: null,
      read_position_read_error: null, rewriting_through: 7694 },
    { saved: null, read_position: null, read_position_read_error: null, rewriting_through: 12888 },
    { saved: null, read_position: 0, read_position_read_error: null, rewriting_through: null },
  ])('rejects a read position that disagrees with its own cycle: %o', async fields => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.context_cycle, fields)
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('keeps synthesis failure and atom range separate from an ordinary drained consumer', async () => {
    const payload = keeperMemoryHealthPayload()
    const synthesis = { observed_at: 1, trace_id: 'trace-a', state: 'not_committed', stop_reason: 'no_smaller_range_evidence',
      range: { start_atom: 4, end_atom: 6, completed_end_atom: 20 } }
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis })
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.synthesis).toEqual(synthesis)
  })

  it.each([
    ['source_unavailable', null], ['source_unavailable', 'source_read_failed'],
    ['input_unavailable', 'input_build_failed'],
    ['not_committed', 'no_smaller_range_evidence'], ['not_committed', 'narrowed_for_next_signal'],
    ['not_committed', 'indivisible_unit_uncommitted'], ['not_committed', 'observed_capacity_unfit'],
    ['not_committed', 'raised_during_pass'], ['capacity_refused', 'observed_capacity_unfit'],
    ['capacity_refused', 'observed_capacity_disagrees'],
  ])('preserves the local stop branch %s/%s', async (state, stop_reason) => {
    const payload = keeperMemoryHealthPayload()
    const synthesis = { observed_at: 1, trace_id: 'trace-a', state, stop_reason, range: null }
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis })
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.synthesis).toEqual(synthesis)
  })

  it.each([
    { state: 'running', stop_reason: 'narrowed_for_next_signal' },
    { state: 'not_committed', stop_reason: 'source_read_failed' },
    { state: 'capacity_refused', stop_reason: 'raised_during_pass' },
    { state: 'not_committed', stop_reason: null },
    { state: 'not_committed', stop_reason: 'provider_quota' },
    { state: 'not_committed', stop_reason: 'no_smaller_range_evidence', detail: 'PRIVATE' },
  ])('rejects inferred reasons, stale reasons, and raw details: %o', async fields => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis: {
      observed_at: 1, trace_id: 'trace-a', range: { start_atom: 0, end_atom: 1, completed_end_atom: 1 }, ...fields,
    } })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it.each([
    { observed_at: 1, trace_id: 'trace-a', state: 'drained', stop_reason: null, range: null },
    { observed_at: 1, trace_id: 'trace-a', state: 'running', stop_reason: null, range: null },
    { observed_at: 1, trace_id: null, state: 'running', stop_reason: null,
      range: { start_atom: 4, end_atom: 6, completed_end_atom: 20 } },
  ])('rejects synthesis without valid source evidence: %o', async synthesis => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('keeps an absorbed request as a position with no boundary line and no summary', async () => {
    const payload = keeperMemoryHealthPayload()
    const prepared = { prepared_at: 1_700_000_000, runtime_id: 'fixture.model',
      input: { kind: 'absorbed' as const, frontier: { trace_id: 'trace-a', end_atom: 12719 } },
      request_bytes: 4096 }
    payload.keepers[0]!.context_cycle = { saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, prepared, synthesis: null }
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.prepared).toEqual(prepared)
  })

  it.each([
    { kind: 'absorbed', frontier: null },
    { kind: 'absorbed', frontier: { trace_id: 'trace-a', end_atom: 8, boundary_line: 6 } },
    { kind: 'absorbed', frontier: { trace_id: 'trace-a', end_atom: 0 } },
    { kind: 'summarized', frontier: { trace_id: 'trace-a', end_atom: 8 } },
  ])('rejects a position in the wrong shape for its kind: %o', async input => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { context_cycle: {
      saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, synthesis: null,
      prepared: { prepared_at: 1, runtime_id: 'fixture.model', request_bytes: 5, input },
    } })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('rejects a summarized request without a frontier', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { context_cycle: {
      saved: null, saved_read_error: null, read_position: null, read_position_read_error: null, rewriting_through: null, unread: { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [] } }, synthesis: null,
      prepared: { prepared_at: 1, runtime_id: 'fixture.model', request_bytes: 5,
        input: { kind: 'summarized', frontier: null } },
    } })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it.each([
    'keeper.memory_os.current_health.v10',
    'keeper.memory_os.current_health.v11',
    'keeper.memory_os.current_health.v12',
    'keeper.memory_os.current_health.v13',
    'keeper.memory_os.current_health.v14',
  ])('rejects an older memory-health envelope: %s', async schema => {
    getMock.mockResolvedValue({ ...keeperMemoryHealthPayload(), schema })

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('decodes the exact current-snapshot health contract', async () => {
    getMock.mockResolvedValue(keeperMemoryHealthPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.schema).toBe('keeper.memory_os.current_health.v15')
    expect(response.keepers[0]).toMatchObject({
      keeper_id: 'healthy',
      revision: 7,
      updated_at: 1_699_999_900,
      facts: 4,
      snapshot_bytes: 512,
      age_bins: [1, 1, 1, 1, ...Array<number>(20).fill(0)],
      facts_by_hour: [
        { recorded_at: 1_699_996_400, facts: 3 },
        { recorded_at: 1_699_999_900, facts: 4 },
      ],
    })
    expect(response.keepers[0]?.changes_since_start.durable)
      .toEqual({ added: 4, absorbed: 3, superseded: 2, dropped: 1 })
    expect(response.keepers[1]?.read_error).toBe('invalid current snapshot')
    expect(response.keepers[1]?.updated_at).toBeNull()
    expect(response.alert_summary.snapshot_read_error_keepers).toBe(1)
  })

  it.each([
    ['the four-key object', { under_hour: 1, under_day: 1, under_week: 1, older: 1 }],
    ['23 counts', [1, 1, 1, 1, ...Array<number>(19).fill(0)]],
    ['25 counts', [1, 1, 1, 1, ...Array<number>(21).fill(0)]],
    ['24 counts that miss a fact', [1, 1, 1, ...Array<number>(21).fill(0)]],
    ['a negative count', [5, -1, ...Array<number>(22).fill(0)]],
  ])('rejects an age ladder that is not 24 counts adding up to the facts: %s', async (_label, age_bins) => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { age_bins })
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it.each([
    ['two points in one clock hour', { facts_by_hour: [
      { recorded_at: 1_699_999_200, facts: 3 },
      { recorded_at: 1_699_999_900, facts: 4 },
    ] }],
    ['more points than the trend hours', { facts_by_hour: Array.from(
      { length: 169 }, (_, hour) => ({ recorded_at: hour * 3600, facts: 4 })) }],
    ['a change table without a pass', { changes_since_start: Object.fromEntries(
      Object.entries(noMemoryChanges()).filter(([pass]) => pass !== 'operator_delete')) }],
    ['a change table with another pass', { changes_since_start: {
      ...noMemoryChanges(), later_pass: { added: 0, absorbed: 0, superseded: 0, dropped: 0 },
    } }],
    ['a negative change count', { changes_since_start: {
      ...noMemoryChanges(), cleanup: { added: 0, absorbed: 0, superseded: 0, dropped: -1 },
    } }],
  ])('rejects a trend or change table the server does not write: %s', async (_label, fields) => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, fields)
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it.each([undefined, '1699999900', -1, NaN, Infinity, null])(
    'rejects invalid timestamps for a readable snapshot: %s',
    async (updated_at) => {
      const payload = keeperMemoryHealthPayload()
      Object.assign(payload.keepers[0]!, { updated_at })
      getMock.mockResolvedValue(payload)

      await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
        '유효하지 않은 keeper memory health payload',
      )
    },
  )

  it('rejects a timestamp without a readable snapshot', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[1]!.updated_at = 1_699_999_900
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a retired Memory health field', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { facts_bytes: 512 })
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects totals that disagree with the keeper rows', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.totals.facts = 5
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a fact total that disagrees with observed and derived facts', async () => {
    const payload = keeperMemoryHealthPayload()
    const keeper = payload.keepers[0]
    if (keeper === undefined) throw new Error('fixture keeper missing')
    keeper.derived_facts = 2
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects alert summaries that disagree with the actual alerts', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.alert_summary.total_alerts = 0
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects duplicate keeper ids', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[1]!.keeper_id = 'healthy'
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects an alert whose typed target disagrees with its code', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[1]!.alerts[0]!.target = 'librarian_stopped'
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('keeps an unmeasured librarian as null rather than zero', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.totals.librarian_unread_turns = null
    payload.keepers[0]!.librarian = {
      state: null,
      detail: null,
      pending: null, admission_wait: null, operator_action_required: false,
      measured_at: null,
      unread_atom_turns: null,
      unread_official_turns: null,
      continuity_unread_atoms: 0,
      last_success_at: null,
      last_failure_kind: null,
      stalled: null,
    }

    getMock.mockResolvedValue(payload)
    const response = await fetchKeeperMemoryHealth()

    expect(response.keepers[0]?.librarian.unread_atom_turns).toBeNull()
    expect(response.totals.librarian_unread_turns).toBeNull()
  })

  it('keeps an unmeasured continuity lag as null and counts it beside the sum', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.librarian.continuity_unread_atoms = null
    payload.keepers[1]!.librarian.continuity_unread_atoms = 4
    payload.totals.librarian_continuity_unread_atoms = 4
    payload.totals.librarian_continuity_unmeasured = 1
    getMock.mockResolvedValue(payload)
    const response = await fetchKeeperMemoryHealth()
    expect(response.keepers[0]?.librarian.continuity_unread_atoms).toBeNull()
    expect(response.keepers[1]?.librarian.continuity_unread_atoms).toBe(4)
    expect(response.totals.librarian_continuity_unread_atoms).toBe(4)
    expect(response.totals.librarian_continuity_unmeasured).toBe(1)
  })

  it('decodes the Librarian_stalled gap and refuses one that does not end after it starts', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.librarian.stalled = { kind: 'gap', gap_start_atom: 2, gap_end_atom: 8 }
    getMock.mockResolvedValue(payload)
    const response = await fetchKeeperMemoryHealth()
    expect(response.keepers[0]?.librarian.stalled)
      .toEqual({ kind: 'gap', gap_start_atom: 2, gap_end_atom: 8 })
    expect(response.keepers[1]?.librarian.stalled).toBeNull()
    const empty = keeperMemoryHealthPayload()
    empty.keepers[0]!.librarian.stalled = { kind: 'gap', gap_start_atom: 8, gap_end_atom: 8 }
    getMock.mockResolvedValue(empty)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('decodes an unmeasured Librarian_stalled apart from no gap and refuses an unknown cause', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.librarian.stalled =
      { kind: 'unmeasured', cause: 'turn_records_unreadable', detail: 'bad row' }
    getMock.mockResolvedValue(payload)
    const response = await fetchKeeperMemoryHealth()
    expect(response.keepers[0]?.librarian.stalled)
      .toEqual({ kind: 'unmeasured', cause: 'turn_records_unreadable', detail: 'bad row' })
    const unknown = keeperMemoryHealthPayload()
    const raw: unknown = { kind: 'unmeasured', cause: 'disk_on_fire', detail: 'x' }
    unknown.keepers[0]!.librarian.stalled = raw as KeeperMemoryHealthLibrarianStalled
    getMock.mockResolvedValue(unknown)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('rejects a continuity sum or an unmeasured count that disagrees with the rows', async () => {
    const summed = keeperMemoryHealthPayload()
    summed.keepers[0]!.librarian.continuity_unread_atoms = 4
    getMock.mockResolvedValue(summed)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
    const counted = keeperMemoryHealthPayload()
    counted.keepers[0]!.librarian.continuity_unread_atoms = null
    getMock.mockResolvedValue(counted)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('rejects a numeric fleet total when any keeper count is unknown', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.librarian.unread_atom_turns = null
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('keeps the empty fleet unread total at zero', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers = []
    for (const key of Object.keys(payload.totals) as (keyof typeof payload.totals)[]) payload.totals[key] = 0
    for (const key of Object.keys(payload.alert_summary) as (keyof typeof payload.alert_summary)[]) payload.alert_summary[key] = 0
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).totals.librarian_unread_turns).toBe(0)
  })

  it('rejects a librarian state this build does not know', async () => {
    const payload = keeperMemoryHealthPayload()
    const unknown = { ...payload.keepers[0]!.librarian, state: 'resting' }
    payload.keepers[0]!.librarian =
      unknown as KeeperMemoryHealthResponse['keepers'][number]['librarian']
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a librarian count with no time it was taken at', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.librarian.measured_at = null
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('decodes the error-severity librarian starvation contract', async () => {
    getMock.mockResolvedValue(starvingKeeperPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.keepers[0]).toMatchObject({
      keeper_id: 'starving',
      snapshot_present: false,
      librarian_failures: 4,
    })
    expect(response.keepers[0]?.alerts[0]?.severity).toBe('error')
    expect(response.alert_summary.error_alerts).toBe(1)
    expect(response.alert_summary.librarian_starving_keepers).toBe(1)
  })

  it('decodes a source snapshot read error without folding it into ordinary read errors', async () => {
    const payload = keeperMemoryHealthPayload()
    const broken = payload.keepers[1]!
    broken.source_snapshot_bytes = 32
    broken.source_read_error = 'invalid source-bound snapshot'
    broken.alerts.push({
      code: 'source_snapshot_read_error',
      severity: 'warn',
      target: 'source_snapshot_read_error',
      label: '소스 읽기',
      message: broken.source_read_error,
    })
    payload.totals.source_snapshot_bytes = 160
    payload.totals.source_read_errors = 1
    payload.alert_summary.total_alerts = 2
    payload.alert_summary.warn_alerts = 2
    payload.alert_summary.source_snapshot_read_error_keepers = 1
    getMock.mockResolvedValue(payload)

    const response = await fetchKeeperMemoryHealth()

    expect(response.keepers[1]?.source_read_error).toBe('invalid source-bound snapshot')
    expect(response.totals.read_errors).toBe(1)
    expect(response.totals.source_read_errors).toBe(1)
    expect(response.alert_summary.source_snapshot_read_error_keepers).toBe(1)
  })

  it('decodes exact Vision ingest reasons instead of a count with no cause', async () => {
    const payload = keeperMemoryHealthPayload()
    const keeper = payload.keepers[0]!
    keeper.vision_ingest_errors = 3
    keeper.vision_ingest_error_reasons = [
      { reason: 'fetch_failed', count: 2 },
      { reason: 'unsupported_media_type', count: 1 },
    ]
    keeper.alerts.push({
      code: 'vision_ingest_errors',
      severity: 'warn',
      target: 'vision_ingest_errors',
      label: 'Vision',
      message: 'Image ingestion failed 3 times.',
    })
    payload.totals.vision_ingest_errors = 3
    payload.alert_summary.total_alerts = 2
    payload.alert_summary.warn_alerts = 2
    payload.alert_summary.keepers_with_alerts = 2
    getMock.mockResolvedValue(payload)

    const response = await fetchKeeperMemoryHealth()

    expect(response.keepers[0]?.vision_ingest_error_reasons).toEqual([
      { reason: 'fetch_failed', count: 2 },
      { reason: 'unsupported_media_type', count: 1 },
    ])
    expect(response.totals.vision_ingest_errors).toBe(3)
  })

  it('rejects an alert whose severity disagrees with its code', async () => {
    const payload = starvingKeeperPayload()
    payload.keepers[0]!.alerts[0]!.severity = 'warn'
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects an alert that carries legacy threshold or value fields', async () => {
    const payloadWithThreshold = starvingKeeperPayload()
    ;(payloadWithThreshold.keepers[0]!.alerts[0] as unknown as Record<string, unknown>).threshold = 0
    getMock.mockResolvedValue(payloadWithThreshold)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )

    const payloadWithValue = starvingKeeperPayload()
    ;(payloadWithValue.keepers[0]!.alerts[0] as unknown as Record<string, unknown>).value = 4
    getMock.mockResolvedValue(payloadWithValue)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })
  it('retains exact unread evidence and independent source failures', async () => {
    const payload = keeperMemoryHealthPayload()
    const cycle = payload.keepers[0]!.context_cycle
    cycle.saved = { trace_id: 'evidence', end_atom: 1, boundary_line: 1 }
    const atom: UnreadMessage = { source: { kind: 'atom', trace_id: 'evidence',
      history_start_boundary_line: 1, atom: 0, message_in_atom: 0, message_sha256: 'a'.repeat(64) },
      reasons: ['context_overflow', 'request_body_refused'] }
    const official: UnreadMessage = { source: { kind: 'official_turn', turn_ref: 'earlier#trace#3',
      boundary_line: 2, message_in_turn: 1, message_sha256: 'b'.repeat(64) }, reasons: ['input_capacity'] }
    cycle.unread = { snapshot: { kind: 'available', messages: [atom] },
      memory: { kind: 'available', messages: [atom, official] } }
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.unread).toEqual(cycle.unread)
    cycle.unread.memory = { kind: 'unavailable' }
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.unread).toEqual(cycle.unread)
    cycle.unread.memory = { kind: 'available', messages: [official] }
    cycle.unread.snapshot = { kind: 'unavailable' }
    cycle.saved = null
    cycle.saved_read_error = 'snapshot_unreadable'
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.unread).toEqual(cycle.unread)
  })

  it.each([
    undefined,
    { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'unavailable', messages: [] } },
    { snapshot: { kind: 'available', messages: [] }, memory: { kind: 'available', messages: [
      { source: { kind: 'atom', trace_id: 't', history_start_boundary_line: 1, atom: 0,
        message_in_atom: 0, message_sha256: 'a'.repeat(64) }, reasons: ['invalid_request'] },
    ] } },
    { snapshot: { kind: 'available', messages: [
      { source: { kind: 'official_turn', turn_ref: 't#1', boundary_line: 1,
        message_in_turn: 0, message_sha256: 'a'.repeat(64) }, reasons: ['input_capacity'] },
    ] }, memory: { kind: 'available', messages: [] } },
  ])('refuses missing or invalid unread evidence without inventing an empty reading', async unread => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.context_cycle, {
      saved: { trace_id: 't', end_atom: 1, boundary_line: 1 }, unread,
    })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

})
