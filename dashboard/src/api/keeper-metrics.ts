import { isRecord } from '../components/common/normalize'
import { normalizeMetricsSeries } from '../keeper-store-normalize'
import type { KeeperMetricPoint } from '../types'
import { get, type AbortableRequestOptions } from './core'

export interface KeeperMetricsWindow {
  readonly keeper: string
  readonly series: KeeperMetricPoint[]
  readonly scannedRows: number
  readonly skippedRows: number
  readonly limit: number
}

/** Reject cross-Keeper or incomplete replies rather than painting an empty chart. */
export function parseKeeperMetrics(raw: unknown, keeper: string): KeeperMetricsWindow {
  if (!isRecord(raw) || raw.keeper !== keeper || !Array.isArray(raw.series)) {
    throw new Error('Invalid selected Keeper metrics response')
  }
  const count = (key: string): number => {
    const value = raw[key]
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
      throw new Error(`Invalid Keeper metrics ${key}`)
    }
    return value
  }
  const scannedRows = count('scanned_rows'), skippedRows = count('skipped_rows'), limit = count('limit')
  const series = normalizeMetricsSeries(raw.series)
  if (limit === 0 || series.length !== raw.series.length || skippedRows > scannedRows || scannedRows > limit
    || series.length + skippedRows > scannedRows) {
    throw new Error('Inconsistent Keeper metrics coverage')
  }
  return { keeper, series, scannedRows, skippedRows, limit }
}

export async function fetchKeeperMetrics(keeper: string, options: AbortableRequestOptions = {}): Promise<KeeperMetricsWindow> {
  const raw = await get<unknown>(`/api/v1/keepers/${encodeURIComponent(keeper)}/metrics`, options)
  return parseKeeperMetrics(raw, keeper)
}
