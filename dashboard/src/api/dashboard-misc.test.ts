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
    schema: 'keeper.memory_os.current_health.v2',
    generated_at: 1_700_000_000,
    cadence_counter_entries: 2,
    keepers: [{
      keeper_id: 'healthy',
      revision: 7,
      facts: 4,
      snapshot_bytes: 512,
      added: 1,
      removed: 2,
      snapshot_present: true,
      librarian_lane_busy: 0,
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
      facts: 0,
      snapshot_bytes: 32,
      added: 0,
      removed: 0,
      snapshot_present: false,
      librarian_lane_busy: 0,
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
        value: 1,
        threshold: 0,
      }],
    }],
    totals: {
      facts: 4,
      snapshot_bytes: 544,
      added: 1,
      removed: 2,
      source_facts: 1,
      source_invalidations: 0,
      source_snapshot_bytes: 128,
      librarian_lane_busy: 0,
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
      librarian_lane_busy_keepers: 0,
      librarian_starving_keepers: 0,
    },
  }
}

function starvingKeeperPayload(): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v2',
    generated_at: 1_700_000_000,
    cadence_counter_entries: 1,
    keepers: [{
      keeper_id: 'starving',
      revision: 0,
      facts: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      snapshot_present: false,
      librarian_lane_busy: 0,
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
        value: 4,
        threshold: 0,
      }],
    }],
    totals: {
      facts: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
      librarian_lane_busy: 0,
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
      librarian_lane_busy_keepers: 0,
      librarian_starving_keepers: 1,
    },
  }
}

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperMemoryHealth', () => {
  it('decodes the exact current-snapshot health contract', async () => {
    getMock.mockResolvedValue(keeperMemoryHealthPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.schema).toBe('keeper.memory_os.current_health.v2')
    expect(response.keepers[0]).toMatchObject({
      keeper_id: 'healthy',
      revision: 7,
      facts: 4,
      snapshot_bytes: 512,
    })
    expect(response.keepers[1]?.read_error).toBe('invalid current snapshot')
    expect(response.alert_summary.snapshot_read_error_keepers).toBe(1)
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
    payload.keepers[1]!.alerts[0]!.target = 'librarian_lane_busy'
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
      value: 1,
      threshold: 0,
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
      value: 3,
      threshold: 0,
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
})
