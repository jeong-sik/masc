import type { RuntimeQuotaRest, RuntimeResolution, SetupAccountEmail } from './types'

export type QuotaRestSortKey = 'release' | 'count' | 'name'
export type QuotaRestCauseFilter = 'all' | RuntimeQuotaRest['cause']

export interface QuotaRestCauseMeta {
  readonly label: string
  readonly shortLabel: string
  readonly tone: 'warn' | 'bad'
}

export interface ReleaseSummary {
  readonly countdown: string
  readonly localTime: string | null
  readonly isSoon: boolean
  readonly isEstimated: boolean
}

export type RestingRuntime = RuntimeResolution & {
  readonly quota_rest: RuntimeQuotaRest
}

export interface PausedRuntimeGroup {
  readonly provider: string
  readonly displayName: string
  readonly accountLineText: string | null
  readonly totalInProvider: number
  readonly restingCount: number
  readonly runtimes: readonly RestingRuntime[]
  readonly causes: readonly string[]
  readonly primaryCause: string
  readonly soonestUntil: number | null
  readonly soonestResetStated: boolean
  readonly hasEstimatedReset: boolean
}

export interface PausedRuntimesSummary {
  readonly totalRegistered: number
  readonly restingCount: number
  readonly availableCount: number
  readonly groupCount: number
  readonly soonestUntil: number | null
  readonly soonestResetStated: boolean
  readonly causeCounts: Readonly<Record<string, number>>
  readonly hasPaymentRefused: boolean
}

export interface GroupedRestingRuntimes {
  readonly summary: PausedRuntimesSummary
  readonly groups: readonly PausedRuntimeGroup[]
}

export interface GroupRestingRuntimesOptions {
  readonly providerDisplayNames?: ReadonlyMap<string, string> | Readonly<Record<string, string>>
  readonly accountEmails?: ReadonlyMap<string, SetupAccountEmail | string> | Readonly<Record<string, SetupAccountEmail | string>>
  readonly sortBy: QuotaRestSortKey
  readonly causeFilter: QuotaRestCauseFilter
  readonly nowUnix?: number
}

const CAUSE_ORDER: readonly string[] = [
  'payment_refused',
  'provider_quota_refused',
  'usage_read',
]

function causeRank(cause: string): number {
  const idx = CAUSE_ORDER.indexOf(cause)
  return idx === -1 ? CAUSE_ORDER.length : idx
}

export function quotaRestCauseMeta(cause: string): QuotaRestCauseMeta {
  const trimmed = cause.trim()
  switch (trimmed) {
    case 'provider_quota_refused':
      return { label: '한도 초과', shortLabel: '한도 초과', tone: 'warn' }
    case 'payment_refused':
      return { label: '결제·크레딧 거절', shortLabel: '결제 거절', tone: 'bad' }
    case 'usage_read':
      return { label: '사용량 100% 도달', shortLabel: '사용량 100%', tone: 'warn' }
    default: {
      const text = trimmed.length > 0 ? `일시 중지 (${trimmed})` : '일시 중지'
      return { label: text, shortLabel: text, tone: 'warn' }
    }
  }
}

function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

function isValidUnix(val: number | null | undefined): val is number {
  return typeof val === 'number' && Number.isFinite(val) && val > 0
}

export function formatLocalReleaseTime(
  untilUnix: number | null | undefined,
  nowUnix: number = Date.now() / 1000,
): string | null {
  if (!isValidUnix(untilUnix)) return null
  const effectiveNow = isValidUnix(nowUnix) ? nowUnix : Date.now() / 1000
  const target = new Date(untilUnix * 1000)
  const now = new Date(effectiveNow * 1000)
  const hhmm = `${pad2(target.getHours())}:${pad2(target.getMinutes())}`

  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const startOfTarget = new Date(target.getFullYear(), target.getMonth(), target.getDate())
  const dayDiff = Math.round((startOfTarget.getTime() - startOfToday.getTime()) / 86_400_000)

  if (dayDiff === 0) return `오늘 ${hhmm}`
  if (dayDiff === 1) return `내일 ${hhmm}`
  return `${pad2(target.getMonth() + 1)}/${pad2(target.getDate())} ${hhmm}`
}

