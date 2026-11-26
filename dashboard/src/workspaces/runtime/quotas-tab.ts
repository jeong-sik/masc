/**
 * Runtime L1 Tab 1: Quotas & Rate Limits
 *
 * - 3-Tier Quota Partition matching TUI #6:
 *   Tier 1: Exhausted / Credits / 429 Resting -> Tier 2: Active Subscriptions ($0 Sub honesty)
 *   -> Tier 3: Collapsed Unreported (? Unreported honesty).
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
  cancelSetupLogin,
  currentAccountMode,
  resourceCache,
  sendSetupLoginInput,
  streamSetupAccountLogin,
  timeWindow,
  timeWindowProviderDays,
  type Observed,
} from '../../core'
import { UPlotChart, type UPlotSeriesSpec } from '../../components/primitives'
import {
  formatReleaseSummary,
  groupRestingRuntimes,
  quotaRestCauseMeta,
  stripProviderPrefix,
  type QuotaRestCauseFilter,
  type QuotaRestSortKey,
} from './quota-rest-groups'
import {
  classifyQuotaScope,
  formatResetCountdown,
  formatUnixTime,
  maxUtilizationPct,
  partitionQuotaScopes,
  windowKindLabel,
  type MultiAccountIntegration,
  type MultiAccountIntegrationsResponse,
  type MultiAccountProviderAccount,
  type MultiAccountProviderAccountsResponse,
  type ProviderUsageHistoryPoint,
  type ProviderUsageHistoryResponse,
  type ProviderUsageScope,
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
    let exhausted = false

    if (pt.unit === 'fraction' && typeof pt.value === 'number') {
      pct = Math.min(100, Math.max(0, pt.value * 100))
      if (pt.value >= 0.99) exhausted = true
    } else if (pt.unit === 'percent' && typeof pt.value === 'number') {
      pct = Math.min(100, Math.max(0, pt.value))
      if (pt.value >= 99) exhausted = true
    } else if (pt.unit === 'usd' && typeof pt.value === 'number' && pt.limit && pt.limit > 0) {
      pct = Math.min(100, Math.max(0, (pt.value / pt.limit) * 100))
      if (pt.value >= pt.limit) exhausted = true
    } else if (pt.unit === 'credit_balance' && typeof pt.remaining === 'number') {
      if (pt.remaining <= 0) exhausted = true
      if (pt.total && pt.total > 0) {
        pct = Math.min(100, Math.max(0, ((pt.total - pt.remaining) / pt.total) * 100))
      }
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

function scopeDisplayName(scope: ProviderUsageScope): string {
  if (scope.providers.length > 0) {
    return scope.providers.map((p) => p.display_name || p.id).join(' · ')
  }
  return scope.scope_id || scope.scope
}

/** The account line under a provider: its login email and the plan labels
 *  the client reports, or why the login file was not read. */
export function accountLine(row: SetupAccountEmail | undefined): string | null {
  if (row === undefined) return null
  if (row.state === 'not_read') return `계정 미확인 (${row.cause})`
  return [row.email, ...(row.plan ?? [])].join(' · ')
}

function primaryProviderId(scope: ProviderUsageScope): string {
  return scope.providers[0]?.id ?? scope.scope_id ?? scope.scope
}

