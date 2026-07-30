import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchKeeperMemoryHealth } from './dashboard-misc'

function keeperMemoryHealthPayload() {
  return {
    generated_at: 1_700_000_000,
    cadence_counter_entries: 2,
    read_error_count: 1,
    read_errors: [{ keeper_id: 'broken', error: 'invalid fact JSON shape' }],
    keepers: [{
      keeper_id: 'healthy',
      facts: 4,
      facts_bytes: 512,
      events: 2,
      events_bytes: 256,
      events_bytes_to_facts_bytes_ratio: 0.5,
      ttl_expired_on_disk: 0,
      duplicate_claim_identity_rows: 1,
      alerts: [{
        code: 'duplicate_claim_identity_rows',
        severity: 'warn',
        target: 'duplicate_claim_identity_rows',
        label: '동일 claim identity 행',
        message: 'A duplicate claim identity row remains on disk.',
        value: 1,
        threshold: 0,
      }],
    }],
    totals: {
      facts: 4,
      facts_bytes: 512,
      events_bytes: 256,
      ttl_expired_on_disk: 0,
      duplicate_claim_identity_rows: 1,
    },
    alert_summary: {
      total_alerts: 1,
      warn_alerts: 1,
      keepers_with_alerts: 1,
      ttl_expired_keepers: 0,
      duplicate_claim_identity_rows_keepers: 1,
      thresholds: {
        ttl_expired_on_disk: 0,
        duplicate_claim_identity_rows: 0,
      },
    },
  }
}

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperMemoryHealth', () => {
  it('decodes the exact backend health and read-error contract', async () => {
    getMock.mockResolvedValue(keeperMemoryHealthPayload())

    const response = await fetchKeeperMemoryHealth()

    expect(response.read_errors).toEqual([
      { keeper_id: 'broken', error: 'invalid fact JSON shape' },
    ])
    expect(response.keepers[0]?.events_bytes_to_facts_bytes_ratio).toBe(0.5)
    expect(response.totals.duplicate_claim_identity_rows).toBe(1)
    expect(response.keepers[0]?.alerts[0]?.code).toBe('duplicate_claim_identity_rows')
    expect(response.alert_summary.duplicate_claim_identity_rows_keepers).toBe(1)
  })

  it('rejects the removed execution-slot wire instead of accepting dead telemetry', async () => {
    const payload = keeperMemoryHealthPayload()
    const keeper = payload.keepers[0] as Record<string, unknown>
    keeper.execution_slot_busy = 3
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a read-error count that disagrees with the exact error list', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.read_error_count = 0
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a malformed read-error row instead of filtering it out', async () => {
    const payload = keeperMemoryHealthPayload()
    Object.assign(payload.read_errors[0]!, { error: '' })
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects an alert whose target disagrees with its typed code', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.alerts[0]!.target = 'ttl_expired_on_disk'
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects totals that disagree with the exact keeper rows', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.totals.facts = 5
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects alert summaries that disagree with the actual alerts', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.alert_summary.duplicate_claim_identity_rows_keepers = 0
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a derived events-bytes/facts-bytes ratio that disagrees with its source fields', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers[0]!.events_bytes_to_facts_bytes_ratio = 0.75
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects the retired imprecise ratio wire name', async () => {
    const payload = keeperMemoryHealthPayload()
    const keeper = payload.keepers[0] as Record<string, unknown>
    keeper.events_to_facts_ratio = keeper.events_bytes_to_facts_bytes_ratio
    delete keeper.events_bytes_to_facts_bytes_ratio
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects the retired near-duplicate wire name', async () => {
    const payload = keeperMemoryHealthPayload()
    const keeper = payload.keepers[0] as Record<string, unknown>
    keeper.near_duplicate = keeper.duplicate_claim_identity_rows
    delete keeper.duplicate_claim_identity_rows
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects duplicate keeper names within successful keeper rows', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.keepers.push({
      keeper_id: 'healthy',
      facts: 0,
      facts_bytes: 0,
      events: 0,
      events_bytes: 0,
      events_bytes_to_facts_bytes_ratio: 0,
      ttl_expired_on_disk: 0,
      duplicate_claim_identity_rows: 0,
      alerts: [],
    })
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects duplicate keeper names within read errors', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.read_errors.push({
      keeper_id: 'broken',
      error: 'second invalid fact JSON shape',
    })
    payload.read_error_count = 2
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })

  it('rejects a keeper name present in both successful rows and read errors', async () => {
    const payload = keeperMemoryHealthPayload()
    payload.read_errors[0]!.keeper_id = 'healthy'
    getMock.mockResolvedValue(payload)

    await expect(fetchKeeperMemoryHealth()).rejects.toThrow(
      '유효하지 않은 keeper memory health payload',
    )
  })
})
