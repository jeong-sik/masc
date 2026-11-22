import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import {
  fetchKeeperMemoryHealth,
  type KeeperMemoryChangesByPass,
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
    schema: 'keeper.memory_os.current_health.v19',
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
      writer: { kind: 'no_writer' },
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
      writer: { kind: 'no_writer' },
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
      librarian_starving_keepers: 0,
    },
  }
}

function starvingKeeperPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v19',
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
      writer: { kind: 'no_writer' },
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
      librarian_starving_keepers: 1,
    },
  }
}

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperMemoryHealth', () => {
  it.each([
    'keeper.memory_os.current_health.v10',
    'keeper.memory_os.current_health.v11',
    'keeper.memory_os.current_health.v12',
    'keeper.memory_os.current_health.v13',
    'keeper.memory_os.current_health.v14',
    'keeper.memory_os.current_health.v15',
    'keeper.memory_os.current_health.v16',
    'keeper.memory_os.current_health.v17',
    'keeper.memory_os.current_health.v18',
  ])('rejects an older memory-health envelope: %s', async schema => {
    getMock.mockResolvedValue({ ...keeperMemoryHealthPayload(), schema })

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('reads the closed tags of a row writer and leaves its state fields unread', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { writer: { kind: 'writer', row: {
      state: 'resting', level: 'error', alarms: ['E3', 'W1'], unread: true,
    } } })
    getMock.mockResolvedValue(payload)

    expect((await fetchKeeperMemoryHealth()).keepers[0]!.writer).toEqual({
      kind: 'writer', row: { state: 'resting', level: 'error', alarms: ['E3', 'W1'] },
    })
  })

  it('reads a row from a process that runs no writer', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { writer: { kind: 'none_in_process' } })
    getMock.mockResolvedValue(payload)

    expect((await fetchKeeperMemoryHealth()).keepers[0]!.writer).toEqual({ kind: 'none_in_process' })
  })

  it.each([
    { kind: 'later' },
    { kind: 'no_writer', row: {} },
    { kind: 'writer' },
    { kind: 'writer', row: { state: 'paused', level: 'ok', alarms: [] } },
    { kind: 'writer', row: { state: 'idle', level: 'fine', alarms: [] } },
    { kind: 'writer', row: { state: 'idle', level: 'warn', alarms: ['W9'] } },
  ])('rejects a row writer this build does not know: %j', async writer => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.keepers[0]!, { writer })
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('decodes the exact current-snapshot health contract', async () => {
    getMock.mockResolvedValue(keeperMemoryHealthPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.schema).toBe('keeper.memory_os.current_health.v19')
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

  it('rejects retired Memory health fields', async () => {
    for (const mutate of [
      (payload: Record<string, unknown>) => {
        Object.assign((payload.keepers as Record<string, unknown>[])[0]!, { facts_bytes: 512 })
      },
      (payload: Record<string, unknown>) => {
        Object.assign((payload.keepers as Record<string, unknown>[])[0]!, { librarian: {} })
      },
      (payload: Record<string, unknown>) => {
        Object.assign((payload.keepers as Record<string, unknown>[])[0]!, { context_cycle: {} })
      },
      (payload: Record<string, unknown>) => {
        payload.execution = { status: 'ok' }
      },
    ]) {
      const payload = keeperMemoryHealthPayload() as unknown as Record<string, unknown>
      mutate(payload)
      getMock.mockResolvedValue(payload)

      await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
        '유효하지 않은 keeper memory health payload',
      )
    }
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
    payload.keepers[1]!.alerts[0]!.target = 'librarian_failures'
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
