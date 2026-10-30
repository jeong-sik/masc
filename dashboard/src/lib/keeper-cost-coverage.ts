/** Lifetime reported sum and its captured pricing evidence. */
export interface KeeperCostCoverage {
  known_cost_usd: number
  priced_readings: number
  unpriced_readings: number
  unresolved_readings: number
  unobserved_attempts: number
  history: 'complete' | 'unobserved'
}

const fields = ['known_cost_usd', 'priced_readings', 'unpriced_readings',
  'unresolved_readings', 'unobserved_attempts', 'history'] as const

const amount = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0
const count = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0

export function readKeeperCostCoverage(raw: unknown): KeeperCostCoverage | null {
  if (amount(raw)) {
    return { known_cost_usd: raw, priced_readings: 0, unpriced_readings: 0,
      unresolved_readings: 0, unobserved_attempts: 0, history: 'unobserved' }
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const row = raw as Record<string, unknown>
  const keys = Object.keys(row)
  if (keys.length !== fields.length || !fields.every(field => keys.includes(field))) return null
  if (!amount(row.known_cost_usd) || !count(row.priced_readings)
    || !count(row.unpriced_readings) || !count(row.unresolved_readings)
    || !count(row.unobserved_attempts)
    || (row.history !== 'complete' && row.history !== 'unobserved')) return null
  if (row.history === 'complete' && row.priced_readings === 0 && row.known_cost_usd !== 0) return null
  return { known_cost_usd: row.known_cost_usd, priced_readings: row.priced_readings,
    unpriced_readings: row.unpriced_readings, unresolved_readings: row.unresolved_readings,
    unobserved_attempts: row.unobserved_attempts, history: row.history }
}

export function keeperCostSummary(cost: KeeperCostCoverage | null | undefined): string {
  if (cost == null) return 'cost not observed'
  const known = `$${cost.known_cost_usd.toFixed(4)}`
  if (cost.history === 'unobserved' || cost.unresolved_readings > 0 || cost.unobserved_attempts > 0) {
    const history = cost.history === 'unobserved' ? 'history unobserved · ' : ''
    return `${history}${known} known · ${cost.priced_readings} priced / ${cost.unpriced_readings} unpriced / ${cost.unresolved_readings} unresolved readings · ${cost.unobserved_attempts} unobserved attempts`
  }
  if (cost.priced_readings === 0) {
    return cost.unpriced_readings === 0 ? 'no cost observations'
      : `not priced by provider (${cost.unpriced_readings} readings)`
  }
  return cost.unpriced_readings === 0 ? known
    : `${known} known · ${cost.priced_readings} priced / ${cost.unpriced_readings} unpriced readings`
}
