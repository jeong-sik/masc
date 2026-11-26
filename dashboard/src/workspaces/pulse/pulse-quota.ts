/**
 * Pulse quota standing: which provider usage windows refuse calls now.
 * Pure functions; the caller passes `nowSec`.
 */

import type { Observed } from '../../core/resource-cache'
import { formatRelativeUntilSec } from '../../lib/format-time'
import { isUtilizationSpent } from '../../lib/quota-window'
import type {
  PulseProviderUsagePoint,
  PulseProviderUsageSnapshot,
  PulseQuotaSummary,
  PulseQuotaWindowStanding,
} from './types'

/**
 * Whether one window reading still refuses calls at `nowSec`. A spent reading
 * whose `resets_at` has passed has reset; a spent reading without `resets_at`
 * is spent as of its report and its return time is unknown.
 */
export function quotaWindowStanding(point: PulseProviderUsagePoint, nowSec: number): PulseQuotaWindowStanding {
  const spent = isUtilizationSpent(point.utilization)
  if (spent === null) return { kind: 'no_limit' }
  if (!spent) return { kind: 'room_left' }
  if (point.resets_at === null) return { kind: 'spent_reset_unknown', observedAt: point.observed_at }
  return point.resets_at > nowSec
    ? { kind: 'exhausted', resetsAt: point.resets_at }
    : { kind: 'reset_since_report', resetsAt: point.resets_at }
}

function quotaWindowKey(point: PulseProviderUsagePoint): string {
  return JSON.stringify([point.scope_id, point.kind, point.limit_id])
}

/**
 * The history holds one reading per window per UTC day, so a window spent on
 * an earlier day appears beside today's reading. Only each window's latest
 * reading speaks for now, and a later report of the same scope that stated no
 * window at all means the provider no longer states it.
 */
export function latestQuotaReadings(
  snapshot: Extract<PulseProviderUsageSnapshot, { state: 'available' }>,
): readonly PulseProviderUsagePoint[] {
  const latest = new Map<string, PulseProviderUsagePoint>()
  for (const pt of snapshot.points) {
    const key = quotaWindowKey(pt)
    const held = latest.get(key)
    if (!held || pt.observed_at > held.observed_at) latest.set(key, pt)
  }
  const emptySince = new Map<string, number>()
  for (const row of snapshot.reported_no_windows) {
    const held = emptySince.get(row.scope_id)
    if (held === undefined || row.observed_at > held) emptySince.set(row.scope_id, row.observed_at)
  }
  return [...latest.values()].filter((pt) => {
    const empty = emptySince.get(pt.scope_id)
    return empty === undefined || empty <= pt.observed_at
  })
}

export function summarizeQuotaWindows(
  usage: Observed<PulseProviderUsageSnapshot>,
  nowSec: number,
): PulseQuotaSummary {
  let exhausted = 0
  let nextReturnAt: number | null = null
  let spentResetUnknown = 0
  let subscription = 0
  if (usage.kind === 'value' && usage.data.state === 'available') {
    for (const pt of latestQuotaReadings(usage.data)) {
      const standing = quotaWindowStanding(pt, nowSec)
      const unit = pt.utilization.unit
      switch (standing.kind) {
        case 'exhausted':
          exhausted += 1
          nextReturnAt = nextReturnAt === null ? standing.resetsAt : Math.min(nextReturnAt, standing.resetsAt)
          break
        case 'spent_reset_unknown':
          spentResetUnknown += 1
          break
        case 'room_left':
        case 'reset_since_report':
          if (unit === 'fraction' || unit === 'percent' || unit === 'credit_unlimited') subscription += 1
          break
        case 'no_limit':
          break
      }
    }
  }
  return { exhausted, nextReturnAt, spentResetUnknown, subscription }
}

/** "한도 소진 2 · 3시간 후 복귀 · 소진(복귀 시각 미확인) 1" — empty when no window is spent. */
export function formatQuotaSpentNote(quota: PulseQuotaSummary, nowSec: number): string {
  const parts: string[] = []
  if (quota.exhausted > 0) {
    parts.push(`한도 소진 ${quota.exhausted}`)
    if (quota.nextReturnAt !== null) parts.push(`${formatRelativeUntilSec(quota.nextReturnAt - nowSec)} 복귀`)
  }
  if (quota.spentResetUnknown > 0) parts.push(`소진(복귀 시각 미확인) ${quota.spentResetUnknown}`)
  return parts.join(' · ')
}
