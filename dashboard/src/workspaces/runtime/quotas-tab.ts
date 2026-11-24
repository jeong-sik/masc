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
import { useEffect, useMemo, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import {
  apiGet,
  apiMutate,
  currentAccountMode,
  resourceCache,
  timeWindow,
  timeWindowProviderDays,
  type Observed,
} from '../../core'
import { UPlotChart, type UPlotSeriesSpec } from '../../components/primitives'
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
  type RuntimeResolvedPayload,
  type SetupIntegration,
  type SetupInventoryPayload,
  type WorkspaceViewProps,
} from './types'

const HISTORY_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '평균 사용률 (%)', colorToken: '--info-fg', width: 2, fillAlpha: 0.14, unit: '%' },
  { label: '최대 피크 / 429 근접 (%)', colorToken: '--warn-fg', width: 1.75, unit: '%' },
  { label: '429 / 소진 쿨다운 수', colorToken: '--err-fg', width: 1.75, dash: [4, 3] },
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

  const restingRuntimes = useMemo(
    () => (resolvedData?.runtimes ?? []).filter((r) => r.quota_rest !== null),
    [resolvedData],
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

  const personIntegrations: readonly MultiAccountIntegration[] =
    personIntegObs.kind === 'value' && Array.isArray(personIntegObs.data.integrations)
      ? personIntegObs.data.integrations
      : []

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

  const handleStartOAuthLogin = async (integrationId: string) => {
    setActionBusy(`login:${integrationId}`)
    setActionBanner(null)
    const res = await apiMutate<Record<string, unknown>>(
      'POST',
      '/api/v1/setup/accounts/login',
      { integration_id: integrationId },
    )
    setActionBusy(null)
    if (!res.ok) {
      setActionBanner({ kind: 'err', text: `CLI OAuth 로그인 시작 실패: ${res.error.message}` })
      return
    }
    const loginId = typeof res.value.login_id === 'string' ? res.value.login_id : 'pending'
    setLoginReceipt({
      loginId,
      integrationId,
      status: typeof res.value.status === 'string' ? res.value.status : 'running',
      accountRef: typeof res.value.account_ref === 'string' ? res.value.account_ref : null,
      authentication: typeof res.value.authentication === 'string' ? res.value.authentication : null,
    })
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

  const integrations: readonly SetupIntegration[] =
    inventoryObs.kind === 'value' && 'integrations' in inventoryObs.data && Array.isArray(inventoryObs.data.integrations)
      ? inventoryObs.data.integrations
      : []

  const multiAccounts: readonly MultiAccountProviderAccount[] =
    inventoryObs.kind === 'value'
      ? ('provider_accounts' in inventoryObs.data && Array.isArray(inventoryObs.data.provider_accounts)
          ? inventoryObs.data.provider_accounts
          : 'accounts' in inventoryObs.data && Array.isArray(inventoryObs.data.accounts)
            ? inventoryObs.data.accounts
            : [])
      : []

  const totalScopes = (resolvedData?.provider_usage_windows ?? []).length

  return html`
    <div class="ov" data-testid="runtime-quotas-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · QUOTAS & RATE LIMITS</span>
          <h1>제공자 할당량 · 429 쿨다운 · 자격 증명</h1>
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
        <div class="ov-kpi">
          <div class="ov-kpi-k">429 쿨다운 중 런타임</div>
          <div class=${`ov-kpi-v ${restingRuntimes.length > 0 ? 'warn' : ''}`}>${restingRuntimes.length}</div>
        </div>
      </section>

      ${restingRuntimes.length > 0 && html`
        <section class="ap-error sev-warn" aria-label="429 쿨다운 런타임">
          <strong>쿨다운(Quota Rest) 활성 런타임 (${restingRuntimes.length}):</strong>
          <div style=${{ display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-2)', marginTop: 'var(--sp-2)' }}>
            ${restingRuntimes.map((rt) => html`
              <span key=${rt.id} class="mono tnum" style=${{ fontSize: 'var(--fs-12)', padding: 'var(--sp-0) var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--bg-2)', border: '1px solid var(--warn-border)' }}>
                ${rt.id} (${rt.quota_rest?.cause}) · 해제 ${formatResetCountdown(rt.quota_rest?.until)}
              </span>
            `)}
          </div>
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
            title=${`제공자 사용량 이력 & 429 쿨다운 추이 (${historyState.days}일 · ${historyState.pointsCount}포인트)`}
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
        <section class="wka-card" style=${{ borderColor: 'var(--info-border)', background: 'var(--info-soft)' }}>
          <div class="wka-h">
            <h3>CLI OAuth 로그인 영수증 · ${loginReceipt.integrationId}</h3>
            <button type="button" class="btn-ghost" onClick=${() => setLoginReceipt(null)}>닫기</button>
          </div>
          <div class="mono" style=${{ fontSize: 'var(--fs-12)', display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-3)' }}>
            <span>login_id: ${loginReceipt.loginId}</span>
            <span>상태: ${loginReceipt.status}</span>
            ${loginReceipt.authentication && html`<span>인증: ${loginReceipt.authentication}</span>`}
            ${loginReceipt.accountRef && html`<span>ref: ${loginReceipt.accountRef.slice(0, 12)}…</span>`}
          </div>
          <div style=${{ display: 'flex', gap: 'var(--sp-2)', marginTop: 'var(--sp-2)' }}>
            <button type="button" class="btn-ghost" onClick=${handleRefreshLoginReceipt} disabled=${actionBusy === 'receipt'}>
              영수증 상태 새로고침
            </button>
            ${loginReceipt.accountRef && html`
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
                        <button type="button" class="btn-ghost" onClick=${() => void handleVerifyAccount(integ.id)}>
                          검증
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
