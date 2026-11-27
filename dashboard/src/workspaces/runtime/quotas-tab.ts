/**
 * Runtime L1 Tab 1: Quotas & Rate Limits
 *
 * - 3-Group Quota View (Attention / Active Subscriptions / Unreported) with
 *   filter, sort, search, 24h call stats (/api/v1/runtime/metrics), window
 *   burn / cutoff elapsed analysis, and inspect drawer detail view.
 * - UPlotChart Provider Usage History & 429 Cooldown Band:
 *   GET /api/v1/dashboard/provider-usage-history?days=<timeWindowProviderDays> (strictly 1|7|14)
 *   explicitly handling HTTP 200 { state: "unavailable", reason } per #36.
 * - Mode-aware Provider Credential & OAuth CRUD (/api/v1/setup/inventory vs /api/v1/auth/provider-accounts),
 *   API key upsert (/api/v1/setup/credential or /api/v1/setup/accounts/key), CLI OAuth login receipt flow
 *   (/api/v1/setup/accounts/login), verify & remove, plus 1-click Re-auth & Open Config Key remediation.
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import {
  apiGet,
  apiMutate,
  authSession,
  cancelSetupLogin,
  currentSessionEpoch,
  extractObserverTopics,
  formatObserved,
  isEpochCurrent,
  markViewSynced,
  resourceCache,
  sendSetupLoginInput,
  sessionEpoch,
  streamSetupAccountLogin,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
  timeWindow,
  timeWindowProviderDays,
  type Observed,
} from '../../core'
import { copyToClipboard } from '../../components/common/copyable-code'
import { isUtilizationSpent } from '../../lib/quota-window'
import { isAdminLockedForSession } from '../../routes/router'
import { pushShellToast } from '../../shell/shell-state'
import {
  PopoverMenu,
  RefreshButton,
  UPlotChart,
  type PopoverMenuItem,
  type UPlotSeriesSpec,
} from '../../components/primitives'
import {
  causeBadgeStyle,
  formatAccountEmailEntry,
  formatReleaseSummary,
  groupRestingRuntimes,
  quotaRestCauseMeta,
  restClockDelayMs,
  someRestIsOver,
  soonestReleaseWords,
  stripProviderPrefix,
  type QuotaRestCauseFilter,
  type QuotaRestSortKey,
} from './quota-rest-groups'
import { RuntimeLivenessPanel } from './runtime-liveness-panel'
import { loadSetupInventory, SETUP_INVENTORY_KEY } from './setup-inventory-read'
import {
  countQuotaFilters,
  decodeRuntimeMetrics24h,
  enrichQuotaScopes,
  filterAndSortQuotaScopes,
  formatDurationKo,
  utilizationToPct,
  type EnrichedQuotaScope,
  type QuotaScopeFilter,
  type QuotaScopeSort,
  type RuntimeMetrics24hSnapshot,
} from './quota-scope-view'
import {
  decodeMultiAccountIntegrations,
  decodeMultiAccountProviderAccounts,
  formatCompactNumber,
  formatResetCountdown,
  formatUnixTime,
  loadProviderUsageHistory,
  loadRuntimeResolved,
  quotaRestOfScope,
  resolveRuntimeMediaCapabilities,
  restingProviderIds,
  windowKindLabel,
  type MultiAccountIntegration,
  type MultiAccountIntegrationsResponse,
  type MultiAccountProviderAccount,
  type MultiAccountProviderAccountsResponse,
  type ProviderUsageHistoryPoint,
  type ProviderUsageHistoryResponse,
  type RuntimeQuotaRest,
  type RuntimeResolvedPayload,
  type SetupAccountEmail,
  type SetupIntegration,
  type SetupInventoryPayload,
  type WorkspaceViewProps,
} from './types'

const HISTORY_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '평균 사용률 (%)', colorToken: '--info-fg', width: 2, fillAlpha: 0.14, unit: '%' },
  { label: '최대 피크 사용률 (%)', colorToken: '--warn-fg', width: 1.75, unit: '%' },
  { label: '일시 중지·소진 수', colorToken: '--err-fg', width: 1.75, dash: [4, 3] },
]

export function buildUsageHistoryChartData(
  points: readonly ProviderUsageHistoryPoint[],
): uPlot.AlignedData {
  if (points.length === 0) return [[], [], [], []]

  const byBucket = new Map<number, { sumPct: number; count: number; maxPct: number; cooldownCount: number }>()
  for (const pt of points) {
    // Bucket to hour boundaries so uPlot receives strictly increasing timestamps
    const ts = Math.floor(pt.observed_at / 3600) * 3600
    let pct: number | null = null

    const u = pt.utilization
    const exhausted = isUtilizationSpent(u) === true
    switch (u.unit) {
      case 'fraction':
        pct = Math.min(100, Math.max(0, u.value * 100))
        break
      case 'percent':
        pct = Math.min(100, Math.max(0, u.value))
        break
      case 'usd':
        if (u.limit !== null && u.limit > 0) {
          pct = Math.min(100, Math.max(0, (u.value / u.limit) * 100))
        }
        break
      case 'credit_balance':
        if (u.total !== null && u.total > 0) {
          pct = Math.min(100, Math.max(0, ((u.total - u.remaining) / u.total) * 100))
        }
        break
      case 'credit_unlimited':
        break
    }

    const cur = byBucket.get(ts) ?? { sumPct: 0, count: 0, maxPct: 0, cooldownCount: 0 }
    if (pct !== null) {
      cur.sumPct += pct
      cur.count += 1
      if (pct > cur.maxPct) cur.maxPct = pct
    }
    if (exhausted) cur.cooldownCount += 1
    byBucket.set(ts, cur)
  }

  const timestamps = [...byBucket.keys()].sort((a, b) => a - b)
  const avgSeries: (number | null)[] = []
  const maxSeries: (number | null)[] = []
  const cooldownSeries: number[] = []

  for (const ts of timestamps) {
    const b = byBucket.get(ts)!
    avgSeries.push(b.count > 0 ? Number((b.sumPct / b.count).toFixed(1)) : null)
    maxSeries.push(b.count > 0 ? Number(b.maxPct.toFixed(1)) : null)
    cooldownSeries.push(b.cooldownCount)
  }

  return [timestamps, avgSeries, maxSeries, cooldownSeries]
}

interface LoginReceiptState {
  readonly loginId: string
  readonly integrationId: string
  readonly status: string
  readonly accountRef?: string | null
  readonly authentication?: string | null
  readonly message?: string
  readonly authUrl?: string | null
  readonly deviceCode?: string | null
  readonly inputReady?: boolean
  readonly outputTail?: string
  readonly streaming?: boolean
  readonly popupBlocked?: boolean
}

interface CredentialFormState {
  readonly providerId: string
  readonly secret: string
  readonly mode: 'api_key' | 'oauth'
}

/** The account line under a provider: its login email and the plan labels
 *  the client reports, or why the login file was not read. */
export function accountLine(row: SetupAccountEmail | undefined): string | null {
  return formatAccountEmailEntry(row)
}

function costBadgeStyle(kind: EnrichedQuotaScope['classification']['kind']) {
  switch (kind) {
    case 'exhausted_zero':
      return { background: 'var(--err-soft)', border: '1px solid var(--err-border)', color: 'var(--err-fg)' }
    case 'subscription_zero':
      return { background: 'var(--ok-soft)', border: '1px solid var(--ok-border)', color: 'var(--ok-fg)' }
    case 'amount':
      return { background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)' }
    case 'unreported':
      return { background: 'var(--idle-soft)', border: '1px solid var(--idle-border)', color: 'var(--fg-3)' }
  }
}

const QUOTA_SORT_OPTIONS: readonly { readonly value: QuotaScopeSort; readonly label: string }[] = [
  { value: 'default', label: '상태 그룹순 (기본)' },
  { value: 'util_desc', label: '사용률 높은순' },
  { value: 'util_asc', label: '여유 많은순 (사용률 낮은순)' },
  { value: 'reset_soon', label: '리셋 임박순' },
  { value: 'calls_desc', label: '24시간 호출 많은순' },
  { value: 'name', label: '이름순' },
]

function historyPointValueLabel(pt: ProviderUsageHistoryPoint): string {
  const u = pt.utilization
  switch (u.unit) {
    case 'fraction':
      return `${Math.min(100, Math.max(0, u.value * 100)).toFixed(1)}%`
    case 'percent':
      return `${Math.min(100, Math.max(0, u.value)).toFixed(0)}%`
    case 'usd':
      return u.limit !== null ? `$${u.value.toFixed(2)} / $${u.limit.toFixed(2)}` : `$${u.value.toFixed(2)}`
    case 'credit_balance':
      return `${u.remaining.toFixed(2)} ${u.currency}`
    case 'credit_unlimited':
      return '무제한 구독'
  }
}

const KNOWN_CAUSE_FILTERS: readonly RuntimeQuotaRest['cause'][] = [
  'payment_refused',
  'provider_quota_refused',
  'usage_read',
]