export function formatReleaseSummary(
  untilUnix: number | null | undefined,
  resetStated: boolean,
  nowUnix: number = Date.now() / 1000,
): ReleaseSummary {
  const isEstimated = !resetStated
  if (!isValidUnix(untilUnix)) {
    return { countdown: '미정', localTime: null, isSoon: false, isEstimated }
  }
  const effectiveNow = isValidUnix(nowUnix) ? nowUnix : Date.now() / 1000
  const rem = untilUnix - effectiveNow
  const localTime = formatLocalReleaseTime(untilUnix, effectiveNow)

  if (rem <= 0) {
    return { countdown: '해제됨', localTime, isSoon: false, isEstimated }
  }

  const isSoon = rem > 0 && rem <= 1800
  let countdown: string
  if (rem < 60) {
    countdown = `${Math.max(1, Math.round(rem))}초 후`
  } else if (rem < 3600) {
    countdown = `${Math.max(1, Math.floor(rem / 60))}분 후`
  } else if (rem < 86_400) {
    const hours = Math.floor(rem / 3600)
    const mins = Math.floor((rem % 3600) / 60)
    countdown = mins > 0 ? `${hours}시간 ${mins}분 후` : `${hours}시간 후`
  } else {
    const days = Math.floor(rem / 86_400)
    const hours = Math.floor((rem % 86_400) / 3600)
    countdown = hours > 0 ? `${days}일 ${hours}시간 후` : `${days}일 후`
  }

  return { countdown, localTime, isSoon, isEstimated }
}

const PREFIX_SEPARATORS = new Set([':', '/', '.', '-', '_'])

export function stripProviderPrefix(runtimeId: string, providerId: string): string {
  if (!providerId || !runtimeId.startsWith(providerId)) return runtimeId
  const rest = runtimeId.slice(providerId.length)
  if (rest.length > 1 && PREFIX_SEPARATORS.has(rest[0]!)) {
    return rest.slice(1)
  }
  return runtimeId
}

function lookupRecordOrMap<V>(
  source: ReadonlyMap<string, V> | Readonly<Record<string, V>> | undefined,
  key: string,
): V | undefined {
  if (!source) return undefined
  if (source instanceof Map) return source.get(key)
  return (source as Readonly<Record<string, V>>)[key]
}

function formatAccountEmailEntry(entry: SetupAccountEmail | string | undefined): string | null {
  if (entry === undefined) return null
  if (typeof entry === 'string') {
    const trimmed = entry.trim()
    return trimmed.length > 0 ? trimmed : null
  }
  if (entry.state === 'not_read') return `계정 미확인 (${entry.cause})`
  return [entry.email, ...(entry.plan ?? [])].join(' · ')
}

function compareOptionalUntil(a: number | null, b: number | null): number {
  const aValid = isValidUnix(a)
  const bValid = isValidUnix(b)
  if (aValid && bValid) return a - b
  if (aValid) return -1
  if (bValid) return 1
  return 0
}

function compareRestingRuntime(a: RestingRuntime, b: RestingRuntime): number {
  const aUntil = isValidUnix(a.quota_rest.until) ? a.quota_rest.until : null
  const bUntil = isValidUnix(b.quota_rest.until) ? b.quota_rest.until : null
  return compareOptionalUntil(aUntil, bUntil) || a.id.localeCompare(b.id)
}

function findSoonest(runtimes: readonly RestingRuntime[]): { until: number | null; resetStated: boolean } {
  let soonestUntil: number | null = null
  let soonestResetStated = false
  for (const rt of runtimes) {
    const u = rt.quota_rest.until
    if (!isValidUnix(u)) continue
    if (soonestUntil === null || u < soonestUntil) {
      soonestUntil = u
      soonestResetStated = rt.quota_rest.reset_stated
    } else if (u === soonestUntil && rt.quota_rest.reset_stated) {
      soonestResetStated = true
    }
  }
  return { until: soonestUntil, resetStated: soonestResetStated }
}

