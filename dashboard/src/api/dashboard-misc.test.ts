import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import {
  fetchKeeperMemoryHealth,
  type KeeperMemoryHealthResponse,
} from './dashboard-misc'

function keeperMemoryHealthPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v7',
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
      context_cycle: { saved: null, saved_read_error: null, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        last_success_at: null,
        last_failure_kind: null,
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
      context_cycle: { saved: null, saved_read_error: null, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        last_success_at: null,
        last_failure_kind: null,
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
      librarian_starving_keepers: 0,
    },
  }
}

function starvingKeeperPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v7',
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
      context_cycle: { saved: null, saved_read_error: null, prepared: null, synthesis: null },
      librarian: {
        state: 'drained',
        detail: null,
        measured_at: 1_699_999_950,
        unread_atom_turns: 0,
        unread_official_turns: 0,
        last_success_at: null,
        last_failure_kind: null,
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
      librarian_starving_keepers: 1,
    },
  }
}

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperMemoryHealth', () => {
  it('keeps saved and prepared frontiers separate without inventing provider success', async () => {
    const payload = keeperMemoryHealthPayload()
    const saved = { trace_id: 'trace-a', end_atom: 12, boundary_line: 8 }
    const prepared = { prepared_at: 1_700_000_000, runtime_id: 'fixture.model',
      input: { kind: 'summarized' as const, frontier: { ...saved, end_atom: 8, boundary_line: 6 } },
      request_bytes: 4096 }
    payload.keepers[0]!.context_cycle = { saved, saved_read_error: null, prepared, synthesis: null }
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle).toEqual({
      saved, saved_read_error: null, prepared, synthesis: null,
    })
  })

  it('keeps synthesis failure and atom range separate from an ordinary drained consumer', async () => {
    const payload = keeperMemoryHealthPayload()
    const synthesis = { observed_at: 1, trace_id: 'trace-a', state: 'not_committed',
      range: { start_atom: 4, end_atom: 6, completed_end_atom: 20 } }
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis })
    getMock.mockResolvedValue(payload)
    expect((await fetchKeeperMemoryHealth()).keepers[0]!.context_cycle.synthesis).toEqual(synthesis)
  })

  it.each([
    { observed_at: 1, trace_id: 'trace-a', state: 'drained', range: null },
    { observed_at: 1, trace_id: 'trace-a', state: 'running', range: null },
    { observed_at: 1, trace_id: null, state: 'running',
      range: { start_atom: 4, end_atom: 6, completed_end_atom: 20 } },
  ])('rejects synthesis without valid source evidence: %o', async synthesis => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!.context_cycle, { synthesis })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('rejects a summarized request without a frontier', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { context_cycle: {
      saved: null, saved_read_error: null, synthesis: null,
      prepared: { prepared_at: 1, runtime_id: 'fixture.model', request_bytes: 5,
        input: { kind: 'summarized', frontier: null } },
    } })
    getMock.mockResolvedValue(payload)
    await expect(fetchKeeperMemoryHealth()).rejects.toThrow('유효하지 않은 keeper memory health payload')
  })

  it('decodes the exact current-snapshot health contract', async () => {
    getMock.mockResolvedValue(keeperMemoryHealthPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.schema).toBe('keeper.memory_os.current_health.v7')
    expect(response.keepers[0]).toMatchObject({
      keeper_id: 'healthy',
      revision: 7,
      updated_at: 1_699_999_900,
      facts: 4,
      snapshot_bytes: 512,
    })
    expect(response.keepers[1]?.read_error).toBe('invalid current snapshot')
    expect(response.keepers[1]?.updated_at).toBeNull()
    expect(response.alert_summary.snapshot_read_error_keepers).toBe(1)
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
      measured_at: null,
      unread_atom_turns: null,
      unread_official_turns: null,
      last_success_at: null,
      last_failure_kind: null,
    }

    getMock.mockResolvedValue(payload)
    const response = await fetchKeeperMemoryHealth()

    expect(response.keepers[0]?.librarian.unread_atom_turns).toBeNull()
    expect(response.totals.librarian_unread_turns).toBeNull()
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
})
