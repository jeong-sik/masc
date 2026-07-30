import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchKeeperMemoryHealth } from './dashboard-misc'

function keeperMemoryHealthPayload() {
  return {
    schema: 'keeper.memory_os.current_health.v1',
    generated_at: 1_700_000_000,
    cadence_counter_entries: 2,
    keepers: [{
      keeper_id: 'healthy',
      revision: 7,
      facts: 4,
      snapshot_bytes: 512,
      added: 1,
      removed: 2,
      librarian_lane_busy: 0,
      read_error: null,
      alerts: [],
    }, {
      keeper_id: 'broken',
      revision: 0,
      facts: 0,
      snapshot_bytes: 32,
      added: 0,
      removed: 0,
      librarian_lane_busy: 0,
      read_error: 'invalid current snapshot',
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
      librarian_lane_busy: 0,
      read_errors: 1,
    },
    alert_summary: {
      total_alerts: 1,
      warn_alerts: 1,
      keepers_with_alerts: 1,
      snapshot_read_error_keepers: 1,
      librarian_lane_busy_keepers: 0,
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

    expect(response.schema).toBe('keeper.memory_os.current_health.v1')
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
})