export function QuotasTab(props: WorkspaceViewProps) {
  const win = timeWindow.value
  const providerDays = timeWindowProviderDays(win)
  const session = authSession.value
  const epoch = sessionEpoch.value
  const isMultiAccountSignedIn = session.kind === 'multi_account_signed_in'
  const isSingleUserLocal = session.kind === 'single_user_local'
  const adminLocked = isAdminLockedForSession('admin', session)
  const canManageProviders = isMultiAccountSignedIn || (isSingleUserLocal && !adminLocked)

  const resolvedObs = resourceCache.observe<RuntimeResolvedPayload>('runtime:resolved').value
  const historyKey = `runtime:provider-usage-history:${providerDays}`
  const historyObs = resourceCache.observe<ProviderUsageHistoryResponse>(historyKey).value
  const runtimeMetricsObs = resourceCache.observe<RuntimeMetrics24hSnapshot>('runtime:metrics:24h').value
  const inventoryKey = isMultiAccountSignedIn ? 'runtime:auth-provider-accounts' : SETUP_INVENTORY_KEY
  const inventoryObs = resourceCache.observe<SetupInventoryPayload | MultiAccountProviderAccountsResponse>(inventoryKey).value
  const personIntegObs = resourceCache.observe<MultiAccountIntegrationsResponse>('runtime:auth-integrations').value

  const [tier3Expanded, setTier3Expanded] = useState(false)
  const [scopeFilter, setScopeFilter] = useState<QuotaScopeFilter>('all')
  const [scopeSort, setScopeSort] = useState<QuotaScopeSort>('default')
  const [scopeQuery, setScopeQuery] = useState('')
  const [pausedPanelPref, setPausedPanelPref] = useState<boolean | null>(null)
  const [inventoryOpen, setInventoryOpen] = useState(false)
  const [pausedSortBy, setPausedSortBy] = useState<QuotaRestSortKey>('release')
  const [pausedCauseFilter, setPausedCauseFilter] = useState<QuotaRestCauseFilter>('all')
  const [expandedGroups, setExpandedGroups] = useState<ReadonlySet<string>>(() => new Set())
  const [nowUnix, setNowUnix] = useState(() => Date.now() / 1000)
  const [credForm, setCredForm] = useState<CredentialFormState | null>(null)
  const [verifyModelInput, setVerifyModelInput] = useState<string>('')
  const [loginReceipt, setLoginReceipt] = useState<LoginReceiptState | null>(null)
  const [actionBusy, setActionBusy] = useState<string | null>(null)
  const [actionBanner, setActionBanner] = useState<{ kind: 'err'; text: string } | null>(null)
  const [sourceRevision, setSourceRevision] = useState<string>('')
  const mountedRef = useRef(true)
  const rawConfigAbortRef = useRef<AbortController | null>(null)

  useEffect(() => {
    mountedRef.current = true
    const timer = window.setInterval(() => {
      setNowUnix(Date.now() / 1000)
    }, 30_000)
    return () => {
      mountedRef.current = false
      window.clearInterval(timer)
      rawConfigAbortRef.current?.abort()
    }
  }, [])

  const loadAll = (reason: 'mount' | 'sse' | 'manual' = 'mount') => {
    const curSession = authSession.peek()
    const multiSignedIn = curSession.kind === 'multi_account_signed_in'
    const singleLocal = curSession.kind === 'single_user_local'
    if (!multiSignedIn && !singleLocal) {
      rawConfigAbortRef.current?.abort()
      return Promise.resolve()
    }
    const startEpoch = currentSessionEpoch()
    const jobs: Promise<unknown>[] = [
      resourceCache.fetch<RuntimeResolvedPayload>(
        'runtime:resolved',
        loadRuntimeResolved,
        { ttlMs: 15_000, topics: ['runtime', 'runtime_resolved', 'provider_usage', 'config'], reason },
      ),
    ]
    if (singleLocal) {
      jobs.push(
        resourceCache.fetch<ProviderUsageHistoryResponse>(
          historyKey,
          (signal) => loadProviderUsageHistory(providerDays, signal),
          { ttlMs: 30_000, topics: ['provider_usage'], reason },
        ),
      )
    }

    if (multiSignedIn) {
      rawConfigAbortRef.current?.abort()
      jobs.push(
        resourceCache.fetch<MultiAccountProviderAccountsResponse>(
          'runtime:auth-provider-accounts',
          (signal) => apiGet<MultiAccountProviderAccountsResponse>('/api/v1/auth/provider-accounts', {
            signal,
            decode: decodeMultiAccountProviderAccounts,
          }),
          { ttlMs: 20_000, topics: ['provider_accounts'], reason },
        ),
        resourceCache.fetch<MultiAccountIntegrationsResponse>(
          'runtime:auth-integrations',
          (signal) => apiGet<MultiAccountIntegrationsResponse>('/api/v1/auth/integrations', {
            signal,
            decode: decodeMultiAccountIntegrations,
          }),
          { ttlMs: 30_000, topics: ['provider_accounts', 'config'], reason },
        ),
      )
    } else if (singleLocal && !isAdminLockedForSession('admin', curSession)) {
      jobs.push(
        loadSetupInventory(reason),
        resourceCache.fetch<RuntimeMetrics24hSnapshot>(
          'runtime:metrics:24h',
          (signal) => apiGet<RuntimeMetrics24hSnapshot>('/api/v1/runtime/metrics', {
            signal,
            decode: decodeRuntimeMetrics24h,
          }),
          { ttlMs: 30_000, topics: ['runtime_metrics', 'model_metrics', 'telemetry'], reason },
        ),
      )
      rawConfigAbortRef.current?.abort()
      const ctrl = new AbortController()
      rawConfigAbortRef.current = ctrl
      void apiGet<{ readonly source_revision?: string }>('/api/v1/runtime/config/raw', { signal: ctrl.signal }).then((res) => {
        if (!mountedRef.current || !isEpochCurrent(startEpoch) || ctrl.signal.aborted) return
        if (res.ok && typeof res.value.source_revision === 'string' && res.value.source_revision.trim().length > 0) {
          setSourceRevision(res.value.source_revision.trim())
        }
      })
    } else {
      rawConfigAbortRef.current?.abort()
    }

    return Promise.all(jobs).then(() => {
      if (mountedRef.current && isEpochCurrent(startEpoch)) markViewSynced()
    })
  }

  useEffect(() => {
    setSourceRevision('')
    setCredForm(null)
    setLoginReceipt(null)
    setActionBanner(null)
  }, [epoch])

  useEffect(() => {
    void loadAll('mount')
  }, [providerDays, session.kind, epoch, adminLocked])

  useEffect(() => {
    const watchedTopics = new Set([
      'runtime',
      'runtime_resolved',
      'runtime_metrics',
      'provider_usage',
      'provider_standing',
      'quota',
      'config',
      'provider_accounts',
      'setup_inventory',
      'dataset_invalidation',
    ])
    let timer: ReturnType<typeof setTimeout> | null = null
    const scheduleRefresh = () => {
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        timer = null
        if (!mountedRef.current || !isEpochCurrent(epoch)) return
        void loadAll('sse')
      }, 450)
    }
    const unsubFrames = subscribeObserverFrames((frame) => {
      if (extractObserverTopics(frame).some((topic) => watchedTopics.has(topic))) {
        scheduleRefresh()
      }
    })
    const recover = () => {
      if (!mountedRef.current || !isEpochCurrent(epoch)) return
      void loadAll('sse')
    }
    const unsubReconnect = subscribeObserverReconnect(recover)
    const unsubResync = subscribeObserverResync(recover)
    return () => {
      if (timer !== null) clearTimeout(timer)
      unsubFrames()
      unsubReconnect()
      unsubResync()
    }
  }, [providerDays, session.kind, epoch, adminLocked])

  const resolvedData = resolvedObs.kind === 'value' ? resolvedObs.data : null
  useEffect(() => {
    if (resolvedData) setNowUnix(Date.now() / 1000)
  }, [resolvedData])

  // The tab's clock ticks every 30 seconds and its countdowns follow it. A
  // rest ends between two ticks, and at its end the server stops reporting
  // it, while the tab reads on mount and on the button only. So while
  // something rests the tab also looks at the clock a second after the next
  // end, and reads again once a rest is over.
  const restEnds = useMemo(
    () => (resolvedData?.runtimes ?? []).flatMap((rt) => (rt.quota_rest !== null ? [rt.quota_rest.until] : [])),
    [resolvedData],
  )
  const [clockLooks, setClockLooks] = useState(0)
  useEffect(() => {
    const delayMs = restClockDelayMs(restEnds, Date.now())
    if (delayMs === null) return undefined
    const timer = window.setTimeout(() => {
      setNowUnix(Date.now() / 1000)
      if (someRestIsOver(restEnds, Date.now())) void loadAll('manual')
      setClockLooks((looks) => looks + 1)
    }, delayMs)
    return () => window.clearTimeout(timer)
  }, [restEnds, clockLooks, providerDays, session.kind, epoch, adminLocked])
  const restingProviders = useMemo(
    () => restingProviderIds(resolvedData?.runtimes ?? [], nowUnix),
    [resolvedData, nowUnix],
  )

  const accountEmails = useMemo(
    () => new Map<string, SetupAccountEmail>(
      inventoryObs.kind === 'value' && 'account_emails' in inventoryObs.data && Array.isArray(inventoryObs.data.account_emails)
        ? inventoryObs.data.account_emails.map((row) => [row.integration_id, row] as const)
        : [],
    ),
    [inventoryObs],
  )

  const metrics24hData: RuntimeMetrics24hSnapshot | null =
    runtimeMetricsObs.kind === 'value' ? runtimeMetricsObs.data : null
  const historyData: ProviderUsageHistoryResponse | null =
    historyObs.kind === 'value' ? historyObs.data : null

  const enrichedScopes = useMemo(
    () => enrichQuotaScopes({
      scopes: resolvedData?.provider_usage_windows ?? [],
      restingProviders,
      accountEmails,
      runtimes: resolvedData?.runtimes ?? [],
      lanes: resolvedData?.lanes ?? [],
      assignments: resolvedData?.assignments ?? [],
      metrics24h: metrics24hData,
      history: historyData,
      nowUnix,
    }),
    [resolvedData, restingProviders, accountEmails, metrics24hData, historyData, nowUnix],
  )

  const filterCounts = useMemo(() => countQuotaFilters(enrichedScopes), [enrichedScopes])

  const groupedScopes = useMemo(() => ({
    attention: enrichedScopes.filter((i) => i.group === 'attention'),
    healthySub: enrichedScopes.filter((i) => i.group === 'healthy_sub'),
    unreported: enrichedScopes.filter((i) => i.group === 'unreported'),
  }), [enrichedScopes])

  const filteredSortedScopes = useMemo(
    () => filterAndSortQuotaScopes(enrichedScopes, {
      filter: scopeFilter,
      sort: scopeSort,
      query: scopeQuery,
    }),
    [enrichedScopes, scopeFilter, scopeSort, scopeQuery],
  )

  const hasActiveScopeControl = scopeFilter !== 'all' || scopeSort !== 'default' || scopeQuery.trim().length > 0

  const integrations: readonly SetupIntegration[] = useMemo(
    () => (inventoryObs.kind === 'value' && 'integrations' in inventoryObs.data && Array.isArray(inventoryObs.data.integrations)
      ? inventoryObs.data.integrations
      : []),
    [inventoryObs],
  )

  const multiAccounts: readonly MultiAccountProviderAccount[] = useMemo(
    () => (inventoryObs.kind === 'value'
      ? ('provider_accounts' in inventoryObs.data && Array.isArray(inventoryObs.data.provider_accounts)
          ? inventoryObs.data.provider_accounts
          : 'accounts' in inventoryObs.data && Array.isArray(inventoryObs.data.accounts)
            ? inventoryObs.data.accounts
            : [])
      : []),
    [inventoryObs],
  )

  const historyState = useMemo(():
    | { kind: 'loading' }
    | { kind: 'failed'; message: string }
    | { kind: 'unavailable'; reason: string }
    | { kind: 'ready'; data: uPlot.AlignedData; pointsCount: number; unreadable: number; undecodable: number; days: number } => {
    if (historyObs.kind === 'loading') return { kind: 'loading' }
    if (historyObs.kind === 'failed') return { kind: 'failed', message: historyObs.error.message }
    if (historyObs.kind !== 'value') return { kind: 'unavailable', reason: '히스토리 데이터 없음' }
    const raw = historyObs.data
    if (raw.state === 'unavailable') {
      return { kind: 'unavailable', reason: raw.reason }
    }
    return {
      kind: 'ready',
      data: buildUsageHistoryChartData(raw.points),
      pointsCount: raw.points.length,
      unreadable: raw.unreadable_reports,
      undecodable: raw.undecodable_points,
      days: raw.days,
    }
  }, [historyObs])

  const personIntegrations: readonly MultiAccountIntegration[] = useMemo(
    () => (personIntegObs.kind === 'value' && Array.isArray(personIntegObs.data.integrations)
      ? personIntegObs.data.integrations
      : []),
    [personIntegObs],
  )

  const providerDisplayNames = useMemo(() => {
    const names = new Map<string, string>()
    for (const acc of multiAccounts) {
      const pid = acc.integration_id ?? acc.provider
      const label = acc.display_name ?? acc.label
      if (pid && label && !names.has(pid)) names.set(pid, label)
    }
    for (const integ of personIntegrations) {
      if (integ.integration_id && integ.display_name) {
        names.set(integ.integration_id, integ.display_name)
      }
    }
    for (const integ of integrations) {
      if (integ.id && integ.display_name) {
        names.set(integ.id, integ.display_name)
      }
    }
    for (const scope of resolvedData?.provider_usage_windows ?? []) {
      for (const p of scope.providers) {
        if (p.id && p.display_name) {
          names.set(p.id, p.display_name)
        }
      }
    }
    return names
  }, [resolvedData, integrations, personIntegrations, multiAccounts])

  const basePausedGrouped = useMemo(
    () => groupRestingRuntimes(resolvedData?.runtimes ?? [], {
      providerDisplayNames,
      accountEmails,
      sortBy: pausedSortBy,
      causeFilter: 'all',
      nowUnix,
    }),
    [resolvedData, providerDisplayNames, accountEmails, pausedSortBy, nowUnix],
  )

  const effectiveCauseFilter: QuotaRestCauseFilter =
    pausedCauseFilter !== 'all' && (basePausedGrouped.summary.causeCounts[pausedCauseFilter] ?? 0) > 0
      ? pausedCauseFilter
      : 'all'

  const pausedGrouped = useMemo(
    () => (effectiveCauseFilter === 'all'
      ? basePausedGrouped
      : groupRestingRuntimes(resolvedData?.runtimes ?? [], {
          providerDisplayNames,
          accountEmails,
          sortBy: pausedSortBy,
          causeFilter: effectiveCauseFilter,
          nowUnix,
        })),
    [basePausedGrouped, effectiveCauseFilter, resolvedData, providerDisplayNames, accountEmails, pausedSortBy, nowUnix],
  )

  const togglePausedGroup = (provider: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev)
      if (next.has(provider)) next.delete(provider)
      else next.add(provider)
      return next
    })
  }

  const resolveModelForIntegration = (integrationId: string): string => {
    const manual = verifyModelInput.trim()
    if (manual) return manual
    const integ = personIntegrations.find((i) => i.integration_id === integrationId)
    if (integ && integ.models?.[0]) return integ.models[0]
    const rt = (resolvedData?.runtimes ?? []).find((r) => r.provider === integrationId && r.model)
    return rt?.model ?? ''
  }

  const canManageProvidersSession = (cur: typeof session): boolean =>
    cur.kind === 'multi_account_signed_in'
    || (cur.kind === 'single_user_local' && !isAdminLockedForSession('admin', cur))

  const handleSaveCredential = async (ev: Event) => {
    ev.preventDefault()
    const curSession = authSession.peek()
    const multiSignedIn = curSession.kind === 'multi_account_signed_in'
    if (!canManageProvidersSession(curSession)) return
    if (!credForm || !credForm.providerId.trim() || !credForm.secret.trim()) return
    const startEpoch = currentSessionEpoch()
    const providerId = credForm.providerId.trim()
    const secret = credForm.secret.trim()
    setActionBusy('save-cred')
    setActionBanner(null)

    if (multiSignedIn) {
      // Exact wire shape: lib/server/server_key_account.ml:133-137 requires { integration_id, key }
      const res = await apiMutate<unknown>('POST', '/api/v1/setup/accounts/key', {
        integration_id: providerId,
        key: secret,
      })
      if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
      setActionBusy(null)
      if (!res.ok) {
        setActionBanner({ kind: 'err', text: `키 저장 실패: ${res.error.message}` })
        return
      }
      setActionBanner(null)
      pushShellToast(`${providerId} 개인 API 키가 등록되었습니다.`, 'success')
      setCredForm(null)
      void loadAll('manual')
      return
    }

    // Single-user CAS precondition: require real source_revision from /api/v1/runtime/config/raw (never 'latest')
    let rev = sourceRevision.trim()
    if (!rev) {
      const rawRes = await apiGet<{ readonly source_revision?: string }>('/api/v1/runtime/config/raw')
      if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
      if (rawRes.ok && typeof rawRes.value.source_revision === 'string') {
        rev = rawRes.value.source_revision.trim()
        if (rev) setSourceRevision(rev)
      }
    }
    if (!rev) {
      setActionBusy(null)
      setActionBanner({
        kind: 'err',
        text: 'runtime.toml의 source_revision을 확인할 수 없어 자격 증명을 저장할 수 없습니다. 새로고침 후 다시 시도하세요.',
      })
      return
    }

    const res = await apiMutate<unknown>('POST', '/api/v1/setup/credential', {
      provider_id: providerId,
      secret,
      source_revision: rev,
    })
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `키 저장 실패: ${res.error.message}` })
      return
    }
    setActionBanner(null)
    pushShellToast(`${providerId} 자격 증명이 저장되었습니다.`, 'success')
    setCredForm(null)
    void loadAll('manual')
  }

  const loginAbortRef = useRef<AbortController | null>(null)
  const openedLoginUrlRef = useRef<string | null>(null)
  const [loginInputText, setLoginInputText] = useState('')
  const [copiedDeviceCode, setCopiedDeviceCode] = useState(false)

  useEffect(() => () => {
    loginAbortRef.current?.abort('unmount')
  }, [])

  // Abort active CLI OAuth streams and wipe transient credential state whenever
  // the session epoch advances (sign-out, account switch, workspace change) or
  // authentication is lost. Note: in multi_account mode, Worker sessions retain
  // Manage_own_provider on /api/v1/setup/accounts/login* (server_login_http.ml:592).
  useEffect(() => {
    loginAbortRef.current?.abort('session_changed')
    loginAbortRef.current = null
    rawConfigAbortRef.current?.abort('session_changed')
    rawConfigAbortRef.current = null
    openedLoginUrlRef.current = null
    setLoginReceipt(null)
    setCredForm(null)
    setLoginInputText('')
    setCopiedDeviceCode(false)
    setSourceRevision('')
    setActionBusy(null)
  }, [epoch, session.kind, canManageProviders])

  const handleStartOAuthLogin = async (integrationId: string) => {
    const curSession = authSession.peek()
    const multiSignedIn = curSession.kind === 'multi_account_signed_in'
    if (!canManageProvidersSession(curSession)) return

    const startEpoch = currentSessionEpoch()
    loginAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    loginAbortRef.current = ctrl
    openedLoginUrlRef.current = null
    setLoginInputText('')
    setCopiedDeviceCode(false)
    setActionBusy(`login:${integrationId}`)
    setActionBanner(null)

    const isStreamActive = () =>
      mountedRef.current && isEpochCurrent(startEpoch) && !ctrl.signal.aborted && loginAbortRef.current === ctrl

    setLoginReceipt({
      loginId: '',
      integrationId,
      status: 'starting',
      accountRef: null,
      authentication: null,
      authUrl: null,
      deviceCode: null,
      inputReady: false,
      outputTail: '',
      streaming: true,
      popupBlocked: false,
    })

    await streamSetupAccountLogin({
      integrationId,
      signal: ctrl.signal,
      callbacks: {
        onStarted: (receipt) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => ({
            ...(cur ?? { loginId: receipt.loginId, integrationId }),
            loginId: receipt.loginId || cur?.loginId || '',
            integrationId: receipt.integrationId || integrationId,
            status: receipt.status,
            accountRef: receipt.accountRef ?? cur?.accountRef ?? null,
            authentication: receipt.authentication ?? cur?.authentication ?? null,
            streaming: true,
          }))
        },
        onOutput: (_stream, text) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => (cur ? { ...cur, outputTail: `${cur.outputTail ?? ''}${text}`.slice(-2000) } : cur))
        },
        onScreen: (text) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => (cur ? { ...cur, outputTail: text.slice(-2000) } : cur))
        },
        onAuthUrl: (url) => {
          if (!isStreamActive()) return
          let popupBlocked = false
          if (openedLoginUrlRef.current !== url) {
            openedLoginUrlRef.current = url
            if (typeof window !== 'undefined' && typeof window.open === 'function') {
              try {
                const win = window.open(url, '_blank', 'noopener,noreferrer')
                popupBlocked = win === null
              } catch {
                popupBlocked = true
              }
            }
          }
          setLoginReceipt((cur) => (cur ? { ...cur, authUrl: url, popupBlocked } : cur))
        },
        onDeviceCode: (code) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => (cur ? { ...cur, deviceCode: code } : cur))
        },
        onInputReady: () => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => (cur ? { ...cur, inputReady: true } : cur))
        },
        onComplete: (receipt) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => ({
            ...(cur ?? { loginId: receipt.loginId, integrationId }),
            loginId: receipt.loginId || cur?.loginId || '',
            integrationId: receipt.integrationId || integrationId,
            status: 'complete',
            accountRef: receipt.accountRef ?? cur?.accountRef ?? null,
            authentication: receipt.authentication ?? cur?.authentication ?? null,
            inputReady: false,
            streaming: false,
          }))
          setActionBanner(null)
          pushShellToast(`${integrationId} CLI OAuth 로그인이 완료되었습니다.`, 'success')
          void loadAll('manual')
          const ref = receipt.accountRef
          // POST /api/v1/setup/accounts/verify is only mounted in multi_account mode (server_login_http.mli:79)
          if (multiSignedIn && ref && resolveModelForIntegration(integrationId)) {
            void handleVerifyAccount(integrationId, ref)
          }
        },
        onError: (message, receipt) => {
          if (!isStreamActive()) return
          setLoginReceipt((cur) => (cur
            ? {
                ...cur,
                loginId: receipt?.loginId || cur.loginId,
                status: receipt?.status || 'failed',
                accountRef: receipt?.accountRef ?? cur.accountRef,
                message,
                inputReady: false,
                streaming: false,
              }
            : null))
          setActionBanner({ kind: 'err', text: `CLI OAuth 로그인 실패: ${message}` })
        },
      },
    })

    if (isStreamActive()) {
      setActionBusy((cur) => (cur === `login:${integrationId}` ? null : cur))
      setLoginReceipt((cur) => (cur ? { ...cur, streaming: false } : cur))
    }
  }

  const handleSubmitLoginInput = async (ev: Event) => {
    ev.preventDefault()
    if (!canManageProvidersSession(authSession.peek())) return
    if (!loginReceipt?.loginId || !loginInputText.trim()) return
    const startEpoch = currentSessionEpoch()
    const text = loginInputText.trim()
    setActionBusy('login-input')
    const res = await sendSetupLoginInput(loginReceipt.loginId, { kind: 'text', text })
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `CLI 입력 전송 실패: ${res.error.message}` })
      return
    }
    setLoginInputText('')
    setLoginReceipt((cur) => (cur ? { ...cur, inputReady: false } : cur))
  }

  const handleSendLoginEnterKey = async () => {
    if (!canManageProvidersSession(authSession.peek())) return
    if (!loginReceipt?.loginId) return
    const startEpoch = currentSessionEpoch()
    setActionBusy('login-input')
    const res = await sendSetupLoginInput(loginReceipt.loginId, { kind: 'key', key: 'enter' })
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `Enter 키 전송 실패: ${res.error.message}` })
      return
    }
    setLoginReceipt((cur) => (cur ? { ...cur, inputReady: false } : cur))
  }

  const handleCancelSetupLogin = async () => {
    if (!canManageProvidersSession(authSession.peek())) return
    const startEpoch = currentSessionEpoch()
    const owner = loginAbortRef.current
    if (loginReceipt?.loginId) {
      await cancelSetupLogin(loginReceipt.loginId)
    }
    if (!mountedRef.current || !isEpochCurrent(startEpoch) || loginAbortRef.current !== owner) return
    owner?.abort('cancelled')
    setLoginReceipt((cur) => (cur ? { ...cur, status: 'cancelled', streaming: false, inputReady: false } : cur))
  }

  const handleRefreshLoginReceipt = async () => {
    if (!canManageProvidersSession(authSession.peek())) return
    const loginId = loginReceipt?.loginId?.trim()
    if (!loginId) return
    const startEpoch = currentSessionEpoch()
    setActionBusy('receipt')
    const res = await apiGet<Record<string, unknown>>(
      `/api/v1/setup/accounts/login/${encodeURIComponent(loginId)}`,
    )
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy((cur) => (cur === 'receipt' ? null : cur))
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `로그인 영수증 조회 실패: ${res.error.message}` })
      return
    }
    const payload = res.value
    setLoginReceipt((cur) => {
      if (!cur || cur.loginId !== loginId) return cur
      return {
        ...cur,
        status: typeof payload.status === 'string' ? payload.status : cur.status,
        accountRef: typeof payload.account_ref === 'string' ? payload.account_ref : cur.accountRef,
        authentication: typeof payload.authentication === 'string' ? payload.authentication : cur.authentication,
      }
    })
  }

  const handleVerifyAccount = async (providerId: string, providerAccountId?: string) => {
    if (authSession.peek().kind !== 'multi_account_signed_in') {
      setActionBanner({
        kind: 'err',
        text: '계정 검증(/api/v1/setup/accounts/verify)은 multi_account 모드에서만 지원됩니다.',
      })
      return
    }
    const acctId = (providerAccountId ?? '').trim()
    const model = resolveModelForIntegration(providerId)
    if (!acctId || !model) {
      setActionBanner({
        kind: 'err',
        text: `계정 검증 실패 (${providerId}): provider_account_id와 검증할 모델명이 필요합니다.`,
      })
      return
    }
    const startEpoch = currentSessionEpoch()
    setActionBusy(`verify:${acctId}`)
    setActionBanner(null)
    // Exact wire shape: lib/server/server_setup_account_login.ml:424-432 requires { provider_account_id, model }
    const res = await apiMutate<unknown>('POST', '/api/v1/setup/accounts/verify', {
      provider_account_id: acctId,
      model,
    })
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `검증 실패 (${acctId}): ${res.error.message}` })
      return
    }
    setActionBanner(null)
    pushShellToast(`${acctId} (${model}) 계정 검증 완료.`, 'success')
    void loadAll('manual')
  }

  const handleRemoveKey = async (id: string) => {
    if (authSession.peek().kind !== 'multi_account_signed_in') return
    const startEpoch = currentSessionEpoch()
    setActionBusy(`remove:${id}`)
    setActionBanner(null)
    const res = await apiMutate<unknown>('DELETE', `/api/v1/setup/accounts/key/${encodeURIComponent(id)}`)
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `삭제 실패 (${id}): ${res.error.message}` })
      return
    }
    setActionBanner(null)
    pushShellToast(`${id} 자격 증명을 제거했습니다.`, 'success')
    void loadAll('manual')
  }

  const openScopeDetail = (item: EnrichedQuotaScope) => {
    const { scope, classification, calls24h, windowBurns, history, impact } = item
    const providerIds = new Set(scope.providers.map((p) => p.id))
    const scopeRuntimes = (resolvedData?.runtimes ?? []).filter((rt) => providerIds.has(rt.provider_id))
    const badgeStyle = costBadgeStyle(classification.kind)

    props.onInspect({
      title: `할당량 상세 · ${item.displayName}`,
      subtitle: `${scope.scope} · ${classification.badge}`,
      kind: 'quota_scope_detail',
      data: {
        scope: scope.scope,
        scope_id: scope.scope_id ?? null,
        classification,
        calls24h,
        windowBurns,
        history,
        impact,
      },
      render: () => html`
        <div data-testid="quota-scope-detail" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }}>
          <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
              <div>
                <div style=${{ fontWeight: 600, fontSize: 'var(--fs-14)', color: 'var(--fg-1)' }}>${item.displayName}</div>
                <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${scope.scope}</div>
              </div>
              <span
                class="mono tnum"
                style=${{
                  ...badgeStyle,
                  padding: 'var(--sp-0) var(--sp-2)',
                  borderRadius: 'var(--radius-pill)',
                  fontSize: 'var(--fs-11)',
                  fontWeight: 600,
                }}
              >
                ${classification.badge}
              </span>
            </div>
            ${item.accountLines.length > 0 && html`
              <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
                ${item.accountLines.map((line) => html`
                  <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>${line}</div>
                `)}
              </div>
            `}
            ${scopeRuntimes.some((rt) => rt.quota_rest !== null || rt.rate_limited) && html`
              <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', paddingTop: 'var(--sp-1)', borderTop: '1px solid var(--line-1)' }}>
                <div style=${{ fontSize: 'var(--fs-11)', fontWeight: 600, color: 'var(--err-fg)' }}>현재 휴식·제한 런타임</div>
                ${scopeRuntimes.filter((rt) => rt.quota_rest !== null || rt.rate_limited).map((rt) => {
                  const rest = rt.quota_rest
                  const rel = rest ? formatReleaseSummary(rest.until, rest.reset_stated, nowUnix) : null
                  return html`
                    <div key=${rt.id} class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)', display: 'flex', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                      <span>${rt.id}</span>
                      <span>
                        ${rest
                          ? `${quotaRestCauseMeta(rest.cause).shortLabel} · ${rel?.countdown ?? '미정'}${rel?.localTime ? ` (${rel.localTime})` : ''}`
                          : '429 속도 제한'}
                      </span>
                    </div>
                  `
                })}
              </div>
            `}
          </section>

          <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <h4 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>창별 소진 · 지속 시간 분석 (마지막 소진 관측 기준)</h4>
            ${windowBurns.length === 0
              ? html`<div class="dtable-absent">보고된 할당량 창이 없습니다.</div>`
              : html`
                  <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
                    ${windowBurns.map((burn, bIdx) => html`
                      <div
                        key=${`${burn.label}-${burn.limitId ?? bIdx}`}
                        style=${{
                          padding: 'var(--sp-2)',
                          borderRadius: 'var(--radius-sm)',
                          background: 'var(--bg-2)',
                          border: `1px solid ${burn.spent ? 'var(--err-border)' : 'var(--line-1)'}`,
                          display: 'flex',
                          flexDirection: 'column',
                          gap: '4px',
                        }}
                      >
                        <div style=${{ display: 'flex', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-12)' }}>
                          <span class="mono" style=${{ fontWeight: 600 }}>
                            ${burn.label}${burn.limitId ? ` (${burn.limitId})` : ''}
                          </span>
                          <span class="mono tnum" style=${{ color: burn.spent ? 'var(--err-fg)' : 'var(--fg-2)', fontWeight: 600 }}>
                            ${burn.utilizationPct !== null ? `${burn.utilizationPct.toFixed(1)}%` : '미보고'} · 리셋 ${formatResetCountdown(burn.resetsAtSec, nowUnix)}
                          </span>
                        </div>
                        ${burn.spent && burn.elapsedSinceStartSec !== null
                          ? html`
                              <div class="mono tnum" style=${{ fontSize: 'var(--fs-12)', color: 'var(--err-fg)', fontWeight: 600 }}>
                                ⏱ 창 시작 후 ${formatDurationKo(burn.elapsedSinceStartSec)} 시점에 마지막 소진 관측
                              </div>
                            `
                          : burn.elapsedSinceStartSec !== null
                            ? html`
                                <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
                                  창 경과 ${formatDurationKo(burn.elapsedSinceStartSec)}${burn.projectedTotalSec !== null
                                    ? ` · 현재 페이스 기준 약 ${formatDurationKo(burn.projectedTotalSec)} 지속 예상`
                                    : ''}
                                </div>
                              `
                            : html`
                                <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                                  창 길이 또는 리셋 시각 미보고 — 소진 경과 계산 불가
                                </div>
                              `}
                        <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                          ${burn.windowStartSec !== null && html`<span>추정 시작 ${formatUnixTime(burn.windowStartSec)}</span>`}
                          <span>마지막 관측 ${formatUnixTime(burn.observedAtSec)}</span>
                          <span>출처 ${burn.source}</span>
                        </div>
                      </div>
                    `)}
                    <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                      ※ 소진 경과는 창 추정 시작 시각(리셋 시각 − 창 길이)부터 마지막 소진 관측 시각 기준입니다.
                    </div>
                  </div>
                `}
          </section>

          <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <h4 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>최근 24시간 호출 · 토큰 통계</h4>
            ${calls24h === null
              ? html`<div class="dtable-absent">24시간 런타임 호출 통계를 읽지 못했습니다 (단일 사용자 관리자 세션에서 제공).</div>`
              : html`
                  <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(110px, 1fr))', gap: 'var(--sp-2)' }}>
                    <div style=${{ padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)' }}>
                      <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>24h 호출</div>
                      <div class="mono tnum" style=${{ fontSize: 'var(--fs-14)', fontWeight: 600 }}>${calls24h.calls}회</div>
                    </div>
                    <div style=${{ padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)' }}>
                      <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>성공 / 오류</div>
                      <div class="mono tnum" style=${{ fontSize: 'var(--fs-14)', fontWeight: 600, color: calls24h.errors > 0 ? 'var(--err-fg)' : 'var(--ok-fg)' }}>
                        ${calls24h.success} / ${calls24h.errors}
                      </div>
                    </div>
                    <div style=${{ padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)' }}>
                      <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>툴 호출</div>
                      <div class="mono tnum" style=${{ fontSize: 'var(--fs-14)', fontWeight: 600 }}>${calls24h.toolCalls}회</div>
                    </div>
                    <div style=${{ padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)' }}>
                      <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>입력 / 출력 토큰</div>
                      <div class="mono tnum" style=${{ fontSize: 'var(--fs-12)', fontWeight: 600 }}>
                        ${calls24h.inputTokens !== null ? formatCompactNumber(calls24h.inputTokens) : '미보고'} / ${calls24h.outputTokens !== null ? formatCompactNumber(calls24h.outputTokens) : '미보고'}
                      </div>
                    </div>
                  </div>
                  ${calls24h.runtimes.length > 0 && html`
                    <div style=${{ overflowX: 'auto' }}>
                      <table class="dtable" style=${{ width: '100%', fontSize: 'var(--fs-11)' }}>
                        <thead>
                          <tr>
                            <th>런타임</th>
                            <th>호출</th>
                            <th>성공/오류</th>
                            <th>p50 / p95</th>
                          </tr>
                        </thead>
                        <tbody>
                          ${calls24h.runtimes.map((rt) => html`
                            <tr key=${rt.runtime_id}>
                              <td class="mono">${rt.runtime_id}</td>
                              <td class="mono tnum">${rt.entry_count}</td>
                              <td class="mono tnum">${rt.success_count} / ${rt.error_count}</td>
                              <td class="mono tnum">
                                ${rt.p50_latency_ms !== null ? `${Math.round(rt.p50_latency_ms)}ms` : '—'} / ${rt.p95_latency_ms !== null ? `${Math.round(rt.p95_latency_ms)}ms` : '—'}
                              </td>
                            </tr>
                          `)}
                        </tbody>
                      </table>
                    </div>
                  `}
                `}
          </section>

          <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <h4 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>
              최근 이력 통계${history ? ` (${history.days}일)` : ''}
            </h4>
            ${history === null || history.points.length === 0
              ? html`<div class="dtable-absent">선택 기간 내 이 스코프의 저장된 사용량 이력이 없습니다.</div>`
              : html`
                  <div class="mono tnum" style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)', display: 'flex', gap: 'var(--sp-3)', flexWrap: 'wrap' }}>
                    <span>관측 일수 ${history.observedDays}일</span>
                    <span style=${{ color: history.exhaustedDays > 0 ? 'var(--err-fg)' : 'var(--ok-fg)', fontWeight: 600 }}>
                      소진 일수 ${history.exhaustedDays}일
                    </span>
                    ${history.peakPct !== null && html`<span>최고 사용률 ${history.peakPct.toFixed(1)}%</span>`}
                  </div>
                  <div style=${{ overflowX: 'auto' }}>
                    <table class="dtable" style=${{ width: '100%', fontSize: 'var(--fs-11)' }}>
                      <thead>
                        <tr>
                          <th>관측 시각</th>
                          <th>창</th>
                          <th>사용량</th>
                          <th>리셋</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${history.points.slice(0, 14).map((pt, pIdx) => {
                          const ptPct = utilizationToPct(pt.utilization)
                          return html`
                            <tr key=${`${pt.observed_at}-${pt.kind}-${pt.limit_id ?? pIdx}`}>
                              <td class="mono tnum">${formatUnixTime(pt.observed_at)}</td>
                              <td class="mono">${pt.kind}${pt.limit_id ? ` (${pt.limit_id})` : ''}</td>
                              <td class="mono tnum" style=${{ color: ptPct !== null && ptPct >= 100 ? 'var(--err-fg)' : 'var(--fg-1)' }}>
                                ${historyPointValueLabel(pt)}
                              </td>
                              <td class="mono tnum">${pt.resets_at ? formatUnixTime(pt.resets_at) : '—'}</td>
                            </tr>
                          `
                        })}
                      </tbody>
                    </table>
                  </div>
                `}
          </section>

          <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <h4 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>연결된 레인 · Keeper</h4>
            <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
              <div>
                <span style=${{ color: 'var(--fg-3)' }}>레인 (${impact.laneIds.length}): </span>
                <span class="mono">${impact.laneIds.length > 0 ? impact.laneIds.join(', ') : '없음'}</span>
              </div>
              <div>
                <span style=${{ color: 'var(--fg-3)' }}>Keeper (${impact.keepers.length}): </span>
                <span class="mono">${impact.keepers.length > 0 ? impact.keepers.join(', ') : '직접 연결 없음'}</span>
              </div>
            </div>
          </section>
        </div>
      `,
    })
  }

  const renderScopeCard = (item: EnrichedQuotaScope) => {
    const { scope, classification: cls, maxPct: pct, primaryProviderId: pid, displayName: name, accountLines: accounts } = item

    const scopeProviderIds = new Set(scope.providers.map((p) => p.id))
    let scopeVision = false
    let scopeImageGen = false
    for (const rt of resolvedData?.runtimes ?? []) {
      if (!scopeProviderIds.has(rt.provider_id)) continue
      const caps = resolveRuntimeMediaCapabilities(rt)
      if (caps.visionInput) scopeVision = true
      if (caps.imageOutput) scopeImageGen = true
    }
    const badgeStyle = costBadgeStyle(cls.kind)
    // A card of a resting scope says so, in the words the paused panel uses
    // for the cause. It is why the card is in Tier 1 whatever its usage says.
    // When the rest ends is in the panel: a window's reset on this card is
    // another fact, and the two side by side read as one. A rest that is over
    // on this page's clock is one the panel calls released until the next
    // read drops it, so the card does not call it paused.
    const rest = quotaRestOfScope(scope, resolvedData?.runtimes ?? [])
    const restMeta = rest !== null && rest.until * 1000 > Date.now() ? quotaRestCauseMeta(rest.cause) : null
    const cutoffBurn = item.primaryCutoffBurn

    return html`
      <article
        key=${item.key}
        class="wka-card"
        data-testid=${`quota-scope-card-${pid}`}
        style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}
      >
        <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <div style=${{ minWidth: 0 }}>
            <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)', flexWrap: 'wrap', fontWeight: 600, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>
              <span>${name}</span>
              ${scopeVision && html`<span class="mono rt-cap-chip" data-testid=${`scope-${pid}-cap-vision`}>Vision</span>`}
              ${scopeImageGen && html`<span class="mono rt-cap-chip rt-cap-chip--gen" data-testid=${`scope-${pid}-cap-image-gen`}>Image Gen</span>`}
            </div>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${scope.scope}</div>
            ${accounts.map((line) => html`<div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>${line}</div>`)}
            ${restMeta !== null && html`
              <div data-testid="quota-card-rest" style=${{ fontSize: 'var(--fs-11)', color: causeBadgeStyle(restMeta.tone).color }}>
                일시 중지 · ${restMeta.shortLabel}
              </div>
            `}
          </div>
          <span
            class="mono tnum"
            style=${{
              ...badgeStyle,
              padding: 'var(--sp-0) var(--sp-2)',
              borderRadius: 'var(--radius-pill)',
              fontSize: 'var(--fs-11)',
              fontWeight: 600,
              whiteSpace: 'nowrap',
            }}
          >
            ${cls.badge}
          </span>
        </div>

        ${scope.windows.length > 0
          ? html`
              <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
                ${scope.windows.map((w, wIdx) => {
                  const u = w.utilization
                  let barPct = 0
                  let labelVal = '미보고'
                  if (u.unit === 'fraction') {
                    barPct = Math.min(100, Math.max(0, u.value * 100))
                    labelVal = `${barPct.toFixed(1)}%`
                  } else if (u.unit === 'percent') {
                    barPct = Math.min(100, Math.max(0, u.value))
                    labelVal = `${barPct.toFixed(0)}%`
                  } else if (u.unit === 'credit_balance') {
                    labelVal = `${u.remaining.toFixed(2)} ${u.currency}`
                    barPct = u.total && u.total > 0 ? Math.min(100, ((u.total - u.remaining) / u.total) * 100) : 0
                  } else if (u.unit === 'usd') {
                    labelVal = u.limit !== null ? `$${u.value.toFixed(2)} / $${u.limit.toFixed(2)}` : `$${u.value.toFixed(2)}`
                    barPct = u.limit && u.limit > 0 ? Math.min(100, (u.value / u.limit) * 100) : 0
                  } else if (u.unit === 'credit_unlimited') {
                    labelVal = '무제한 구독'
                  }
                  const fillColor = barPct >= 95
                    ? 'var(--err)'
                    : barPct >= 75
                      ? 'var(--warn)'
                      : 'var(--ok)'

                  return html`
                    <div key=${`${wIdx}-${w.limit_id ?? 'w'}`} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-0)' }}>
                      <div style=${{ display: 'flex', justifyContent: 'space-between', fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
                        <span class="mono">${windowKindLabel(w.window)} ${w.limit_id ? `(${w.limit_id})` : ''}</span>
                        <span class="mono tnum">
                          ${labelVal} · 리셋 ${formatResetCountdown(w.resets_at, nowUnix)}
                        </span>
                      </div>
                      <div style=${{ height: '6px', borderRadius: 'var(--radius-pill)', background: 'var(--bg-3)', overflow: 'hidden' }}>
                        <div style=${{ width: `${barPct}%`, height: '100%', background: fillColor }} />
                      </div>
                    </div>
                  `
                })}
              </div>
            `
          : html`
              <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-3)' }}>
                ${scope.state === 'reported_no_windows' ? '창 정보 없음 (제공자 미제공)' : '서버 시작 이후 미보고'}
              </div>
            `}

        ${(cutoffBurn !== null || item.calls24h !== null || (item.history !== null && item.history.observedDays > 0)) && html`
          <div style=${{ display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-1)', fontSize: 'var(--fs-11)' }}>
            ${cutoffBurn !== null && cutoffBurn.elapsedSinceStartSec !== null && html`
              <span
                class="mono tnum"
                title=${`창 시작 추정 시각(${cutoffBurn.windowStartSec ? formatUnixTime(cutoffBurn.windowStartSec) : '—'}) → 마지막 소진 관측(${formatUnixTime(cutoffBurn.observedAtSec)}) 기준`}
                style=${{
                  padding: '2px 6px',
                  borderRadius: 'var(--radius-sm)',
                  background: 'var(--err-soft)',
                  border: '1px solid var(--err-border)',
                  color: 'var(--err-fg)',
                  fontWeight: 600,
                }}
              >
                ⏱ ${cutoffBurn.label} 창 · 창 시작 후 ${formatDurationKo(cutoffBurn.elapsedSinceStartSec)} 시점에 마지막 소진 관측
              </span>
            `}
            ${item.calls24h !== null && html`
              <span
                class="mono tnum"
                style=${{
                  padding: '2px 6px',
                  borderRadius: 'var(--radius-sm)',
                  background: 'var(--bg-2)',
                  border: '1px solid var(--line-1)',
                  color: 'var(--fg-2)',
                }}
              >
                24h 호출 ${item.calls24h.calls}회${item.calls24h.errors > 0 ? ` · 오류 ${item.calls24h.errors}` : ''}
              </span>
            `}
            ${item.history !== null && item.history.observedDays > 0 && html`
              <span
                class="mono tnum"
                style=${{
                  padding: '2px 6px',
                  borderRadius: 'var(--radius-sm)',
                  background: 'var(--bg-2)',
                  border: '1px solid var(--line-1)',
                  color: item.history.exhaustedDays > 0 ? 'var(--warn-fg)' : 'var(--fg-3)',
                }}
              >
                최근 ${item.history.days}일 소진 ${item.history.exhaustedDays}일${item.history.peakPct !== null ? ` · 최고 ${item.history.peakPct.toFixed(0)}%` : ''}
              </span>
            `}
          </div>
        `}

        <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', paddingTop: 'var(--sp-1)', borderTop: '1px solid var(--line-1)', flexWrap: 'wrap' }}>
          <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            최대 사용률: ${pct !== null ? `${pct.toFixed(1)}%` : '미보고'}
          </span>
          <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
            <button
              type="button"
              class="btn-ghost"
              data-testid=${`quota-detail-btn-${pid}`}
              onClick=${() => openScopeDetail(item)}
            >
              상세 보기
            </button>
            ${canManageProviders && html`
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => setCredForm({ providerId: pid, secret: '', mode: 'api_key' })}
              >
                Re-auth
              </button>
            `}
            ${canManageProviders && !adminLocked && html`
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(pid)}`)}
              >
                Open Config Key
              </button>
            `}
          </div>
        </div>
      </article>
    `
  }

  const totalScopes = (resolvedData?.provider_usage_windows ?? []).length
  const pausedSummary = pausedGrouped.summary
  const pausedGroups = pausedGrouped.groups
  const presentCauses = KNOWN_CAUSE_FILTERS.filter((c) => (pausedSummary.causeCounts[c] ?? 0) > 0)
  const allVisibleExpanded = pausedGroups.length > 0 && pausedGroups.every((g) => expandedGroups.has(g.provider))
  const pausedPanelOpen = pausedPanelPref ?? pausedSummary.hasPaymentRefused
  const globalSoonestRelease = pausedSummary.soonestUntil !== null
    ? formatReleaseSummary(pausedSummary.soonestUntil, pausedSummary.soonestResetStated, nowUnix)
    : null
  const pausedKpiTone = pausedSummary.hasPaymentRefused || pausedSummary.hasCredentialRefused
    ? 'bad'
    : pausedSummary.availableCount < pausedSummary.totalRegistered
      ? 'warn'
      : 'ok'
  const enabledIntegrationsCount = integrations.filter((i) => i.enabled !== false).length
  const sortLabelMap: Readonly<Record<QuotaRestSortKey, string>> = {
    release: '해제 임박순',
    count: '런타임 많은순',
    name: '이름순',
  }
  const activeFilterSuffix = effectiveCauseFilter !== 'all'
    ? ` · ${quotaRestCauseMeta(effectiveCauseFilter).shortLabel}`
    : pausedSortBy !== 'release'
      ? ` · ${sortLabelMap[pausedSortBy]}`
      : ''
  const pausedControlItems: readonly PopoverMenuItem[] = [
    {
      id: 'sort-release',
      label: '정렬: 해제 임박순',
      active: pausedSortBy === 'release',
      testId: 'paused-sort-release',
      onSelect: () => setPausedSortBy('release'),
    },
    {
      id: 'sort-count',
      label: '정렬: 런타임 많은순',
      active: pausedSortBy === 'count',
      testId: 'paused-sort-count',
      onSelect: () => setPausedSortBy('count'),
    },
    {
      id: 'sort-name',
      label: '정렬: 이름순',
      active: pausedSortBy === 'name',
      testId: 'paused-sort-name',
      onSelect: () => setPausedSortBy('name'),
    },
    ...(presentCauses.length >= 2
      ? [
          {
            id: 'filter-all',
            label: `사유: 전체 (${pausedSummary.restingCount})`,
            active: effectiveCauseFilter === 'all',
            testId: 'paused-filter-all',
            separatorBefore: true,
            onSelect: () => setPausedCauseFilter('all'),
          },
          ...presentCauses.map((cause) => {
            const meta = quotaRestCauseMeta(cause)
            const count = pausedSummary.causeCounts[cause] ?? 0
            return {
              id: `filter-${cause}`,
              label: `사유: ${meta.shortLabel} (${count})`,
              active: effectiveCauseFilter === cause,
              testId: `paused-filter-${cause}`,
              onSelect: () => setPausedCauseFilter(cause),
            }
          }),
        ]
      : []),
    {
      id: 'toggle-expand-all',
      label: allVisibleExpanded ? '모두 접기' : '모두 펼치기',
      testId: 'paused-expand-all-toggle',
      separatorBefore: true,
      onSelect: () => {
        if (allVisibleExpanded) {
          setExpandedGroups(new Set())
        } else {
          setExpandedGroups(new Set(pausedGroups.map((g) => g.provider)))
        }
      },
    },
  ]

  return html`
    <div class="ov" data-testid="runtime-quotas-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · QUOTAS & RATE LIMITS</span>
          <h1>제공자 할당량 · 일시 중지 · 자격 증명</h1>
          <p class="ov-sub">
            $0 Sub / $0 Exhausted / ? Unreported 정직 분류 · 조회 창 ${win} (Provider History ${providerDays}d)
          </p>
        </div>
        <div style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          ${canManageProviders && html`
            <button
              type="button"
              class="btn-primary"
              onClick=${() => setCredForm({
                providerId: personIntegrations[0]?.integration_id ?? integrations[0]?.id ?? 'openai',
                secret: '',
                mode: 'api_key',
              })}
            >
              + API 키 등록
            </button>
          `}
          <${RefreshButton} onRefresh=${() => loadAll('manual')} />
        </div>
      </header>

      ${actionBanner && html`
        <div role="alert" class="ap-error">
          ${actionBanner.text}
        </div>
      `}

      ${resolvedObs.kind === 'failed' && html`
        <div class="ap-error" role="alert">할당량 요약 조회 실패: ${resolvedObs.error.message}</div>
      `}

      <section class="ov-kpis" aria-label="할당량 요약">
        <button
          type="button"
          class="ov-kpi"
          data-testid="kpi-quota-attention"
          onClick=${() => setScopeFilter((cur) => (cur === 'attention' ? 'all' : 'attention'))}
          style=${{
            textAlign: 'left',
            cursor: 'pointer',
            borderColor: scopeFilter === 'attention' ? 'var(--err-border)' : undefined,
          }}
        >
          <div class="ov-kpi-k">주의 필요 · 소진 / 크레딧 / 429</div>
          <div class=${`ov-kpi-v ${resolvedObs.kind === 'failed' ? 'bad' : resolvedObs.kind === 'value' ? (groupedScopes.attention.length > 0 ? 'bad' : 'ok') : ''}`}>
            ${resolvedObs.kind === 'value'
              ? groupedScopes.attention.length
              : formatObserved(resolvedObs)}
          </div>
        </button>
        <button
          type="button"
          class="ov-kpi"
          data-testid="kpi-quota-healthy"
          onClick=${() => setScopeFilter((cur) => (cur === 'healthy_sub' ? 'all' : 'healthy_sub'))}
          style=${{
            textAlign: 'left',
            cursor: 'pointer',
            borderColor: scopeFilter === 'healthy_sub' ? 'var(--ok-border)' : undefined,
          }}
        >
          <div class="ov-kpi-k">정상 활성 구독 ($0 Sub)</div>
          <div class=${`ov-kpi-v ${resolvedObs.kind === 'failed' ? 'bad' : resolvedObs.kind === 'value' ? 'ok' : ''}`}>
            ${resolvedObs.kind === 'value'
              ? groupedScopes.healthySub.length
              : formatObserved(resolvedObs)}
          </div>
        </button>
        <button
          type="button"
          class="ov-kpi"
          data-testid="kpi-quota-unreported"
          onClick=${() => setScopeFilter((cur) => (cur === 'unreported' ? 'all' : 'unreported'))}
          style=${{
            textAlign: 'left',
            cursor: 'pointer',
            borderColor: scopeFilter === 'unreported' ? 'var(--line-2)' : undefined,
          }}
        >
          <div class="ov-kpi-k">사용량 미보고 (? Unreported)</div>
          <div class=${`ov-kpi-v ${resolvedObs.kind === 'failed' ? 'bad' : ''}`}>
            ${resolvedObs.kind === 'value'
              ? groupedScopes.unreported.length
              : formatObserved(resolvedObs)}
          </div>
        </button>
        <div class="ov-kpi" data-testid="kpi-paused-runtimes">
          <div class="ov-kpi-k">
            ${pausedSummary.blockedCount > pausedSummary.restingCount
              ? '일시 중지 런타임 · 차단'
              : '일시 중지 런타임'}
          </div>
          <div class=${`ov-kpi-v ${resolvedObs.kind === 'failed' ? 'bad' : resolvedObs.kind === 'value' ? pausedKpiTone : ''}`}>
            ${resolvedObs.kind !== 'value'
              ? formatObserved(resolvedObs)
              : pausedSummary.totalRegistered > 0
                ? `${pausedSummary.blockedCount} / ${pausedSummary.totalRegistered}`
                : String(pausedSummary.blockedCount)}
          </div>
          ${resolvedObs.kind === 'value' && pausedSummary.totalRegistered > 0 && html`
            <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', marginTop: 'var(--sp-0)' }}>
              전체 ${pausedSummary.totalRegistered} · 가용 ${pausedSummary.availableCount}${pausedSummary.credentialRefusedCount > 0
                ? ` · 인증 거부 ${pausedSummary.credentialRefusedCount}`
                : ''}${pausedSummary.rateLimitedCount > 0
                ? ` · 속도 제한 ${pausedSummary.rateLimitedCount}`
                : ''}
            </div>
          `}
        </div>
      </section>

      ${pausedSummary.restingCount > 0 && html`
        <section
          class="wka-card"
          data-testid="paused-runtimes-panel"
          aria-label="일시 중지 런타임"
          style=${{
            display: 'flex',
            flexDirection: 'column',
            gap: 'var(--sp-2)',
            borderColor: pausedSummary.hasPaymentRefused ? 'var(--err-border)' : 'var(--warn-border)',
            background: pausedSummary.hasPaymentRefused ? 'var(--err-soft)' : 'var(--warn-soft)',
          }}
        >
          <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
            <button
              type="button"
              class="ap-disclosure-trigger"
              data-testid="paused-panel-toggle"
              aria-expanded=${pausedPanelOpen}
              onClick=${() => setPausedPanelPref(!pausedPanelOpen)}
              style=${{
                flex: '1 1 240px',
                padding: 'var(--sp-1) var(--sp-2)',
                color: 'var(--fg-1)',
              }}
            >
              <span style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-13)', fontWeight: 600 }}>
                <span aria-hidden="true">${pausedPanelOpen ? '▾' : '▸'}</span>
                ${pausedPanelOpen
                  ? html`
                      <span>일시 중지 런타임 (${pausedSummary.restingCount}/${pausedSummary.totalRegistered})</span>
                      <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', fontWeight: 500, color: 'var(--fg-2)' }}>
                        ${pausedSummary.groupCount}개 계정 · 가용 ${pausedSummary.availableCount}
                      </span>
                    `
                  : html`
                      <span class="mono tnum" style=${{ fontSize: 'var(--fs-12)' }}>
                        일시 중지 ${pausedSummary.restingCount}/${pausedSummary.totalRegistered} (${pausedSummary.groupCount}개 계정) · 가용 ${pausedSummary.availableCount}${globalSoonestRelease ? ` · ${soonestReleaseWords(globalSoonestRelease)}` : ''}
                      </span>
                    `}
              </span>
            </button>

            ${pausedPanelOpen && html`
              <div style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', flexShrink: 0 }}>
                ${globalSoonestRelease && html`
                  <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: globalSoonestRelease.isSoon ? 'var(--ok-fg)' : 'var(--fg-2)' }}>
                    ${soonestReleaseWords(globalSoonestRelease)}
                  </span>
                `}
                <${PopoverMenu}
                  triggerLabel=${`정렬·필터${activeFilterSuffix} ▾`}
                  triggerTestId="paused-controls-trigger"
                  popoverTestId="paused-controls-menu"
                  align="right"
                  ariaLabel="일시 중지 런타임 정렬 및 사유 필터"
                  items=${pausedControlItems}
                />
              </div>
            `}
          </div>

          ${pausedPanelOpen && html`
            <p style=${{ margin: 0, fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
              할당량 소진·결제 거절로 자동 우회 중인 런타임입니다. 해제 시각이 지나면 자동으로 다시 호출됩니다.
            </p>

            <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
              ${pausedGroups.map((group) => {
                const isOpen = expandedGroups.has(group.provider)
                const rel = formatReleaseSummary(group.soonestUntil, group.soonestResetStated, nowUnix)
                const hasPayment = group.causes.includes('payment_refused')
                const showEstimated = rel.isEstimated
                return html`
                  <div
                    key=${group.provider}
                    data-testid=${`paused-group-${group.provider}`}
                    style=${{
                      border: `1px solid ${hasPayment ? 'var(--err-border)' : 'var(--line-1)'}`,
                      borderRadius: 'var(--radius-sm)',
                      background: 'var(--bg-1)',
                    }}
                  >
                    <button
                      type="button"
                      class="ap-disclosure-trigger"
                      aria-expanded=${isOpen}
                      onClick=${() => togglePausedGroup(group.provider)}
                      style=${{
                        flexWrap: 'wrap',
                        padding: 'var(--sp-2) var(--sp-3)',
                        borderRadius: 'var(--radius-sm)',
                        color: 'var(--fg-1)',
                      }}
                    >
                      <span style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', minWidth: 0 }}>
                        <span aria-hidden="true" style=${{ color: 'var(--fg-3)' }}>${isOpen ? '▾' : '▸'}</span>
                        <span style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${group.displayName}</span>
                        ${group.displayName !== group.provider && html`
                          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${group.provider}</span>
                        `}
                        ${group.accountLineText && html`
                          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>${group.accountLineText}</span>
                        `}
                        ${group.causes.map((cause) => {
                          const meta = quotaRestCauseMeta(cause)
                          return html`
                            <span
                              key=${cause}
                              style=${{
                                ...causeBadgeStyle(meta.tone),
                                padding: 'var(--sp-0) var(--sp-2)',
                                borderRadius: 'var(--radius-pill)',
                                fontSize: 'var(--fs-11)',
                                fontWeight: 600,
                                whiteSpace: 'nowrap',
                              }}
                            >
                              ${meta.label}
                            </span>
                          `
                        })}
                      </span>

                      <span class="mono tnum" style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-12)' }}>
                        <span style=${{ color: 'var(--fg-2)', fontWeight: 600 }}>
                          ${group.restingCount}/${group.totalInProvider} 중지
                        </span>
                        <span style=${{ color: rel.isSoon ? 'var(--ok-fg)' : 'var(--fg-2)' }}>
                          ${rel.isSoon ? `곧 해제 · ${rel.countdown}` : rel.countdown}${rel.localTime ? ` (${rel.localTime})` : ''}
                        </span>
                        ${showEstimated && html`
                          <span
                            title="제공자가 정확한 리셋 시각을 명시하지 않아 서버 재시도 예정 시각을 표시합니다."
                            style=${{
                              padding: 'var(--sp-0) var(--sp-1)',
                              borderRadius: 'var(--radius-sm)',
                              border: '1px solid var(--line-2)',
                              background: 'var(--bg-2)',
                              color: 'var(--fg-3)',
                              fontSize: 'var(--fs-11)',
                            }}
                          >
                            예상
                          </span>
                        `}
                      </span>
                    </button>

                    ${isOpen && html`
                      <div
                        data-testid=${`paused-group-body-${group.provider}`}
                        style=${{
                          display: 'flex',
                          flexDirection: 'column',
                          gap: 'var(--sp-1)',
                          padding: 'var(--sp-2) var(--sp-3)',
                          borderTop: '1px solid var(--line-1)',
                          borderBottomLeftRadius: 'var(--radius-sm)',
                          borderBottomRightRadius: 'var(--radius-sm)',
                          background: 'var(--bg-2)',
                        }}
                      >
                        ${group.runtimes.map((rt) => {
                          const rMeta = quotaRestCauseMeta(rt.quota_rest.cause)
                          const rRel = formatReleaseSummary(rt.quota_rest.until, rt.quota_rest.reset_stated, nowUnix)
                          const shortId = stripProviderPrefix(rt.id, group.provider)
                          return html`
                            <div
                              key=${rt.id}
                              style=${{
                                display: 'flex',
                                alignItems: 'center',
                                justifyContent: 'space-between',
                                gap: 'var(--sp-2)',
                                flexWrap: 'wrap',
                                padding: 'var(--sp-1) var(--sp-2)',
                                borderRadius: 'var(--radius-sm)',
                                background: 'var(--bg-1)',
                                border: '1px solid var(--line-1)',
                              }}
                            >
                              <span style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', minWidth: 0 }}>
                                <span style=${{ fontWeight: 600, fontSize: 'var(--fs-12)' }}>${rt.model || shortId}</span>
                                <span class="mono" title=${rt.id} style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                                  ${shortId}
                                </span>
                                ${rt.is_default && html`
                                  <span style=${{ padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-pill)', background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)', fontSize: 'var(--fs-11)', fontWeight: 600 }}>
                                    기본
                                  </span>
                                `}
                              </span>
                              <span class="mono tnum" style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-11)' }}>
                                <span style=${{ ...causeBadgeStyle(rMeta.tone), padding: 'var(--sp-0) var(--sp-2)', borderRadius: 'var(--radius-pill)', fontWeight: 600 }}>
                                  ${rMeta.shortLabel}
                                </span>
                                <span style=${{ color: rRel.isSoon ? 'var(--ok-fg)' : 'var(--fg-2)' }}>
                                  ${rRel.countdown}${rRel.localTime ? ` (${rRel.localTime})` : ''}
                                </span>
                                ${rRel.isEstimated && html`
                                  <span style=${{ padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-sm)', border: '1px solid var(--line-2)', background: 'var(--bg-2)', color: 'var(--fg-3)' }}>
                                    예상
                                  </span>
                                `}
                              </span>
                            </div>
                          `
                        })}

                        <div style=${{ display: 'flex', justifyContent: 'flex-end', gap: 'var(--sp-2)', paddingTop: 'var(--sp-1)', flexWrap: 'wrap' }}>
                          ${canManageProviders && !adminLocked && html`
                            <button
                              type="button"
                              class="btn-ghost"
                              style=${{ padding: 'var(--sp-0) var(--sp-2)', fontSize: 'var(--fs-11)' }}
                              onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(group.provider)}`)}
                            >
                              설정 열기
                            </button>
                          `}
                          ${canManageProviders && hasPayment && html`
                            <button
                              type="button"
                              class="btn-primary"
                              style=${{ padding: 'var(--sp-0) var(--sp-2)', fontSize: 'var(--fs-11)' }}
                              onClick=${() => setCredForm({ providerId: group.provider, secret: '', mode: 'api_key' })}
                            >
                              API 키 등록
                            </button>
                          `}
                        </div>
                      </div>
                    `}
                  </div>
                `
              })}
            </div>
          `}
        </section>
      `}

      <${RuntimeLivenessPanel} runtimes=${resolvedData?.runtimes ?? []} nowUnix=${nowUnix} />

      <!-- Provider Usage History UPlotChart (Strictly days=1|7|14 & HTTP 200 unavailable honesty) -->
      <section aria-label="제공자 사용량 이력">
        ${!isSingleUserLocal && html`
          <div class="wka-card dtable-absent" data-testid="provider-usage-mode-notice" role="status">
            제공자 사용량 이력 시계열은 single_user 모드에서 제공됩니다.
          </div>
        `}
        ${isSingleUserLocal && historyState.kind === 'loading' && html`
          <div class="wka-card dtable-absent">사용량 이력 불러오는 중… (${providerDays}d)</div>
        `}
        ${isSingleUserLocal && historyState.kind === 'failed' && html`
          <div class="ap-error" role="alert">사용량 이력 조회 실패: ${historyState.message}</div>
        `}
        ${isSingleUserLocal && historyState.kind === 'unavailable' && html`
          <div
            class="wka-card"
            data-testid="provider-usage-unavailable"
            role="status"
            style=${{ borderColor: 'var(--warn-border)', background: 'var(--warn-soft)' }}
          >
            <div style=${{ fontWeight: 600, color: 'var(--warn-fg)', marginBottom: 'var(--sp-1)' }}>
              ⚠ 제공자 사용량 이력 사용 불가 (state: unavailable)
            </div>
            <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
              사유: <span class="mono">${historyState.reason}</span>
            </div>
          </div>
        `}
        ${isSingleUserLocal && historyState.kind === 'ready' && html`
          <${UPlotChart}
            id="runtime-quotas-history"
            title=${`제공자 사용량 이력 & 일시 중지 추이 (${historyState.days}일 · ${historyState.pointsCount}포인트)`}
            subtitle=${historyState.unreadable > 0 || historyState.undecodable > 0
              ? html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--warn-fg)' }}>${[
                  historyState.unreadable > 0 ? `판독 불가 보고서 ${historyState.unreadable}건` : null,
                  historyState.undecodable > 0 ? `읽지 못한 포인트 ${historyState.undecodable}건 (차트에서 빠짐)` : null,
                ].filter((part) => part !== null).join(' · ')}</span>`
              : html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>days=${providerDays}</span>`}
            data=${historyState.data}
            series=${HISTORY_SERIES}
            height=${210}
            emptyLabel="선택한 기간에 기록된 제공자 사용량 이력이 없습니다."
          />
        `}
      </section>

      <!-- Quota Scope Filter / Sort / Search & Grouped Cards -->
      <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }} aria-label="제공자별 할당량 현황">
        ${resolvedObs.kind === 'loading' && html`
          <div class="wka-card dtable-absent">런타임 할당량 불러오는 중…</div>
        `}
        ${resolvedObs.kind === 'failed' && html`
          <div class="ap-error" role="alert">런타임 할당량 조회 오류: ${resolvedObs.error.message}</div>
        `}

        ${resolvedObs.kind === 'value' && totalScopes === 0 && html`
          <div class="wka-card dtable-absent">보고된 제공자 할당량 스코프가 없습니다.</div>
        `}

        ${resolvedObs.kind === 'value' && totalScopes > 0 && html`
          <div
            class="wka-card"
            data-testid="quota-scope-controls"
            style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap', padding: 'var(--sp-2) var(--sp-3)' }}
          >
            <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)', flexWrap: 'wrap' }} role="group" aria-label="할당량 상태 필터">
              ${([
                { id: 'all', label: `전체 (${filterCounts.all})` },
                { id: 'attention', label: `주의 필요 (${filterCounts.attention})` },
                { id: 'healthy_sub', label: `정상 구독 (${filterCounts.healthy_sub})` },
                { id: 'resting', label: `429·휴식 (${filterCounts.resting})` },
                { id: 'unreported', label: `미보고 (${filterCounts.unreported})` },
              ] as const).map((pill) => {
                const active = scopeFilter === pill.id
                return html`
                  <button
                    key=${pill.id}
                    type="button"
                    class=${active ? 'btn-primary' : 'btn-ghost'}
                    data-testid=${`quota-filter-${pill.id}`}
                    aria-pressed=${active}
                    style=${{ padding: '4px 10px', fontSize: 'var(--fs-11)' }}
                    onClick=${() => setScopeFilter(pill.id)}
                  >
                    ${pill.label}
                  </button>
                `
              })}
            </div>

            <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
              <input
                type="search"
                data-testid="quota-search-input"
                aria-label="제공자 또는 계정 검색"
                placeholder="제공자·계정·Keeper 검색…"
                value=${scopeQuery}
                onInput=${(e: Event) => setScopeQuery((e.target as HTMLInputElement).value)}
                style=${{
                  padding: '4px 8px',
                  fontSize: 'var(--fs-11)',
                  background: 'var(--input-bg)',
                  border: '1px solid var(--input-border)',
                  borderRadius: 'var(--radius-sm)',
                  color: 'var(--fg-1)',
                  minWidth: '170px',
                }}
              />
              <select
                data-testid="quota-sort-select"
                aria-label="할당량 정렬"
                value=${scopeSort}
                onChange=${(e: Event) => setScopeSort((e.target as HTMLSelectElement).value as QuotaScopeSort)}
                style=${{
                  padding: '4px 8px',
                  fontSize: 'var(--fs-11)',
                  background: 'var(--input-bg)',
                  border: '1px solid var(--input-border)',
                  borderRadius: 'var(--radius-sm)',
                  color: 'var(--fg-1)',
                }}
              >
                ${QUOTA_SORT_OPTIONS.map((opt) => html`
                  <option key=${opt.value} value=${opt.value}>${opt.label}</option>
                `)}
              </select>
              ${hasActiveScopeControl && html`
                <button
                  type="button"
                  class="btn-ghost"
                  data-testid="quota-controls-reset"
                  style=${{ padding: '4px 8px', fontSize: 'var(--fs-11)' }}
                  onClick=${() => {
                    setScopeFilter('all')
                    setScopeSort('default')
                    setScopeQuery('')
                  }}
                >
                  초기화
                </button>
              `}
            </div>
          </div>
        `}

        ${hasActiveScopeControl
          ? html`
              <div data-testid="quota-filtered-list">
                <div class="mono tnum" style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-3)', marginBottom: 'var(--sp-2)' }}>
                  ${filteredSortedScopes.length} / ${totalScopes}개 표시
                </div>
                ${filteredSortedScopes.length === 0
                  ? html`<div class="wka-card dtable-absent">조건에 맞는 제공자 할당량 스코프가 없습니다.</div>`
                  : html`
                      <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
                        ${filteredSortedScopes.map(renderScopeCard)}
                      </div>
                    `}
              </div>
            `
          : html`
              ${groupedScopes.attention.length > 0 && html`
                <div data-testid="quota-tier-1">
                  <h2 style=${{ margin: '0 0 var(--sp-2)', fontSize: 'var(--fs-13)', color: 'var(--err-fg)' }}>
                    주의 필요 · 소진 / 크레딧 잔액 / 고사용률 (${groupedScopes.attention.length})
                  </h2>
                  <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
                    ${groupedScopes.attention.map(renderScopeCard)}
                  </div>
                </div>
              `}

              ${groupedScopes.healthySub.length > 0 && html`
                <div data-testid="quota-tier-2">
                  <h2 style=${{ margin: '0 0 var(--sp-2)', fontSize: 'var(--fs-13)', color: 'var(--ok-fg)' }}>
                    정상 활성 구독 ($0 Sub · ${groupedScopes.healthySub.length})
                  </h2>
                  <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
                    ${groupedScopes.healthySub.map(renderScopeCard)}
                  </div>
                </div>
              `}

              ${groupedScopes.unreported.length > 0 && html`
                <div data-testid="quota-tier-3">
                  <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 'var(--sp-2)' }}>
                    <h2 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-3)' }}>
                      사용량 미보고 (? Unreported · ${groupedScopes.unreported.length})
                    </h2>
                    <button
                      type="button"
                      class="btn-ghost"
                      aria-expanded=${tier3Expanded}
                      onClick=${() => setTier3Expanded((v) => !v)}
                    >
                      ${tier3Expanded ? '미보고 접기' : `미보고 ${groupedScopes.unreported.length}개 펼치기`}
                    </button>
                  </div>
                  ${tier3Expanded && html`
                    <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
                      ${groupedScopes.unreported.map(renderScopeCard)}
                    </div>
                  `}
                </div>
              `}
            `}
      </section>

      <!-- Inline Credential Form & CLI OAuth Receipt -->
      ${canManageProviders && credForm && html`
        <form class="wka-card" onSubmit=${handleSaveCredential} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', borderColor: 'var(--line-2)' }}>
          <div class="wka-h">
            <h3>제공자 API 키 등록 / 갱신 (${isMultiAccountSignedIn ? '개인 계정' : '워크스페이스'})</h3>
            <button type="button" class="btn-ghost" onClick=${() => setCredForm(null)}>닫기</button>
          </div>
          <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 'var(--sp-2)' }}>
            <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
              <span>제공자 ID</span>
              <input
                type="text"
                value=${credForm.providerId}
                onInput=${(e: Event) => {
                  const val = (e.target as HTMLInputElement).value
                  setCredForm((prev) => (prev ? { ...prev, providerId: val } : prev))
                }}
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                required
              />
            </label>
            <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
              <span>API 키 / 시크릿</span>
              <input
                type="password"
                autocomplete="off"
                placeholder="sk-..."
                value=${credForm.secret}
                onInput=${(e: Event) => {
                  const val = (e.target as HTMLInputElement).value
                  setCredForm((prev) => (prev ? { ...prev, secret: val } : prev))
                }}
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                required
              />
            </label>
          </div>
          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            <button type="submit" class="btn-primary" disabled=${actionBusy === 'save-cred'}>
              ${actionBusy === 'save-cred' ? '저장 중…' : '저장'}
            </button>
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => void handleStartOAuthLogin(credForm.providerId)}
              disabled=${actionBusy !== null}
            >
              CLI OAuth 로그인 시작
            </button>
          </div>
        </form>
      `}

      ${canManageProviders && loginReceipt && html`
        <section
          class="wka-card"
          data-testid="setup-login-panel"
          style=${{ borderColor: 'var(--info-border)', background: 'var(--info-soft)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}
        >
          <div class="wka-h">
            <h3>CLI OAuth 로그인 스트림 · ${loginReceipt.integrationId}</h3>
            <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
              ${loginReceipt.streaming && html`
                <button type="button" class="btn-ghost" style=${{ color: 'var(--err-fg)' }} onClick=${() => void handleCancelSetupLogin()}>
                  로그인 취소
                </button>
              `}
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => {
                  loginAbortRef.current?.abort('dismissed')
                  setLoginReceipt(null)
                }}
              >
                닫기
              </button>
            </div>
          </div>

          <div class="mono" style=${{ fontSize: 'var(--fs-12)', display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-3)' }}>
            <span>login_id: ${loginReceipt.loginId || '연결 중…'}</span>
            <span>상태: ${loginReceipt.status}${loginReceipt.streaming ? ' (SSE 실시간)' : ''}</span>
            ${loginReceipt.authentication && html`<span>인증: ${loginReceipt.authentication}</span>`}
            ${loginReceipt.accountRef && html`<span>ref: ${loginReceipt.accountRef.slice(0, 12)}…</span>`}
          </div>

          ${(loginReceipt.authUrl || loginReceipt.deviceCode) && html`
            <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-1)', border: '1px solid var(--line-2)' }}>
              ${loginReceipt.authUrl && html`
                <a
                  href=${loginReceipt.authUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn-primary"
                  data-testid="setup-login-auth-url"
                >
                  OAuth 인증 페이지 열기 ↗
                </a>
              `}
              ${loginReceipt.deviceCode && html`
                <span class="mono" data-testid="setup-login-device-code" style=${{ padding: 'var(--sp-1) var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--brass-soft)', color: 'var(--brass-1)', fontWeight: 700, fontSize: 'var(--fs-13)' }}>
                  ${loginReceipt.deviceCode}
                </span>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => {
                    const code = loginReceipt.deviceCode ?? ''
                    void copyToClipboard(code).then((copied) => {
                      if (!mountedRef.current) return
                      if (copied) {
                        setCopiedDeviceCode(true)
                      } else {
                        setActionBanner({ kind: 'err', text: '클립보드 복사에 실패했습니다. 코드를 직접 선택해 복사하세요.' })
                      }
                    })
                  }}
                >
                  ${copiedDeviceCode ? '복사됨 ✓' : '코드 복사'}
                </button>
              `}
              ${loginReceipt.popupBlocked && html`
                <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--warn-fg)' }}>
                  브라우저 팝업이 차단되었습니다 — 위 버튼을 직접 클릭하세요.
                </span>
              `}
            </div>
          `}

          ${loginReceipt.inputReady && loginReceipt.loginId && html`
            <form
              data-testid="setup-login-input-form"
              onSubmit=${handleSubmitLoginInput}
              style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap', alignItems: 'center' }}
            >
              <input
                type="text"
                aria-label="CLI 로그인 응답 입력"
                placeholder="인증 코드 또는 응답을 입력하세요…"
                value=${loginInputText}
                onInput=${(e: Event) => setLoginInputText((e.target as HTMLInputElement).value)}
                class="mono"
                style=${{ flex: '1 1 220px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
              />
              <button type="submit" class="btn-primary" disabled=${actionBusy === 'login-input' || !loginInputText.trim()}>
                응답 전송
              </button>
              <button type="button" class="btn-ghost" disabled=${actionBusy === 'login-input'} onClick=${() => void handleSendLoginEnterKey()}>
                Enter 전송
              </button>
            </form>
          `}

          ${loginReceipt.outputTail && html`
            <details>
              <summary style=${{ cursor: 'pointer', fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>CLI 로그인 출력 로그</summary>
              <pre class="mono" style=${{ margin: 'var(--sp-1) 0 0', padding: 'var(--sp-2)', background: 'var(--bg-0)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--fs-11)', maxHeight: '180px', overflow: 'auto', whiteSpace: 'pre-wrap' }}>
                ${loginReceipt.outputTail}
              </pre>
            </details>
          `}

          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            ${loginReceipt.loginId && html`
              <${RefreshButton} label="영수증 상태 새로고침" onRefresh=${handleRefreshLoginReceipt} />
            `}
            ${isMultiAccountSignedIn && loginReceipt.accountRef && html`
              <button
                type="button"
                class="btn-primary"
                onClick=${() => void handleVerifyAccount(loginReceipt.integrationId, loginReceipt.accountRef ?? undefined)}
              >
                계정 검증
              </button>
            `}
          </div>
        </section>
      `}

      <!-- Provider Credentials & OAuth Inventory (default-collapsed via .ap-disclosure) -->
      <section class="ap-disclosure" data-testid="provider-inventory-disclosure" aria-label="제공자 자격 증명 목록">
        <button
          type="button"
          class="ap-disclosure-trigger"
          data-testid="provider-inventory-toggle"
          aria-expanded=${inventoryOpen}
          onClick=${() => setInventoryOpen((v) => !v)}
        >
          <span>
            ${isMultiAccountSignedIn
              ? `내 제공자 계정 (${multiAccounts.length}개 계정)`
              : `제공자 연동 & 자격 증명 (${integrations.length}개 제공자 · 활성 ${enabledIntegrationsCount})`}
          </span>
          <span aria-hidden="true">${inventoryOpen ? '▾' : '▸'}</span>
        </button>

        ${inventoryOpen && html`
          <div class="ap-disclosure-body" data-testid="provider-inventory-body">
            ${inventoryObs.kind === 'failed' && html`
              <div class="ap-error" role="alert">제공자 자격 증명 조회 실패: ${inventoryObs.error.message}</div>
            `}
            ${isMultiAccountSignedIn && personIntegObs.kind === 'failed' && html`
              <div class="ap-error" role="alert">제공자 연동 목록 조회 실패: ${personIntegObs.error.message}</div>
            `}
            ${isMultiAccountSignedIn && html`
              <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                <label style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>검증용 모델 (선택 시 우선 적용):</label>
                <input
                  type="text"
                  aria-label="검증할 모델 ID"
                  placeholder="예: gpt-5-codex (비우면 통합 기본 모델)"
                  value=${verifyModelInput}
                  onInput=${(e: Event) => setVerifyModelInput((e.target as HTMLInputElement).value)}
                  class="mono"
                  style=${{ flex: '1 1 200px', minWidth: 0, minHeight: 'var(--btn-h, 32px)', padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--fs-12)' }}
                />
              </div>
            `}

            ${isMultiAccountSignedIn
              ? (multiAccounts.length === 0
                ? (inventoryObs.kind === 'failed'
                  ? null
                  : html`<div class="dtable-absent">${inventoryObs.kind === 'loading' ? '불러오는 중…' : '연결된 개인 제공자 계정이 없습니다.'}</div>`)
                : html`
                    <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
                      ${multiAccounts.map((acc, i) => {
                        const pid = acc.integration_id ?? acc.provider ?? acc.provider_account_id ?? acc.id ?? `acct-${i}`
                        const ref = acc.provider_account_id ?? acc.account_ref ?? acc.id ?? pid
                        const statusLabel = acc.removal
                          ? `removal:${acc.removal}`
                          : acc.replacement
                            ? `replacement:${acc.replacement}`
                            : acc.key
                              ? `${acc.kind ?? 'key'} (${acc.key})`
                              : (acc.status ?? (acc.kind === 'login' ? 'login' : acc.verified ? 'verified' : 'active'))
                        return html`
                          <div key=${ref} style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', padding: 'var(--sp-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)', flexWrap: 'wrap' }}>
                            <div>
                              <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${acc.display_name ?? acc.label ?? pid}</div>
                              <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                                ${ref} · ${statusLabel}
                              </div>
                            </div>
                            <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
                              <button type="button" class="btn-ghost" onClick=${() => void handleVerifyAccount(pid, acc.provider_account_id ?? acc.account_ref)}>검증</button>
                              <button type="button" class="btn-ghost" onClick=${() => void handleStartOAuthLogin(pid)}>Re-auth</button>
                              ${acc.kind !== 'login' && html`
                                <button type="button" class="btn-ghost" onClick=${() => void handleRemoveKey(ref)} style=${{ color: 'var(--err-fg)' }}>제거</button>
                              `}
                            </div>
                          </div>
                        `
                      })}
                    </div>
                  `)
              : isSingleUserLocal
                ? adminLocked
                  ? html`<div class="dtable-absent" data-testid="provider-inventory-admin-locked" role="status">워크스페이스 제공자 자격 증명 관리는 관리자 전용입니다.</div>`
                  : (integrations.length === 0
                  ? (inventoryObs.kind === 'failed'
                    ? null
                    : html`<div class="dtable-absent">${inventoryObs.kind === 'loading' ? '불러오는 중…' : '등록된 제공자 인벤토리가 없습니다.'}</div>`)
                  : html`
                      <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(290px, 1fr))', gap: 'var(--sp-2)' }}>
                        ${integrations.map((integ) => html`
                          <div key=${integ.id} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', padding: 'var(--sp-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)' }}>
                            <div style=${{ display: 'flex', justifyContent: 'space-between', gap: 'var(--sp-2)' }}>
                              <div>
                                <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${integ.display_name}</div>
                                <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                                  ${integ.id} · ${integ.credential_kind ?? integ.protocol ?? '없음'}
                                </div>
                                ${accountLine(accountEmails.get(integ.id)) !== null && html`
                                  <div data-testid="provider-account-line" class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
                                    ${accountLine(accountEmails.get(integ.id))}
                                  </div>
                                `}
                              </div>
                              <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: integ.enabled === false ? 'var(--fg-4)' : 'var(--ok-fg)' }}>
                                ${integ.enabled === false ? '비활성' : '활성'}
                              </span>
                            </div>
                            <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
                              <button type="button" class="btn-ghost" onClick=${() => setCredForm({ providerId: integ.id, secret: '', mode: 'api_key' })}>
                                API 키
                              </button>
                              <button type="button" class="btn-ghost" onClick=${() => void handleStartOAuthLogin(integ.id)}>
                                CLI OAuth
                              </button>
                              ${!adminLocked && html`
                                <button type="button" class="btn-ghost" onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(integ.id)}`)}>
                                  Open Config Key
                                </button>
                              `}
                            </div>
                          </div>
                        `)}
                      </div>
                    `)
                : html`<div class="dtable-absent">로그인된 세션에서만 제공자 자격 증명을 관리할 수 있습니다.</div>`}
          </div>
        `}
      </section>
    </div>
  `
}

// Re-export helpers for targeted verification tests
export type { Observed as QuotaObserved }
export { formatUnixTime }