function isRestingRuntime(rt: RuntimeResolution): rt is RestingRuntime {
  return rt.quota_rest !== null
}

export function groupRestingRuntimes(
  allRuntimes: readonly RuntimeResolution[],
  opts: GroupRestingRuntimesOptions,
): GroupedRestingRuntimes {
  const totalRegistered = allRuntimes.length
  const providerTotals = new Map<string, number>()
  const restingByProvider = new Map<string, RestingRuntime[]>()
  const allResting: RestingRuntime[] = []
  const causeCounts: Record<string, number> = {}

  for (const rt of allRuntimes) {
    providerTotals.set(rt.provider, (providerTotals.get(rt.provider) ?? 0) + 1)
    if (!isRestingRuntime(rt)) continue
    allResting.push(rt)
    const cause = rt.quota_rest.cause
    causeCounts[cause] = (causeCounts[cause] ?? 0) + 1
    const list = restingByProvider.get(rt.provider)
    if (list) list.push(rt)
    else restingByProvider.set(rt.provider, [rt])
  }

  const restingCount = allResting.length
  const availableCount = Math.max(0, totalRegistered - restingCount)
  const groupCount = restingByProvider.size
  const globalSoonest = findSoonest(allResting)
  const hasPaymentRefused = (causeCounts['payment_refused'] ?? 0) > 0

  const groups: PausedRuntimeGroup[] = []
  for (const [provider, rawList] of restingByProvider.entries()) {
    const filtered = opts.causeFilter === 'all'
      ? rawList
      : rawList.filter((rt) => rt.quota_rest.cause === opts.causeFilter)
    if (filtered.length === 0) continue

    const sortedRuntimes = [...filtered].sort(compareRestingRuntime)
    const causeSet = new Set<string>()
    for (const rt of sortedRuntimes) causeSet.add(rt.quota_rest.cause)
    const causes = [...causeSet].sort((a, b) => (causeRank(a) - causeRank(b)) || a.localeCompare(b))
    const primaryCause = causes[0]!
    const soonest = findSoonest(sortedRuntimes)
    const hasEstimatedReset = sortedRuntimes.some((rt) => !rt.quota_rest.reset_stated)
    const rawDisplay = lookupRecordOrMap(opts.providerDisplayNames, provider)
    const displayName = rawDisplay && rawDisplay.trim().length > 0 ? rawDisplay.trim() : provider
    const accountLineText = formatAccountEmailEntry(lookupRecordOrMap(opts.accountEmails, provider))

    groups.push({
      provider,
      displayName,
      accountLineText,
      totalInProvider: providerTotals.get(provider) ?? sortedRuntimes.length,
      restingCount: sortedRuntimes.length,
      runtimes: sortedRuntimes,
      causes,
      primaryCause,
      soonestUntil: soonest.until,
      soonestResetStated: soonest.resetStated,
      hasEstimatedReset,
    })
  }

  groups.sort((a, b) => {
    switch (opts.sortBy) {
      case 'count':
        return (b.restingCount - a.restingCount)
          || compareOptionalUntil(a.soonestUntil, b.soonestUntil)
          || a.provider.localeCompare(b.provider)
      case 'name':
        return a.displayName.localeCompare(b.displayName)
          || a.provider.localeCompare(b.provider)
      case 'release':
      default:
        return compareOptionalUntil(a.soonestUntil, b.soonestUntil)
          || (b.restingCount - a.restingCount)
          || a.provider.localeCompare(b.provider)
    }
  })

  return {
    summary: {
      totalRegistered,
      restingCount,
      availableCount,
      groupCount,
      soonestUntil: globalSoonest.until,
      soonestResetStated: globalSoonest.resetStated,
      causeCounts,
      hasPaymentRefused,
    },
    groups,
  }
}