function costBadgeStyle(kind: ReturnType<typeof classifyQuotaScope>['kind']) {
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

function causeBadgeStyle(tone: 'warn' | 'bad') {
  return tone === 'bad'
    ? { background: 'var(--err-soft)', border: '1px solid var(--err-border)', color: 'var(--err-fg)' }
    : { background: 'var(--warn-soft)', border: '1px solid var(--warn-border)', color: 'var(--warn-fg)' }
}

const KNOWN_CAUSE_FILTERS: readonly RuntimeQuotaRest['cause'][] = [
  'payment_refused',
  'provider_quota_refused',
  'usage_read',
]

export function QuotasTab(props: WorkspaceViewProps) {
  const win = timeWindow.value
  const providerDays = timeWindowProviderDays(win)
  const accountMode = currentAccountMode.value

  const resolvedObs = resourceCache.observe<RuntimeResolvedPayload>('runtime:resolved').value
  const historyKey = `runtime:provider-usage-history:${providerDays}`
  const historyObs = resourceCache.observe<ProviderUsageHistoryResponse>(historyKey).value
  const inventoryKey = accountMode === 'multi_account' ? 'runtime:auth-provider-accounts' : 'runtime:setup-inventory'
  const inventoryObs = resourceCache.observe<SetupInventoryPayload | MultiAccountProviderAccountsResponse>(inventoryKey).value
  const personIntegObs = resourceCache.observe<MultiAccountIntegrationsResponse>('runtime:auth-integrations').value

  const [tier3Expanded, setTier3Expanded] = useState(false)
  const [pausedPanelOpen, setPausedPanelOpen] = useState(true)
  const [pausedSortBy, setPausedSortBy] = useState<QuotaRestSortKey>('release')
  const [pausedCauseFilter, setPausedCauseFilter] = useState<QuotaRestCauseFilter>('all')
  const [expandedGroups, setExpandedGroups] = useState<ReadonlySet<string>>(() => new Set())
  const [credForm, setCredForm] = useState<CredentialFormState | null>(null)
  const [verifyModelInput, setVerifyModelInput] = useState<string>('')
  const [loginReceipt, setLoginReceipt] = useState<LoginReceiptState | null>(null)
  const [actionBusy, setActionBusy] = useState<string | null>(null)
  const [actionBanner, setActionBanner] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [sourceRevision, setSourceRevision] = useState<string>('')

  const loadAll = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<RuntimeResolvedPayload>(
      'runtime:resolved',
      (signal) => apiGet<RuntimeResolvedPayload>('/api/v1/runtime/resolved', { signal }),
      { ttlMs: 15_000, topics: ['runtime', 'provider_usage', 'config'], reason },
    )
    void resourceCache.fetch<ProviderUsageHistoryResponse>(
      historyKey,
      (signal) => apiGet<ProviderUsageHistoryResponse>(
        `/api/v1/dashboard/provider-usage-history?days=${providerDays}`,
        { signal },
      ),
      { ttlMs: 30_000, topics: ['provider_usage'], reason },
    )

    if (accountMode === 'multi_account') {
      void resourceCache.fetch<MultiAccountProviderAccountsResponse>(
        'runtime:auth-provider-accounts',
        (signal) => apiGet<MultiAccountProviderAccountsResponse>('/api/v1/auth/provider-accounts', { signal }),
        { ttlMs: 20_000, topics: ['provider_accounts'], reason },
      )
      void resourceCache.fetch<MultiAccountIntegrationsResponse>(
        'runtime:auth-integrations',
        (signal) => apiGet<MultiAccountIntegrationsResponse>('/api/v1/auth/integrations', { signal }),
        { ttlMs: 30_000, topics: ['provider_accounts', 'config'], reason },
      )
    } else {
      void resourceCache.fetch<SetupInventoryPayload>(
        'runtime:setup-inventory',
        (signal) => apiGet<SetupInventoryPayload>('/api/v1/setup/inventory', { signal }),
        { ttlMs: 20_000, topics: ['setup_inventory', 'config'], reason },
      )
      void apiGet<{ readonly source_revision?: string }>('/api/v1/runtime/config/raw').then((res) => {
        if (res.ok && typeof res.value.source_revision === 'string' && res.value.source_revision.trim().length > 0) {
          setSourceRevision(res.value.source_revision.trim())
        }
      })
    }
  }

  useEffect(() => {
    loadAll('mount')
  }, [providerDays, accountMode])

  const resolvedData = resolvedObs.kind === 'value' ? resolvedObs.data : null
  const restingProviders = useMemo(() => {
    const set = new Set<string>()
    if (resolvedData) {
      for (const rt of resolvedData.runtimes) {
        if (rt.quota_rest !== null) set.add(rt.provider)
      }
    }
    return set
  }, [resolvedData])

  const partitioned = useMemo(
    () => partitionQuotaScopes(resolvedData?.provider_usage_windows ?? [], restingProviders),
    [resolvedData, restingProviders],
  )

  const accountEmails = useMemo(
    () => new Map<string, SetupAccountEmail>(
      inventoryObs.kind === 'value' && 'account_emails' in inventoryObs.data && Array.isArray(inventoryObs.data.account_emails)
        ? inventoryObs.data.account_emails.map((row) => [row.integration_id, row] as const)
        : [],
    ),
    [inventoryObs],
  )

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
    | { kind: 'ready'; data: uPlot.AlignedData; pointsCount: number; unreadable: number; days: number } => {
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
    }),
    [resolvedData, providerDisplayNames, accountEmails, pausedSortBy],
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
        })),
    [basePausedGrouped, effectiveCauseFilter, resolvedData, providerDisplayNames, accountEmails, pausedSortBy],
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
    if (integ && integ.models[0]) return integ.models[0]
    const rt = resolvedData?.runtimes.find((r) => r.provider === integrationId && r.model)
    return rt?.model ?? ''
  }

  const handleSaveCredential = async (ev: Event) => {
    ev.preventDefault()
    if (!credForm || !credForm.providerId.trim() || !credForm.secret.trim()) return
    setActionBusy('save-cred')
    setActionBanner(null)

    if (accountMode === 'multi_account') {
      // Exact wire shape: lib/server/server_key_account.ml:133-137 requires { integration_id, key }
      const res = await apiMutate<unknown>('POST', '/api/v1/setup/accounts/key', {
        integration_id: credForm.providerId.trim(),
        key: credForm.secret.trim(),
      })
      setActionBusy(null)
      if (!res.ok) {
        setActionBanner({ kind: 'err', text: `키 저장 실패: ${res.error.message}` })
        return
      }
      setActionBanner({ kind: 'ok', text: `${credForm.providerId} 개인 API 키가 등록되었습니다.` })
      setCredForm(null)
      loadAll('manual')
      return
    }

    // Single-user CAS precondition: require real source_revision from /api/v1/runtime/config/raw (never 'latest'!)
    let rev = sourceRevision.trim()
    if (!rev) {
      const rawRes = await apiGet<{ readonly source_revision?: string }>('/api/v1/runtime/config/raw')
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
      provider_id: credForm.providerId.trim(),
      secret: credForm.secret.trim(),
      source_revision: rev,
    })
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `키 저장 실패: ${res.error.message}` })
      return
    }
    setActionBanner({ kind: 'ok', text: `${credForm.providerId} 자격 증명이 저장되었습니다.` })
    setCredForm(null)
    loadAll('manual')
  }

  const loginAbortRef = useRef<AbortController | null>(null)
  const openedLoginUrlRef = useRef<string | null>(null)
  const [loginInputText, setLoginInputText] = useState('')
  const [copiedDeviceCode, setCopiedDeviceCode] = useState(false)

  useEffect(() => () => {
    loginAbortRef.current?.abort('unmount')
  }, [])

  const handleStartOAuthLogin = async (integrationId: string) => {
    loginAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    loginAbortRef.current = ctrl
    openedLoginUrlRef.current = null
    setLoginInputText('')
    setCopiedDeviceCode(false)
    setActionBusy(`login:${integrationId}`)
    setActionBanner(null)

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
          setLoginReceipt((cur) => (cur ? { ...cur, outputTail: `${cur.outputTail ?? ''}${text}`.slice(-2000) } : cur))
        },
        onScreen: (text) => {
          setLoginReceipt((cur) => (cur ? { ...cur, outputTail: text.slice(-2000) } : cur))
        },
        onAuthUrl: (url) => {
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
          setLoginReceipt((cur) => (cur ? { ...cur, deviceCode: code } : cur))
        },
        onInputReady: () => {
          setLoginReceipt((cur) => (cur ? { ...cur, inputReady: true } : cur))
        },
        onComplete: (receipt) => {
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
          setActionBanner({ kind: 'ok', text: `${integrationId} CLI OAuth 로그인이 완료되었습니다.` })
          loadAll('manual')
          const ref = receipt.accountRef
          // POST /api/v1/setup/accounts/verify is only mounted in multi_account mode (server_login_http.mli:79)
          if (accountMode === 'multi_account' && ref && resolveModelForIntegration(integrationId)) {
            void handleVerifyAccount(integrationId, ref)
          }
        },
        onError: (message, receipt) => {
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

    if (loginAbortRef.current === ctrl) {
      setActionBusy((cur) => (cur === `login:${integrationId}` ? null : cur))
      setLoginReceipt((cur) => (cur ? { ...cur, streaming: false } : cur))
    }
  }

  const handleSubmitLoginInput = async (ev: Event) => {
    ev.preventDefault()
    if (!loginReceipt?.loginId || !loginInputText.trim()) return
    const text = loginInputText.trim()
    setActionBusy('login-input')
    const res = await sendSetupLoginInput(loginReceipt.loginId, { kind: 'text', text })
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `CLI 입력 전송 실패: ${res.error.message}` })
      return
    }
    setLoginInputText('')
    setLoginReceipt((cur) => (cur ? { ...cur, inputReady: false } : cur))
  }

  const handleSendLoginEnterKey = async () => {
    if (!loginReceipt?.loginId) return
    setActionBusy('login-input')
    const res = await sendSetupLoginInput(loginReceipt.loginId, { kind: 'key', key: 'enter' })
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `Enter 키 전송 실패: ${res.error.message}` })
      return
    }
    setLoginReceipt((cur) => (cur ? { ...cur, inputReady: false } : cur))
  }

  const handleCancelSetupLogin = async () => {
    const owner = loginAbortRef.current
    if (loginReceipt?.loginId) {
      await cancelSetupLogin(loginReceipt.loginId)
    }
    if (loginAbortRef.current !== owner) return
    owner?.abort('cancelled')
    setLoginReceipt((cur) => (cur ? { ...cur, status: 'cancelled', streaming: false, inputReady: false } : cur))
  }

  const handleRefreshLoginReceipt = async () => {
    if (!loginReceipt) return
    setActionBusy('receipt')
    const res = await apiGet<Record<string, unknown>>(
      `/api/v1/setup/accounts/login/${encodeURIComponent(loginReceipt.loginId)}`,
    )
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `로그인 영수증 조회 실패: ${res.error.message}` })
      return
    }
    setLoginReceipt({
      ...loginReceipt,
      status: typeof res.value.status === 'string' ? res.value.status : loginReceipt.status,
      accountRef: typeof res.value.account_ref === 'string' ? res.value.account_ref : loginReceipt.accountRef,
      authentication: typeof res.value.authentication === 'string' ? res.value.authentication : loginReceipt.authentication,
    })
  }

  const handleVerifyAccount = async (providerId: string, providerAccountId?: string) => {
    if (accountMode !== 'multi_account') {
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
    setActionBusy(`verify:${acctId}`)
    setActionBanner(null)
    // Exact wire shape: lib/server/server_setup_account_login.ml:424-432 requires { provider_account_id, model }
    const res = await apiMutate<unknown>('POST', '/api/v1/setup/accounts/verify', {
      provider_account_id: acctId,
      model,
    })
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `검증 실패 (${acctId}): ${res.error.message}` })
      return
    }
    setActionBanner({ kind: 'ok', text: `${acctId} (${model}) 계정 검증 완료.` })
    loadAll('manual')
  }

  const handleRemoveKey = async (id: string) => {
    setActionBusy(`remove:${id}`)
    setActionBanner(null)
    const res = await apiMutate<unknown>('DELETE', `/api/v1/setup/accounts/key/${encodeURIComponent(id)}`)
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `삭제 실패 (${id}): ${res.error.message}` })
      return
    }
    setActionBanner({ kind: 'ok', text: `${id} 자격 증명을 제거했습니다.` })
    loadAll('manual')
  }

  const renderScopeCard = (scope: ProviderUsageScope, idx: number) => {
    const cls = classifyQuotaScope(scope)
    const pct = maxUtilizationPct(scope)
    const pid = primaryProviderId(scope)
    const name = scopeDisplayName(scope)
    const accounts = scope.providers
      .map((p) => accountLine(accountEmails.get(p.id)))
      .filter((line): line is string => line !== null)
    const badgeStyle = costBadgeStyle(cls.kind)

    return html`
      <article
        key=${`${scope.scope}-${idx}`}
        class="wka-card"
        style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}
      >
        <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <div style=${{ minWidth: 0 }}>
            <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>${name}</div>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${scope.scope}</div>
            ${accounts.map((line) => html`<div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>${line}</div>`)}
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
                          ${labelVal} · 리셋 ${formatResetCountdown(w.resets_at)}
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

        <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', paddingTop: 'var(--sp-1)', borderTop: '1px solid var(--line-1)', flexWrap: 'wrap' }}>
          <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            최대 사용률: ${pct !== null ? `${pct.toFixed(1)}%` : '미보고'}
          </span>
          <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => setCredForm({ providerId: pid, secret: '', mode: 'api_key' })}
            >
              Re-auth
            </button>
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(pid)}`)}
            >
              Open Config Key
            </button>
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
  const globalSoonestRelease = pausedSummary.soonestUntil !== null
    ? formatReleaseSummary(pausedSummary.soonestUntil, pausedSummary.soonestResetStated)
    : null
  const pausedKpiTone = pausedSummary.hasPaymentRefused
    ? 'bad'
    : pausedSummary.restingCount > 0
      ? 'warn'
      : 'ok'

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
          <button type="button" class="btn-ghost" onClick=${() => loadAll('manual')}>
            새로고침
          </button>
        </div>
      </header>

      ${actionBanner && html`
        <div
          role="status"
          class=${actionBanner.kind === 'err' ? 'ap-error' : 'wka-card'}
          style=${actionBanner.kind === 'ok'
            ? { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' }
            : undefined}
        >
          ${actionBanner.text}
        </div>
      `}

      <section class="ov-kpis" aria-label="할당량 요약">
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 1 소진 / 크레딧 / 429</div>
          <div class=${`ov-kpi-v ${partitioned.tier1ExhaustedOrCredits.length > 0 ? 'bad' : 'ok'}`}>
            ${partitioned.tier1ExhaustedOrCredits.length}
          </div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 2 활성 구독 ($0 Sub)</div>
          <div class="ov-kpi-v ok">${partitioned.tier2ActiveSubscriptions.length}</div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 3 미보고 (? Unreported)</div>
          <div class="ov-kpi-v">${partitioned.tier3Unreported.length}</div>
        </div>
        <div class="ov-kpi" data-testid="kpi-paused-runtimes">
          <div class="ov-kpi-k">일시 중지 런타임</div>
          <div class=${`ov-kpi-v ${pausedKpiTone}`}>
            ${pausedSummary.totalRegistered > 0
              ? `${pausedSummary.restingCount} / ${pausedSummary.totalRegistered}`
              : String(pausedSummary.restingCount)}
          </div>
          ${pausedSummary.totalRegistered > 0 && html`
            <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', marginTop: 'var(--sp-0)' }}>
              전체 ${pausedSummary.totalRegistered} · 가용 ${pausedSummary.availableCount}
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
          <button
            type="button"
            data-testid="paused-panel-toggle"
            aria-expanded=${pausedPanelOpen}
            onClick=${() => setPausedPanelOpen((v) => !v)}
            style=${{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 'var(--sp-2)',
              flexWrap: 'wrap',
              width: '100%',
              padding: 0,
              border: 'none',
              background: 'transparent',
              color: 'var(--fg-1)',
              cursor: 'pointer',
              textAlign: 'left',
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
                      일시 중지 ${pausedSummary.restingCount}/${pausedSummary.totalRegistered} (${pausedSummary.groupCount}개 계정) · 가용 ${pausedSummary.availableCount}${globalSoonestRelease
                        ? ` · 가장 빠른 해제 ${globalSoonestRelease.countdown}${globalSoonestRelease.localTime ? ` (${globalSoonestRelease.localTime})` : ''}${globalSoonestRelease.isEstimated ? ' · 예상' : ''}`
                        : ''}
                    </span>
                  `}
            </span>
            ${pausedPanelOpen && globalSoonestRelease && html`
              <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: globalSoonestRelease.isSoon ? 'var(--ok-fg)' : 'var(--fg-2)' }}>
                가장 빠른 해제 ${globalSoonestRelease.countdown}${globalSoonestRelease.localTime ? ` (${globalSoonestRelease.localTime})` : ''}${globalSoonestRelease.isEstimated ? ' · 예상' : ''}
              </span>
            `}
          </button>

          ${pausedPanelOpen && html`
            <p style=${{ margin: 0, fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
              할당량 소진·결제 거절로 자동 우회 중인 런타임입니다. 해제 시각이 지나면 자동으로 다시 호출됩니다.
            </p>

            <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
              <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                <div class="ap-viewseg" role="group" aria-label="정렬 기준">
                  <button
                    type="button"
                    data-testid="paused-sort-release"
                    class=${`ap-viewbtn ${pausedSortBy === 'release' ? 'on' : ''}`}
                    aria-pressed=${pausedSortBy === 'release'}
                    onClick=${() => setPausedSortBy('release')}
                  >
                    해제 임박순
                  </button>
                  <button
                    type="button"
                    data-testid="paused-sort-count"
                    class=${`ap-viewbtn ${pausedSortBy === 'count' ? 'on' : ''}`}
                    aria-pressed=${pausedSortBy === 'count'}
                    onClick=${() => setPausedSortBy('count')}
                  >
                    런타임 많은순
                  </button>
                  <button
                    type="button"
                    data-testid="paused-sort-name"
                    class=${`ap-viewbtn ${pausedSortBy === 'name' ? 'on' : ''}`}
                    aria-pressed=${pausedSortBy === 'name'}
                    onClick=${() => setPausedSortBy('name')}
                  >
                    이름순
                  </button>
                </div>

                ${presentCauses.length >= 2 && html`
                  <div role="group" aria-label="일시 중지 사유 필터" style=${{ display: 'inline-flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
                    <button
                      type="button"
                      data-testid="paused-filter-all"
                      class="btn-ghost"
                      aria-pressed=${effectiveCauseFilter === 'all'}
                      onClick=${() => setPausedCauseFilter('all')}
                      style=${{
                        padding: 'var(--sp-0) var(--sp-2)',
                        fontSize: 'var(--fs-11)',
                        ...(effectiveCauseFilter === 'all'
                          ? { background: 'var(--bg-4)', borderColor: 'var(--line-2)', color: 'var(--fg-1)', fontWeight: 600 }
                          : {}),
                      }}
                    >
                      전체 (${pausedSummary.restingCount})
                    </button>
                    ${presentCauses.map((cause) => {
                      const meta = quotaRestCauseMeta(cause)
                      const count = pausedSummary.causeCounts[cause] ?? 0
                      const active = effectiveCauseFilter === cause
                      return html`
                        <button
                          key=${cause}
                          type="button"
                          data-testid=${`paused-filter-${cause}`}
                          class="btn-ghost"
                          aria-pressed=${active}
                          onClick=${() => setPausedCauseFilter(cause)}
                          style=${{
                            padding: 'var(--sp-0) var(--sp-2)',
                            fontSize: 'var(--fs-11)',
                            ...(active ? { ...causeBadgeStyle(meta.tone), fontWeight: 600 } : {}),
                          }}
                        >
                          ${meta.shortLabel} (${count})
                        </button>
                      `
                    })}
                  </div>
                `}
              </div>

              <button
                type="button"
                class="btn-ghost"
                data-testid="paused-expand-all-toggle"
                style=${{ padding: 'var(--sp-0) var(--sp-2)', fontSize: 'var(--fs-11)' }}
                onClick=${() => {
                  if (allVisibleExpanded) {
                    setExpandedGroups(new Set())
                  } else {
                    setExpandedGroups(new Set(pausedGroups.map((g) => g.provider)))
                  }
                }}
              >
                ${allVisibleExpanded ? '모두 접기' : '모두 펼치기'}
              </button>
            </div>

            <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
              ${pausedGroups.map((group) => {
                const isOpen = expandedGroups.has(group.provider)
                const rel = formatReleaseSummary(group.soonestUntil, group.soonestResetStated)
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
                      overflow: 'hidden',
                    }}
                  >
                    <button
                      type="button"
                      aria-expanded=${isOpen}
                      onClick=${() => togglePausedGroup(group.provider)}
                      style=${{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        gap: 'var(--sp-2)',
                        flexWrap: 'wrap',
                        width: '100%',
                        padding: 'var(--sp-2) var(--sp-3)',
                        border: 'none',
                        background: 'transparent',
                        color: 'var(--fg-1)',
                        cursor: 'pointer',
                        textAlign: 'left',
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
                                padding: '1px var(--sp-2)',
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
                              padding: '1px var(--sp-1)',
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
                          background: 'var(--bg-2)',
                        }}
                      >
                        ${group.runtimes.map((rt) => {
                          const rMeta = quotaRestCauseMeta(rt.quota_rest.cause)
                          const rRel = formatReleaseSummary(rt.quota_rest.until, rt.quota_rest.reset_stated)
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
                                  <span style=${{ padding: '1px var(--sp-1)', borderRadius: 'var(--radius-pill)', background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)', fontSize: 'var(--fs-11)', fontWeight: 600 }}>
                                    기본
                                  </span>
                                `}
                              </span>
                              <span class="mono tnum" style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-11)' }}>
                                <span style=${{ ...causeBadgeStyle(rMeta.tone), padding: '1px var(--sp-2)', borderRadius: 'var(--radius-pill)', fontWeight: 600 }}>
                                  ${rMeta.shortLabel}
                                </span>
                                <span style=${{ color: rRel.isSoon ? 'var(--ok-fg)' : 'var(--fg-2)' }}>
                                  ${rRel.countdown}${rRel.localTime ? ` (${rRel.localTime})` : ''}
                                </span>
                                ${rRel.isEstimated && html`
                                  <span style=${{ padding: '1px var(--sp-1)', borderRadius: 'var(--radius-sm)', border: '1px solid var(--line-2)', background: 'var(--bg-2)', color: 'var(--fg-3)' }}>
                                    예상
                                  </span>
                                `}
                              </span>
                            </div>
                          `
                        })}

                        <div style=${{ display: 'flex', justifyContent: 'flex-end', gap: 'var(--sp-2)', paddingTop: 'var(--sp-1)', flexWrap: 'wrap' }}>
                          <button
                            type="button"
                            class="btn-ghost"
                            style=${{ padding: 'var(--sp-0) var(--sp-2)', fontSize: 'var(--fs-11)' }}
                            onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(group.provider)}`)}
                          >
                            설정 열기
                          </button>
                          ${hasPayment && html`
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

      <!-- Provider Usage History UPlotChart (Strictly days=1|7|14 & HTTP 200 unavailable honesty) -->
      <section aria-label="제공자 사용량 이력">
        ${historyState.kind === 'loading' && html`
          <div class="wka-card dtable-absent">사용량 이력 불러오는 중… (${providerDays}d)</div>
        `}
        ${historyState.kind === 'failed' && html`
          <div class="ap-error" role="alert">사용량 이력 조회 실패: ${historyState.message}</div>
        `}
        ${historyState.kind === 'unavailable' && html`
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
        ${historyState.kind === 'ready' && html`
          <${UPlotChart}
            id="runtime-quotas-history"
            title=${`제공자 사용량 이력 & 일시 중지 추이 (${historyState.days}일 · ${historyState.pointsCount}포인트)`}
            subtitle=${historyState.unreadable > 0
              ? html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--warn-fg)' }}>판독 불가 보고서 ${historyState.unreadable}건</span>`
              : html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>days=${providerDays}</span>`}
            data=${historyState.data}
            series=${HISTORY_SERIES}
            height=${210}
            emptyLabel="선택한 기간에 기록된 제공자 사용량 이력이 없습니다."
          />
        `}
      </section>

      <!-- 3-Tier Quota Partition -->
      <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }} aria-label="3계층 할당량 파티션">
        ${resolvedObs.kind === 'loading' && html`
          <div class="wka-card dtable-absent">런타임 할당량 불러오는 중…</div>
        `}
        ${resolvedObs.kind === 'failed' && html`
          <div class="ap-error" role="alert">런타임 할당량 조회 오류: ${resolvedObs.error.message}</div>
        `}

        ${resolvedObs.kind === 'value' && totalScopes === 0 && html`
          <div class="wka-card dtable-absent">보고된 제공자 할당량 스코프가 없습니다.</div>
        `}

        ${partitioned.tier1ExhaustedOrCredits.length > 0 && html`
          <div data-testid="quota-tier-1">
            <h2 style=${{ margin: '0 0 var(--sp-2)', fontSize: 'var(--fs-13)', color: 'var(--err-fg)' }}>
              Tier 1 · 소진 / 크레딧 잔액 / 고사용률 (${partitioned.tier1ExhaustedOrCredits.length})
            </h2>
            <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
              ${partitioned.tier1ExhaustedOrCredits.map(renderScopeCard)}
            </div>
          </div>
        `}

        ${partitioned.tier2ActiveSubscriptions.length > 0 && html`
          <div data-testid="quota-tier-2">
            <h2 style=${{ margin: '0 0 var(--sp-2)', fontSize: 'var(--fs-13)', color: 'var(--ok-fg)' }}>
              Tier 2 · 활성 구독 ($0 Sub · ${partitioned.tier2ActiveSubscriptions.length})
            </h2>
            <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
              ${partitioned.tier2ActiveSubscriptions.map(renderScopeCard)}
            </div>
          </div>
        `}

        ${partitioned.tier3Unreported.length > 0 && html`
          <div data-testid="quota-tier-3">
            <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 'var(--sp-2)' }}>
              <h2 style=${{ margin: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-3)' }}>
                Tier 3 · 미보고 (? Unreported · ${partitioned.tier3Unreported.length})
              </h2>
              <button
                type="button"
                class="btn-ghost"
                aria-expanded=${tier3Expanded}
                onClick=${() => setTier3Expanded((v) => !v)}
              >
                ${tier3Expanded ? '미보고 접기' : `미보고 ${partitioned.tier3Unreported.length}개 펼치기`}
              </button>
            </div>
            ${tier3Expanded && html`
              <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 'var(--sp-3)' }}>
                ${partitioned.tier3Unreported.map(renderScopeCard)}
              </div>
            `}
          </div>
        `}
      </section>

      <!-- Inline Credential Form & CLI OAuth Receipt -->
      ${credForm && html`
        <form class="wka-card" onSubmit=${handleSaveCredential} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', borderColor: 'var(--line-2)' }}>
          <div class="wka-h">
            <h3>제공자 API 키 등록 / 갱신 (${accountMode === 'multi_account' ? '개인 계정' : '워크스페이스'})</h3>
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

      ${loginReceipt && html`
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
                    if (typeof navigator !== 'undefined' && navigator.clipboard) {
                      void navigator.clipboard.writeText(loginReceipt.deviceCode ?? '')
                      setCopiedDeviceCode(true)
                    }
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
              <button type="button" class="btn-ghost" onClick=${handleRefreshLoginReceipt} disabled=${actionBusy === 'receipt'}>
                영수증 상태 새로고침
              </button>
            `}
            ${accountMode === 'multi_account' && loginReceipt.accountRef && html`
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

      <!-- Provider Credentials & OAuth Inventory -->
      <section class="wka-card" aria-label="제공자 자격 증명 목록">
        <div class="wka-h">
          <h3>
            ${accountMode === 'multi_account'
              ? '내 제공자 계정 (/api/v1/auth/provider-accounts)'
              : '제공자 연동 & 자격 증명 (/api/v1/setup/inventory)'}
          </h3>
          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            ${accountMode === 'multi_account' ? `${multiAccounts.length}개 계정` : `${integrations.length}개 제공자`}
          </span>
        </div>

        ${accountMode === 'multi_account' && html`
          <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', marginBottom: 'var(--sp-2)', flexWrap: 'wrap' }}>
            <label style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>검증용 모델 (선택 시 우선 적용):</label>
            <input
              type="text"
              aria-label="검증할 모델 ID"
              placeholder="예: gpt-5-codex (비우면 통합 기본 모델)"
              value=${verifyModelInput}
              onInput=${(e: Event) => setVerifyModelInput((e.target as HTMLInputElement).value)}
              class="mono"
              style=${{ flex: '1 1 200px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--fs-12)' }}
            />
          </div>
        `}

        ${accountMode === 'multi_account'
          ? (multiAccounts.length === 0
            ? html`<div class="dtable-absent">연결된 개인 제공자 계정이 없습니다.</div>`
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
                          <button type="button" class="btn-ghost" onClick=${() => void handleRemoveKey(ref)} style=${{ color: 'var(--err-fg)' }}>제거</button>
                        </div>
                      </div>
                    `
                  })}
                </div>
              `)
          : (integrations.length === 0
            ? html`<div class="dtable-absent">${inventoryObs.kind === 'loading' ? '불러오는 중…' : '등록된 제공자 인벤토리가 없습니다.'}</div>`
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
                        <button type="button" class="btn-ghost" onClick=${() => props.onNavigate(`/settings?key=providers.${encodeURIComponent(integ.id)}`)}>
                          Open Config Key
                        </button>
                      </div>
                    </div>
                  `)}
                </div>
              `)}
      </section>
    </div>
  `
}

// Re-export helpers for targeted verification tests
export type { Observed as QuotaObserved }
export { formatUnixTime }
