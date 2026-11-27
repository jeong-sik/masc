/**
 * Runtime L1 Tab 4: Tools, Skills & Plug-ins
 *
 * - Live 24h Tool Call & Failure Rate UPlotChart via acquireViewStream('runtime-tools')
 *   on /api/v1/tool-metrics/series/stream (snapshot on 7d | 30d).
 * - Unified Plug-in sub-sections (keeps DOM < 600):
 *   1. Tools Catalog (/api/v1/dashboard/tools)
 *   2. Skills (SKILL.md viewer/editor + preview/save/refresh via /api/v1/skills*)
 *   3. Gate Connectors bind/unbind (/api/v1/gate/connectors*)
 *   4. Keeper OAuth Tools attach/switch/refresh/disconnect (/api/v1/keepers/oauth/*)
 *   5. MCP Clients (/api/v1/dashboard/clients)
 */

import { html } from 'htm/preact'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import {
  acquireViewStream,
  apiGet,
  authSession,
  apiMutate,
  currentSessionEpoch,
  disconnectKeeperOAuth,
  extractObserverTopics,
  isEpochCurrent,
  markViewSynced,
  observerSseInstanceId,
  resourceCache,
  saveKeeperOAuthClient,
  sessionEpoch,
  startKeeperGithubDeviceFlow,
  startKeeperOAuthPopupFlow,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
  timeWindow,
  type ActiveKeeperOAuthFlow,
  type KeeperOAuthFlowHandle,
} from '../../core'
import { DataTable, RefreshButton, UPlotChart, type DataTableColumn, type UPlotSeriesSpec } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import { isAdminLockedForSession } from '../../routes/router'
import { pushShellToast } from '../../shell/shell-state'
import {
  decodeToolMetricsSeriesPayload,
  formatCompactNumber,
  formatIsoTime,
  formatMs,
  formatPercent,
  localUtcOffsetMin,
  openViewSseStream,
  snapshotUnavailableReason,
  toObservedNumber,
  type DashboardToolRow,
  type GateConnectorRow,
  type McpClientRow,
  type ToolMetricsSeriesPayload,
  type WorkspaceViewProps,
} from './types'

type ToolsSubSection = 'catalog' | 'skills' | 'connectors' | 'oauth' | 'clients'
type OAuthTarget = { readonly keeper: string; readonly epoch: number }

interface SkillSummaryItem {
  readonly identity: { readonly source_id: string; readonly package_id: string; readonly name: string }
  readonly content_revision: string
  readonly description: string
  readonly body_bytes: number
}

interface SkillsApiPayload {
  readonly state: string
  readonly snapshot?: {
    readonly snapshot_revision: string
    readonly skills: readonly SkillSummaryItem[]
    readonly rejections?: readonly unknown[]
  }
}

interface KeeperOAuthProviderRow {
  readonly provider: string
  readonly provider_label?: string
  readonly attached?: boolean
  readonly tools?: readonly string[]
  readonly enabled?: boolean
  readonly switch_problem?: string
  readonly problem?: string
}

const TOOL_SERIES_SPECS: readonly UPlotSeriesSpec[] = [
  { label: '도구 호출 수', colorToken: '--info-fg', width: 2, fillAlpha: 0.14 },
  { label: '실패 수', colorToken: '--err-fg', width: 2, fillAlpha: 0.1 },
]

interface ToolUsageAggregate {
  calls: number
  successCount: number
  hasSuccessCount: boolean
  failureCount: number
  deferredCount: number
  hasDeferredCount: boolean
  p95Ms: number | null
}

function addToolUsageEntry(map: Map<string, ToolUsageAggregate>, key: string, entry: Record<string, unknown>): void {
  const calls = typeof entry.call_count === 'number' && Number.isFinite(entry.call_count)
    ? entry.call_count
    : typeof entry.calls === 'number' && Number.isFinite(entry.calls)
      ? entry.calls
      : 0
  const hasSuccessCount = typeof entry.success_count === 'number' && Number.isFinite(entry.success_count)
  const successCount = hasSuccessCount ? (entry.success_count as number) : 0
  const failureCount = typeof entry.failure_count === 'number' && Number.isFinite(entry.failure_count)
    ? entry.failure_count
    : 0
  const hasDeferredCount = typeof entry.deferred_count === 'number' && Number.isFinite(entry.deferred_count)
  const deferredCount = hasDeferredCount ? (entry.deferred_count as number) : 0
  const p95Ms = typeof entry.p95_ms === 'number' && Number.isFinite(entry.p95_ms) && calls > 0
    ? entry.p95_ms
    : null
  const existing = map.get(key)
  if (existing) {
    existing.calls += calls
    existing.successCount += successCount
    existing.hasSuccessCount = existing.hasSuccessCount && hasSuccessCount
    existing.failureCount += failureCount
    existing.deferredCount += deferredCount
    existing.hasDeferredCount = existing.hasDeferredCount && hasDeferredCount
    if (p95Ms !== null) {
      existing.p95Ms = existing.p95Ms === null ? p95Ms : Math.max(existing.p95Ms, p95Ms)
    }
  } else {
    map.set(key, {
      calls,
      successCount,
      hasSuccessCount,
      failureCount,
      deferredCount,
      hasDeferredCount,
      p95Ms,
    })
  }
}

function buildUsageMap(toolUsage: unknown): Map<string, ToolUsageAggregate> {
  const map = new Map<string, ToolUsageAggregate>()
  if (!toolUsage || typeof toolUsage !== 'object' || Array.isArray(toolUsage)) return map
  const rec = toolUsage as Record<string, unknown>
  const rows = Array.isArray(rec.by_tool)
    ? rec.by_tool
    : Array.isArray(rec.top_20)
      ? rec.top_20
      : []
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue
    const entry = raw as Record<string, unknown>
    const internalName = typeof entry.name === 'string' && entry.name.trim() ? entry.name.trim() : null
    if (internalName) addToolUsageEntry(map, internalName, entry)
    if (Array.isArray(entry.public_names)) {
      for (const pub of entry.public_names) {
        if (typeof pub === 'string' && pub.trim() && pub.trim() !== internalName) {
          addToolUsageEntry(map, pub.trim(), entry)
        }
      }
    }
  }
  return map
}

export function decodeToolsCatalogPayload(raw: unknown): {
  readonly rows: readonly DashboardToolRow[]
  readonly isWarming: boolean
} {
  if (!raw || typeof raw !== 'object') return { rows: [], isWarming: false }
  const rec = raw as Record<string, unknown>
  const isWarming = rec.is_warming === true
  const inventory = rec.tool_inventory && typeof rec.tool_inventory === 'object' && !Array.isArray(rec.tool_inventory)
    ? (rec.tool_inventory as Record<string, unknown>)
    : null
  const list = inventory && Array.isArray(inventory.tools)
    ? inventory.tools
    : Array.isArray(rec.tools)
      ? rec.tools
      : Array.isArray(rec.entries)
        ? rec.entries
        : Array.isArray(raw)
          ? raw
          : []
  const usageMap = buildUsageMap(rec.tool_usage)
  const rows = list
    .filter((item): item is Record<string, unknown> => typeof item === 'object' && item !== null)
    .map((item) => {
      const name = typeof item.name === 'string' ? item.name : String(item.tool ?? 'unknown')
      const joined = usageMap.get(name)
      const inlineCalls = typeof item.calls === 'number'
        ? item.calls
        : typeof item.call_count === 'number'
          ? item.call_count
          : null
      const calls = inlineCalls ?? (joined ? joined.calls : null)
      const failureCount = typeof item.failure_count === 'number'
        ? item.failure_count
        : (joined ? joined.failureCount : 0)
      const hasInlineDeferred = typeof item.deferred_count === 'number' && Number.isFinite(item.deferred_count)
      const deferredCount = hasInlineDeferred
        ? (item.deferred_count as number)
        : (joined ? joined.deferredCount : 0)
      const hasInlineSuccess = typeof item.success_count === 'number' && Number.isFinite(item.success_count)
      const successCount = hasInlineSuccess
        ? (item.success_count as number)
        : (joined ? joined.successCount : 0)
      const hasDeferred = hasInlineDeferred || Boolean(joined?.hasDeferredCount)
      const hasSuccess = hasInlineSuccess || Boolean(joined?.hasSuccessCount)
      const inlineFailureRate = typeof item.failure_rate === 'number'
        ? item.failure_rate
        : typeof item.failure_rate_pct === 'number'
          ? item.failure_rate_pct
          : null
      const settledCalls = hasDeferred && calls !== null
        ? Math.max(0, calls - deferredCount)
        : hasSuccess
          ? successCount + failureCount
          : calls !== null
            ? Math.max(0, calls - deferredCount)
            : 0
      const failureRate = inlineFailureRate
        ?? ((joined || inlineCalls !== null) && settledCalls > 0 ? (failureCount / settledCalls) * 100 : null)
      const p95Ms = typeof item.p95_ms === 'number'
        ? item.p95_ms
        : (joined ? joined.p95Ms : null)
      return {
        name,
        description: typeof item.description === 'string' ? item.description : null,
        calls,
        failure_count: failureCount,
        deferred_count: deferredCount,
        failure_rate: failureRate,
        p95_ms: p95Ms,
        domain: typeof item.domain === 'string' ? item.domain : undefined,
        family: typeof item.family === 'string'
          ? item.family
          : typeof item.category === 'string'
            ? item.category
            : undefined,
      }
    })
  return { rows, isWarming }
}

export function ToolsTab({ onInspect }: WorkspaceViewProps) {
  const win = timeWindow.value
  const session = authSession.value
  const isSingleUser = session.kind === 'single_user_local'
  const isMultiAccountSignedIn = session.kind === 'multi_account_signed_in'
  const adminLocked = isAdminLockedForSession('admin', session)
  const canAdminTools = isSingleUser && !adminLocked
  const canBroadcastTools = isSingleUser && session.role !== 'player'
  const sseInstanceId = isSingleUser ? observerSseInstanceId.value : null
  const epoch = sessionEpoch.value
  const [section, setSection] = useState<ToolsSubSection>('catalog')
  const [search, setSearch] = useState('')
  const [liveSeries, setLiveSeries] = useState<ToolMetricsSeriesPayload | null>(null)
  const [streamLive, setStreamLive] = useState(false)
  const [streamDecodeError, setStreamDecodeError] = useState<string | null>(null)
  const [banner, setBanner] = useState<{ kind: 'err'; text: string } | null>(null)

  // Skills editor state
  const [selectedSkill, setSelectedSkill] = useState<SkillSummaryItem | null>(null)
  const [skillSource, setSkillSource] = useState('')
  const [skillReading, setSkillReading] = useState(true)
  const [skillAccess, setSkillAccess] = useState<'read_only' | 'read_write'>('read_only')
  const [skillPreviewNote, setSkillPreviewNote] = useState<string | null>(null)
  const [skillBusy, setSkillBusy] = useState(false)

  // Connector bind form state
  const [bindTarget, setBindTarget] = useState<{ connectorId: string; channelId: string; keeperName: string } | null>(null)

  // Keeper OAuth state (real keeper selector + auto popup/poll + GitHub device flow + client app drawer)
  const [keeperOptions, setKeeperOptions] = useState<readonly string[]>([])
  const [oauthKeeper, setOauthKeeper] = useState('')
  const [oauthProviders, setOauthProviders] = useState<readonly KeeperOAuthProviderRow[]>([])
  const [oauthCallbackUrl, setOauthCallbackUrl] = useState<string | null>(null)
  const [oauthLoading, setOauthLoading] = useState(false)
  const [activeOAuthFlow, setActiveOAuthFlow] = useState<ActiveKeeperOAuthFlow | null>(null)
  const [clientDrawer, setClientDrawer] = useState<{
    readonly provider: string
    readonly providerLabel: string
    readonly clientId: string
    readonly clientSecret: string
    readonly scopes: string
  } | null>(null)
  const [clientBusy, setClientBusy] = useState(false)
  const oauthFlowRef = useRef<KeeperOAuthFlowHandle | null>(null)

  const selectedOAuthTarget = useRef<OAuthTarget | null>(null)
  const oauthRead = useRef<AbortController | null>(null)
  const skillReadRef = useRef<AbortController | null>(null)
  const mountedRef = useRef(true)
  const selectedSkillKeyRef = useRef('')

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      skillReadRef.current?.abort()
    }
  }, [])

  const isCurrentOAuthTarget = (target: OAuthTarget | null) =>
    target !== null && target === selectedOAuthTarget.current && target.epoch === sessionEpoch.peek()

  const selectOAuthKeeper = (name: string) => {
    const keeper = name.trim()
    const previous = selectedOAuthTarget.current
    if (!previous || previous.keeper !== keeper || previous.epoch !== epoch) {
      selectedOAuthTarget.current = { keeper, epoch }
      oauthFlowRef.current?.cancel()
      oauthRead.current?.abort()
      setActiveOAuthFlow(null)
      setClientDrawer(null)
      setClientBusy(false)
      setOauthProviders([])
      setOauthCallbackUrl(null)
      setOauthLoading(false)
      setBanner(null)
    }
    setOauthKeeper(name)
  }

  useEffect(() => {
    selectOAuthKeeper('')
    setKeeperOptions([])
    return () => {
      selectedOAuthTarget.current = null
      oauthFlowRef.current?.cancel()
      oauthRead.current?.abort()
    }
  }, [epoch])

  useEffect(() => {
    if (canAdminTools) return
    skillReadRef.current?.abort()
    oauthFlowRef.current?.cancel()
    setSelectedSkill(null)
    setSkillSource('')
    setSkillPreviewNote(null)
    setSkillBusy(false)
    setActiveOAuthFlow(null)
    setClientDrawer(null)
    setClientBusy(false)
  }, [canAdminTools])

  useEffect(() => {
    if (!canBroadcastTools) setBindTarget(null)
  }, [canBroadcastTools])

  const sinceHours = win === '24h' ? 24 : win === '7d' ? 168 : 720
  const bucket = win === '24h' ? 'hour' : 'day'
  const seriesKey = `runtime:tools-series:${win}`

  const seriesObs = resourceCache.observe<ToolMetricsSeriesPayload>(seriesKey).value
  const toolsObs = resourceCache.observe<unknown>('runtime:dashboard-tools').value
  const skillsObs = resourceCache.observe<SkillsApiPayload>('runtime:skills').value
  const connectorsObs = resourceCache.observe<{ readonly connectors?: readonly GateConnectorRow[] }>('runtime:gate-connectors').value
  const clientsObs = resourceCache.observe<{ readonly clients?: readonly McpClientRow[] }>('runtime:mcp-clients').value

  const utcOffsetMin = localUtcOffsetMin()

  const loadSeriesSnapshot = (reason: 'mount' | 'sse' | 'manual' = 'mount') => {
    if (authSession.peek().kind !== 'single_user_local') return Promise.resolve(null)
    return resourceCache.fetch<ToolMetricsSeriesPayload>(
      seriesKey,
      (signal) => apiGet<ToolMetricsSeriesPayload>(
        `/api/v1/tool-metrics/series?since_hours=${sinceHours}&bucket=${bucket}&utc_offset_min=${utcOffsetMin}`,
        { signal, decode: decodeToolMetricsSeriesPayload },
      ),
      { ttlMs: 15_000, topics: ['tool_metrics', 'tools'], reason },
    )
  }

  const loadSubSection = (targetSection: ToolsSubSection, reason: 'mount' | 'sse' | 'manual' = 'mount') => {
    const cur = authSession.peek()
    const singleLocal = cur.kind === 'single_user_local'
    const multiSignedIn = cur.kind === 'multi_account_signed_in'
    if (targetSection === 'catalog') {
      if (!singleLocal && !multiSignedIn) return Promise.resolve(null)
      return resourceCache.fetch<unknown>(
        'runtime:dashboard-tools',
        (signal) => apiGet<unknown>('/api/v1/dashboard/tools', { signal }),
        { ttlMs: 20_000, topics: ['tools', 'tool_metrics', 'skills', 'async_requests'], reason },
      )
    }
    if (!singleLocal) return Promise.resolve(null)
    if (targetSection === 'skills') {
      return resourceCache.fetch<SkillsApiPayload>(
        'runtime:skills',
        (signal) => apiGet<SkillsApiPayload>('/api/v1/skills', { signal }),
        { ttlMs: 20_000, topics: ['skills', 'skill_usage', 'skill_activations'], reason },
      )
    }
    if (targetSection === 'connectors') {
      return resourceCache.fetch<{ readonly connectors?: readonly GateConnectorRow[] }>(
        'runtime:gate-connectors',
        (signal) => apiGet('/api/v1/gate/connectors', { signal }),
        { ttlMs: 15_000, topics: ['connectors', 'gate', 'gate_connector_changed'], reason },
      )
    }
    if (targetSection === 'clients') {
      return resourceCache.fetch<{ readonly clients?: readonly McpClientRow[] }>(
        'runtime:mcp-clients',
        (signal) => apiGet('/api/v1/dashboard/clients', { signal }),
        { ttlMs: 15_000, topics: ['clients', 'ide_presence'], reason },
      )
    }
    return Promise.resolve(null)
  }

  // Snapshot load for tool series across 24h | 7d | 30d (single_user only)
  useEffect(() => {
    setLiveSeries(null)
    if (!isSingleUser) return
    void loadSeriesSnapshot('mount')
  }, [win, epoch, isSingleUser])

  // Live SSE for 24h tool series once observer x-masc-sse-instance-id is populated (strict 2+1 SSE)
  useEffect(() => {
    setStreamDecodeError(null)
    if (win !== '24h' || !sseInstanceId) {
      setStreamLive(false)
      return
    }
    const handle = acquireViewStream('runtime-tools', (signal) => {
      openViewSseStream(
        `/api/v1/tool-metrics/series/stream?since_hours=24&bucket=hour&utc_offset_min=${utcOffsetMin}`,
        signal,
        (frame) => {
          if (frame.data && typeof frame.data === 'object') {
            const payload = frame.data as Record<string, unknown>
            if (typeof payload.error === 'string' && payload.error.trim().length > 0) {
              setStreamLive(false)
              setBanner({ kind: 'err', text: `도구 지표 스트림 오류: ${payload.error}` })
              return
            }
            if ('buckets' in payload) {
              try {
                const decoded = decodeToolMetricsSeriesPayload(frame.data)
                setLiveSeries(decoded)
                setStreamDecodeError(null)
                setStreamLive(true)
              } catch (error) {
                setStreamDecodeError(error instanceof Error ? error.message : String(error))
              }
            }
          }
        },
        (st) => {
          setStreamLive(st === 'open')
        },
      )
    })
    return () => {
      handle.release()
    }
  }, [win, sseInstanceId, epoch])

  // Observer SSE refresh for warming catalog completion, skills, connectors, and clients
  useEffect(() => {
    const watchedTopics = new Set([
      'tools',
      'tool_metrics',
      'skills',
      'async_requests',
      'skill_usage',
      'skill_activations',
      'gate_connector_changed',
      'gate',
      'connectors',
      'ide_presence',
      'clients',
      'dataset_invalidation',
    ])
    let timer: ReturnType<typeof setTimeout> | null = null
    const refreshActive = () => {
      if (!mountedRef.current || !isEpochCurrent(epoch)) return
      void Promise.all([
        loadSeriesSnapshot('sse'),
        loadSubSection(section, 'sse'),
      ]).then(() => {
        if (mountedRef.current && isEpochCurrent(epoch)) markViewSynced()
      })
    }
    const unsubFrames = subscribeObserverFrames((frame) => {
      if (extractObserverTopics(frame).some((topic) => watchedTopics.has(topic))) {
        if (timer !== null) clearTimeout(timer)
        timer = setTimeout(() => {
          timer = null
          refreshActive()
        }, 400)
      }
    })
    const unsubReconnect = subscribeObserverReconnect(refreshActive)
    const unsubResync = subscribeObserverResync(refreshActive)
    return () => {
      if (timer !== null) clearTimeout(timer)
      unsubFrames()
      unsubReconnect()
      unsubResync()
    }
  }, [section, win, epoch])

  // Lazy load active sub-section
  useEffect(() => {
    if (section !== 'oauth') {
      void loadSubSection(section, 'mount')
    } else if (section === 'oauth') {
      if (!isSingleUser) return
      let cancelled = false
      void (async () => {
        let targetKeeper = selectedOAuthTarget.current?.keeper ?? ''
        if (keeperOptions.length === 0 || !targetKeeper) {
          const seen = new Set<string>()
          const names: string[] = []
          const addName = (raw: unknown) => {
            if (typeof raw !== 'string') return
            const t = raw.trim()
            if (t && !seen.has(t)) {
              seen.add(t)
              names.push(t)
            }
          }

          // Primary canonical roster endpoint: GET /api/v1/gate/keepers (CanBroadcast)
          if (canBroadcastTools) {
            const gateRes = await apiGet<{ readonly keepers?: readonly { readonly name?: string }[] }>('/api/v1/gate/keepers')
            if (cancelled) return
            if (gateRes.ok && Array.isArray(gateRes.value.keepers)) {
              for (const k of gateRes.value.keepers) addName(k?.name)
            }
          }

          // Fallback: flatten groups[].keepers (and optional top-level keepers) from /api/v1/dashboard/shell
          if (names.length === 0) {
            const shellRes = await apiGet<{
              readonly groups?: readonly { readonly keepers?: readonly string[] }[]
              readonly keepers?: readonly { readonly name?: string }[]
            }>('/api/v1/dashboard/shell')
            if (cancelled) return
            if (shellRes.ok) {
              if (Array.isArray(shellRes.value.groups)) {
                for (const g of shellRes.value.groups) {
                  if (Array.isArray(g?.keepers)) {
                    for (const k of g.keepers) addName(k)
                  }
                }
              }
              if (Array.isArray(shellRes.value.keepers)) {
                for (const k of shellRes.value.keepers) addName(k?.name)
              }
            }
          }

          targetKeeper = selectedOAuthTarget.current?.keeper ?? ''
          if (names.length > 0) {
            setKeeperOptions(names)
            if (!targetKeeper || !names.includes(targetKeeper)) {
              targetKeeper = names[0]!
              selectOAuthKeeper(targetKeeper)
            }
          }
        }
        if (!cancelled && targetKeeper) {
          void loadKeeperOAuth(targetKeeper)
        }
      })()
      return () => {
        cancelled = true
      }
    }
    return undefined
  }, [section, epoch, isSingleUser, isMultiAccountSignedIn, canBroadcastTools])

  const loadKeeperOAuth = async (keeperName: string) => {
    if (authSession.peek().kind !== 'single_user_local') return
    const target = selectedOAuthTarget.current
    if (!target?.keeper || target.keeper !== keeperName.trim() || !isCurrentOAuthTarget(target)) return
    oauthRead.current?.abort()
    const request = new AbortController()
    oauthRead.current = request
    setOauthLoading(true)
    const res = await apiGet<{
      readonly providers?: readonly KeeperOAuthProviderRow[]
      readonly callback?: { readonly url?: string }
    }>(
      `/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(target.keeper)}`,
      { signal: request.signal },
    )
    if (request.signal.aborted || !isCurrentOAuthTarget(target)) return
    setOauthLoading(false)
    if (res.ok) {
      setOauthProviders(res.value.providers ?? [])
      setOauthCallbackUrl(typeof res.value.callback?.url === 'string' ? res.value.callback.url : null)
    } else {
      setOauthProviders([])
      setBanner({ kind: 'err', text: `OAuth 도구 조회 실패: ${res.error.message}` })
    }
  }

  const activeSeries = !isSingleUser
    ? null
    : (win === '24h' && sseInstanceId && liveSeries)
      ? liveSeries
      : (seriesObs.kind === 'value' ? seriesObs.data : null)
  const live = isSingleUser && win === '24h' && sseInstanceId !== null && streamLive
  const snapshotError = isSingleUser && !activeSeries ? snapshotUnavailableReason(seriesObs) : null
  const seriesSource = !isSingleUser ? '○ SINGLE-USER ONLY'
    : live ? '● LIVE SSE (tool-metrics)'
    : snapshotError ? '○ UNAVAILABLE'
    : seriesObs.kind === 'loading' && !activeSeries ? '◐ LOADING'
    : `○ SNAPSHOT (${win})`


  const chartData = useMemo<uPlot.AlignedData>(() => {
    if (!activeSeries) return [[], [], []]
    const buckets = activeSeries.buckets ?? []
    return [
      buckets.map((b) => b.start),
      buckets.map((b) => b.call_count),
      buckets.map((b) => b.failure_count),
    ]
  }, [activeSeries])

  const decodedCatalog = useMemo(
    () => (toolsObs.kind === 'value' ? decodeToolsCatalogPayload(toolsObs.data) : { rows: [] as readonly DashboardToolRow[], isWarming: false }),
    [toolsObs],
  )
  const toolRows = useMemo(() => {
    const all = decodedCatalog.rows
    const q = search.trim().toLowerCase()
    if (!q) return all
    return all.filter((t) => t.name.toLowerCase().includes(q) || (t.description ?? '').toLowerCase().includes(q))
  }, [decodedCatalog, search])

  const toolColumns = useMemo<readonly DataTableColumn<DashboardToolRow>[]>(() => [
    {
      id: 'name',
      header: '도구 이름',
      sortable: true,
      sortValue: (r) => r.name,
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${r.name}</span>`,
    },
    {
      id: 'desc',
      header: '설명',
      cell: (r) => {
        const description = r.description
        return description ? html`
          <button type="button" class="btn-ghost btn-compact" aria-label=${`${r.name} 설명 읽기`} onClick=${() => onInspect({
            title: r.name,
            kind: 'tool-description',
            render: () => html`<${MarkdownContent} text=${description} />`,
          })}>설명 읽기</button>
        ` : '없음'
      },
    },
    {
      id: 'calls',
      header: '호출 수',
      numeric: true,
      sortable: true,
      observed: (r) => toObservedNumber(r.calls, true),
      formatValue: (v) => formatCompactNumber(Number(v)),
    },
    {
      id: 'failRate',
      header: '실패율',
      numeric: true,
      sortable: true,
      observed: (r) => toObservedNumber(r.failure_rate, true),
      formatValue: (v) => formatPercent(Number(v)),
    },
    {
      id: 'p95',
      header: 'p95',
      numeric: true,
      sortable: true,
      observed: (r) => toObservedNumber(r.p95_ms, true),
      formatValue: (v) => formatMs(Number(v)),
    },
  ], [onInspect])

  const clientColumns = useMemo<readonly DataTableColumn<McpClientRow>[]>(() => [
    { id: 'name', header: '클라이언트', sortable: true, accessor: (r) => r.name },
    {
      id: 'keeper',
      header: '바인딩 Keeper',
      cell: (r) => r.keeper_name
        ? html`<${KeeperBadge} id=${r.keeper_name} size="sm" />`
        : html`<span class="dtable-absent">없음</span>`,
    },
    { id: 'status', header: '상태', accessor: (r) => r.status },
    {
      id: 'lastSeen',
      header: '최근 관측',
      numeric: true,
      cell: (r) => html`<span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${formatIsoTime(r.last_seen)}</span>`,
    },
  ], [])

  // Skills editor handlers
  const skillKey = (s: SkillSummaryItem | null): string =>
    s ? `${s.identity.source_id}:${s.identity.package_id}:${s.identity.name}` : ''
  selectedSkillKeyRef.current = skillKey(selectedSkill)

  const hasAdminToolsAccess = (): boolean => {
    const cur = authSession.peek()
    return cur.kind === 'single_user_local' && !isAdminLockedForSession('admin', cur)
  }

  const hasBroadcastToolsAccess = (): boolean => {
    const cur = authSession.peek()
    return cur.kind === 'single_user_local' && cur.role !== 'player'
  }

  const handleOpenSkill = async (skill: SkillSummaryItem) => {
    if (!hasAdminToolsAccess()) return
    skillReadRef.current?.abort()
    const ctrl = new AbortController()
    skillReadRef.current = ctrl
    const startEpoch = sessionEpoch.peek()
    const targetKey = skillKey(skill)
    setSelectedSkill(skill)
    setSkillReading(true)
    setSkillSource('')
    setSkillPreviewNote(null)
    setSkillBusy(true)
    const res = await apiMutate<{ readonly source_text?: string; readonly access?: 'read_only' | 'read_write' }>(
      'POST',
      '/api/v1/skills/editor/read',
      { reference: { identity: skill.identity, content_revision: skill.content_revision } },
      { signal: ctrl.signal },
    )
    if (!mountedRef.current || ctrl.signal.aborted || sessionEpoch.peek() !== startEpoch || selectedSkillKeyRef.current !== targetKey) return
    setSkillBusy(false)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `SKILL.md 읽기 실패: ${res.error.message}` })
      setSkillSource('')
      return
    }
    setSkillSource(res.value.source_text ?? '')
    setSkillAccess(res.value.access ?? 'read_only')
  }

  const handlePreviewSkill = async () => {
    if (!hasAdminToolsAccess() || !selectedSkill) return
    const startEpoch = sessionEpoch.peek()
    const targetKey = skillKey(selectedSkill)
    setSkillBusy(true)
    const res = await apiMutate<{ readonly preview?: { readonly diagnostics?: readonly string[] } }>(
      'POST',
      '/api/v1/skills/editor/preview',
      {
        reference: { identity: selectedSkill.identity, content_revision: selectedSkill.content_revision },
        source_text: skillSource,
      },
    )
    if (!mountedRef.current || sessionEpoch.peek() !== startEpoch || selectedSkillKeyRef.current !== targetKey) return
    setSkillBusy(false)
    if (!res.ok) {
      setSkillPreviewNote(`검증 오류: ${res.error.message}`)
      return
    }
    const diags = res.value.preview?.diagnostics ?? []
    setSkillPreviewNote(diags.length === 0 ? '검증 통과 (경고 0건)' : `진단: ${diags.join(' · ')}`)
  }

  const handleSaveSkill = async () => {
    if (!hasAdminToolsAccess() || !selectedSkill) return
    const startEpoch = sessionEpoch.peek()
    const savedKey = skillKey(selectedSkill)
    setSkillBusy(true)
    const res = await apiMutate<{ readonly status?: string }>(
      'POST',
      '/api/v1/skills/editor/save',
      {
        reference: { identity: selectedSkill.identity, content_revision: selectedSkill.content_revision },
        source_text: skillSource,
      },
    )
    if (!mountedRef.current || sessionEpoch.peek() !== startEpoch) return
    setSkillBusy(false)
    if (!res.ok) {
      setBanner({
        kind: 'err',
        text: res.error.kind === 'conflict_cas'
          ? '스킬 리비전 충돌 (409) — 스킬 목록을 새로고침 후 다시 편집하세요.'
          : `스킬 저장 실패: ${res.error.message}`,
      })
      return
    }
    setBanner(null)
    pushShellToast(`SKILL.md 저장 완료 (${res.value.status ?? 'saved'}).`, 'success')
    const refreshed = await resourceCache.fetch<SkillsApiPayload>(
      'runtime:skills',
      (signal) => apiGet<SkillsApiPayload>('/api/v1/skills', { signal }),
      { reason: 'manual' },
    )
    if (!mountedRef.current || sessionEpoch.peek() !== startEpoch) return
    if (refreshed.kind === 'value') {
      const updated = refreshed.data.snapshot?.skills?.find((item) => skillKey(item) === savedKey)
      if (updated) {
        setSelectedSkill((cur) => (skillKey(cur) === savedKey ? updated : cur))
      }
    }
  }

  // Gate connector bind / unbind
  const handleConnectorBind = async (ev: Event) => {
    ev.preventDefault()
    if (!hasBroadcastToolsAccess() || !bindTarget || !bindTarget.channelId.trim() || !bindTarget.keeperName.trim()) return
    const startEpoch = currentSessionEpoch()
    const target = bindTarget
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/gate/connector/bind?name=${encodeURIComponent(target.connectorId)}`,
      { channel_id: target.channelId.trim(), keeper_name: target.keeperName.trim() },
    )
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    if (!res.ok) {
      setBanner({ kind: 'err', text: `커넥터 바인딩 실패: ${res.error.message}` })
      return
    }
    setBanner(null)
    pushShellToast(`${target.connectorId} 바인딩 완료.`, 'success')
    setBindTarget(null)
    void resourceCache.fetch<{ readonly connectors?: readonly GateConnectorRow[] }>(
      'runtime:gate-connectors',
      (signal) => apiGet('/api/v1/gate/connectors', { signal }),
      { reason: 'manual' },
    )
  }

  const handleConnectorUnbind = async (connectorId: string, channelId: string) => {
    if (!hasBroadcastToolsAccess()) return
    const startEpoch = currentSessionEpoch()
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/gate/connector/unbind?name=${encodeURIComponent(connectorId)}`,
      { channel_id: channelId },
    )
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    if (!res.ok) {
      setBanner({ kind: 'err', text: `바인딩 해제 실패: ${res.error.message}` })
      return
    }
    setBanner(null)
    pushShellToast(`${connectorId} 채널 ${channelId} 해제됨.`, 'success')
    void resourceCache.fetch<{ readonly connectors?: readonly GateConnectorRow[] }>(
      'runtime:gate-connectors',
      (signal) => apiGet('/api/v1/gate/connectors', { signal }),
      { reason: 'manual' },
    )
  }

  // Keeper OAuth actions (synchronous popup + postMessage + 1.5s attempt-status poll + GitHub device SSE)
  const handleOAuthAttach = (providerRow: KeeperOAuthProviderRow) => {
    if (!hasAdminToolsAccess()) return
    const keeper = oauthKeeper.trim()
    if (!keeper) {
      setBanner({ kind: 'err', text: '먼저 대상 Keeper를 선택하세요.' })
      return
    }
    const target = selectedOAuthTarget.current
    if (!target || target.keeper !== keeper || !isCurrentOAuthTarget(target)) return
    oauthFlowRef.current?.cancel()
    setBanner(null)
    const label = providerRow.provider_label ?? providerRow.provider
    const options = {
      keeper,
      providerLabel: label,
      onUpdate: (state: ActiveKeeperOAuthFlow) => {
        if (isCurrentOAuthTarget(target)) setActiveOAuthFlow(state)
      },
      onSettled: (ok: boolean) => {
        if (ok && isCurrentOAuthTarget(target)) void loadKeeperOAuth(keeper)
      },
    }
    oauthFlowRef.current = providerRow.provider === 'github'
      ? startKeeperGithubDeviceFlow(options)
      : startKeeperOAuthPopupFlow({ ...options, provider: providerRow.provider })
  }

  const handleSaveOAuthClient = async (ev: Event) => {
    ev.preventDefault()
    if (!hasAdminToolsAccess() || !clientDrawer || !clientDrawer.clientId.trim()) return
    const target = selectedOAuthTarget.current
    setClientBusy(true)
    const res = await saveKeeperOAuthClient({
      provider: clientDrawer.provider,
      clientId: clientDrawer.clientId,
      clientSecret: clientDrawer.clientSecret,
      scopes: clientDrawer.scopes,
    })
    if (!isCurrentOAuthTarget(target)) return
    setClientBusy(false)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `OAuth 앱 등록 실패: ${res.error.message}` })
      return
    }
    setBanner(null)
    pushShellToast(`${clientDrawer.providerLabel} OAuth 앱이 등록되었습니다. 이제 바로 연결할 수 있습니다.`, 'success')
    setClientDrawer(null)
    if (oauthKeeper.trim()) void loadKeeperOAuth(oauthKeeper)
  }

  const handleOAuthSwitch = async (providerId: string, enabled: boolean) => {
    if (!hasAdminToolsAccess()) return
    const target = selectedOAuthTarget.current
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/keepers/${encodeURIComponent(oauthKeeper)}/identity-switch`,
      { provider: providerId, enabled },
    )
    if (!isCurrentOAuthTarget(target)) return
    if (!res.ok) {
      setBanner({ kind: 'err', text: `스위치 전환 실패: ${res.error.message}` })
      return
    }
    void loadKeeperOAuth(oauthKeeper)
  }

  const handleOAuthDisconnect = async (providerId: string) => {
    if (!hasAdminToolsAccess()) return
    const target = selectedOAuthTarget.current
    const res = await disconnectKeeperOAuth(oauthKeeper, providerId)
    if (!isCurrentOAuthTarget(target)) return
    if (!res.ok) {
      setBanner({ kind: 'err', text: `OAuth 연결 해제 실패: ${res.error.message}` })
      return
    }
    setBanner(null)
    pushShellToast(`${oauthKeeper} · ${providerId} 연결이 해제되었습니다.`, 'success')
    void loadKeeperOAuth(oauthKeeper)
  }

  const skillsList = skillsObs.kind === 'value' ? (skillsObs.data.snapshot?.skills ?? []) : []
  const connectorsList = connectorsObs.kind === 'value' ? (connectorsObs.data.connectors ?? []) : []
  const clientsList = clientsObs.kind === 'value' ? (clientsObs.data.clients ?? []) : []

  return html`
    <div class="ov" data-testid="runtime-tools-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · TOOLS, SKILLS & PLUG-INS</span>
          <h1>도구 시계열 · 스킬(SKILL.md) · 커넥터 · OAuth · MCP</h1>
        </div>
        <span
          class="mono"
          data-testid="tools-stream-badge"
          style=${{
            padding: 'var(--sp-0) var(--sp-2)',
            borderRadius: 'var(--radius-pill)',
            fontSize: 'var(--fs-11)',
            border: `1px solid ${live ? 'var(--ok-border)' : 'var(--line-2)'}`,
            background: live ? 'var(--ok-soft)' : 'var(--bg-2)',
            color: live ? 'var(--ok-fg)' : 'var(--fg-2)',
          }}
        >
          ${seriesSource}
        </span>
      </header>

      ${banner && html`
        <div role="alert" class="ap-error">
          ${banner.text}
        </div>
      `}
      ${streamDecodeError && html`
        <div role="alert" class="ap-error">
          실시간 도구 시계열 디코드 오류: ${streamDecodeError}
        </div>
      `}

      <!-- 24h Tool Call & Failure Rate Chart -->
      <${UPlotChart}
        id="runtime-tools-series"
        title="도구 호출 & 실패 시계열"
        subtitle=${activeSeries?.total
          ? html`<span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
              총 ${formatCompactNumber(activeSeries.total.call_count)}회 · 실패 ${activeSeries.total.failure_count} · p95 ${activeSeries.total.p95_ms !== null ? formatMs(activeSeries.total.p95_ms) : '미보고'}
            </span>`
          : undefined}
        data=${chartData}
        series=${TOOL_SERIES_SPECS}
        height=${185}
        syncCrosshair=${true}
        emptyLabel=${!isSingleUser ? '도구 호출 시계열은 single_user 모드에서 제공됩니다.'
          : snapshotError ? `도구 호출 시계열 조회 실패: ${snapshotError}`
          : seriesObs.kind === 'loading' ? '도구 호출 시계열 불러오는 중…'
          : '도구 호출 시계열 데이터 없음'}
      />

      <!-- Plug-in Surface Switcher -->
      <div class="ap-viewseg" role="tablist" aria-label="플러그인 서피스 선택" style=${{ alignSelf: 'flex-start', flexWrap: 'wrap' }}>
        ${([
          ['catalog', 'Tools 카탈로그'],
          ['skills', 'Skills (SKILL.md)'],
          ['connectors', 'Gate 커넥터'],
          ['oauth', 'Keeper OAuth'],
          ['clients', 'MCP 클라이언트'],
        ] as const).map(([id, label]) => html`
          <button
            key=${id}
            type="button"
            role="tab"
            aria-selected=${section === id}
            class=${`ap-viewbtn ${section === id ? 'on' : ''}`}
            onClick=${() => setSection(id)}
          >
            ${label}
          </button>
        `)}
      </div>

      ${section === 'catalog' && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
          <input
            type="search"
            aria-label="도구 검색"
            placeholder="도구 이름 / 설명 검색…"
            value=${search}
            onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
            style=${{ maxWidth: '320px', padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />
          ${toolsObs.kind === 'failed' && html`
            <div class="ap-error" role="alert">도구 카탈로그 조회 실패: ${toolsObs.error.message}</div>
          `}
          <${DataTable}
            data=${toolRows}
            columns=${toolColumns}
            getRowId=${(r: DashboardToolRow) => r.name}
            virtualizeThreshold=${30}
            maxHeight=${400}
            caption="도구 카탈로그"
            emptyLabel=${toolsObs.kind === 'failed'
              ? `도구 카탈로그 조회 실패: ${toolsObs.error.message}`
              : toolsObs.kind === 'loading'
                ? '도구 불러오는 중…'
                : decodedCatalog.isWarming
                  ? '도구 카탈로그 준비 중…'
                  : '등록된 도구가 없습니다.'}
          />
        </div>
      `}

      ${section !== 'catalog' && !isSingleUser && html`
        <div class="wka-card" data-testid="tools-section-mode-notice" role="status" style=${{ fontSize: 'var(--fs-13)', color: 'var(--fg-2)' }}>
          선택한 플러그인 탭(Skills · Gate 커넥터 · Keeper OAuth · MCP 클라이언트)은 single_user 모드 전용입니다.
        </div>
      `}

      ${section === 'skills' && isSingleUser && html`
        <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <div class="wka-h">
              <h3>스킬 목록 (${skillsList.length})</h3>
              <${RefreshButton}
                onRefresh=${() => resourceCache.fetch<SkillsApiPayload>(
                  'runtime:skills',
                  (signal) => apiGet<SkillsApiPayload>('/api/v1/skills', { signal }),
                  { reason: 'manual' },
                )}
              />
            </div>
            ${skillsObs.kind === 'failed'
              ? html`<div class="ap-error" role="alert">스킬 목록 조회 실패: ${skillsObs.error.message}</div>`
              : skillsList.length === 0
                ? html`<div class="dtable-absent">${skillsObs.kind === 'loading' ? '스킬 불러오는 중…' : '발행된 스킬이 없습니다.'}</div>`
                : skillsList.map((s) => html`
                  <button
                    key=${`${s.identity.source_id}:${s.identity.package_id}:${s.identity.name}`}
                    type="button"
                    class="btn-ghost"
                    disabled=${!canAdminTools}
                    style=${{
                      justifyContent: 'space-between',
                      textAlign: 'left',
                      background: skillKey(selectedSkill) === skillKey(s) ? 'var(--bg-4)' : undefined,
                    }}
                    onClick=${() => void handleOpenSkill(s)}
                  >
                    <span class="mono">${s.identity.name}</span>
                    <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${s.body_bytes}B</span>
                  </button>
                `)}
          </div>

          <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
            <div class="wka-h">
              <h3>${selectedSkill ? `SKILL.md · ${selectedSkill.identity.name}` : 'SKILL.md 뷰어 / 편집기'}</h3>
              ${canAdminTools && selectedSkill && html`
                <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
                  <button type="button" class="btn-ghost" aria-pressed=${!skillReading} onClick=${() => setSkillReading(value => !value)}>
                    ${skillReading ? '원문' : '읽기'}
                  </button>
                  <button type="button" class="btn-ghost" disabled=${skillBusy} onClick=${handlePreviewSkill}>미리보기 검증</button>
                  <button type="button" class="btn-primary" disabled=${skillBusy || skillAccess !== 'read_write'} onClick=${handleSaveSkill}>저장</button>
                </div>
              `}
            </div>
            ${!canAdminTools
              ? html`<div class="dtable-absent" data-testid="tools-skills-admin-locked" role="status">SKILL.md 본문 조회 및 편집은 관리자 전용입니다.</div>`
              : html`
                  ${skillPreviewNote && html`<div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--info-fg)' }}>${skillPreviewNote}</div>`}
                  ${selectedSkill
                    ? skillReading
                      ? html`<${MarkdownContent} text=${skillSource} document />`
                      : html`
                        <textarea
                          rows=${14}
                          readOnly=${skillAccess !== 'read_write'}
                          value=${skillSource}
                          onInput=${(e: Event) => setSkillSource((e.target as HTMLTextAreaElement).value)}
                          class="mono"
                          style=${{ width: '100%', padding: 'var(--sp-2)', fontSize: 'var(--fs-12)', background: 'var(--bg-0)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)' }}
                        />
                      `
                    : html`<div class="dtable-absent">왼쪽에서 스킬을 선택하면 SKILL.md 본문을 불러옵니다.</div>`}
                `}
          </div>
        </div>
      `}

      ${section === 'connectors' && isSingleUser && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }}>
          ${canBroadcastTools && bindTarget && html`
            <form class="wka-card" onSubmit=${handleConnectorBind} style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap', alignItems: 'flex-end' }}>
              <strong style=${{ fontSize: 'var(--fs-12)' }}>${bindTarget.connectorId} 바인딩:</strong>
              <input
                type="text"
                placeholder="channel_id"
                value=${bindTarget.channelId}
                onInput=${(e: Event) => {
                  const val = (e.target as HTMLInputElement).value
                  setBindTarget((prev) => (prev ? { ...prev, channelId: val } : prev))
                }}
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                required
              />
              <input
                type="text"
                placeholder="keeper_name"
                value=${bindTarget.keeperName}
                onInput=${(e: Event) => {
                  const val = (e.target as HTMLInputElement).value
                  setBindTarget((prev) => (prev ? { ...prev, keeperName: val } : prev))
                }}
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                required
              />
              <button type="submit" class="btn-primary">바인딩</button>
              <button type="button" class="btn-ghost" onClick=${() => setBindTarget(null)}>취소</button>
            </form>
          `}

          ${connectorsObs.kind === 'failed'
            ? html`<div class="ap-error" role="alert">Gate 커넥터 조회 실패: ${connectorsObs.error.message}</div>`
            : connectorsList.length === 0
              ? html`<div class="wka-card dtable-absent">${connectorsObs.kind === 'loading' ? '커넥터 불러오는 중…' : '등록된 Gate 커넥터가 없습니다.'}</div>`
              : html`
                <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 'var(--sp-3)' }}>
                  ${connectorsList.map((c) => html`
                    <article key=${c.connector_id} class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
                      <div class="wka-h">
                        <h3>${c.display_name} (${c.channel})</h3>
                        <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: c.connected ? 'var(--ok-fg)' : 'var(--warn-fg)' }}>
                          ${c.connected ? 'connected' : (c.status || 'offline')}
                        </span>
                      </div>
                      ${c.error && html`<div style=${{ fontSize: 'var(--fs-11)', color: 'var(--err-fg)' }}>${c.error}</div>`}
                      <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
                        ${(c.configured_bindings ?? []).length === 0
                          ? html`<span class="dtable-absent" style=${{ fontSize: 'var(--fs-12)' }}>바인딩 없음</span>`
                          : (c.configured_bindings ?? []).map((b) => html`
                              <div key=${`${b.channel_id}:${b.keeper_name}`} style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 'var(--fs-12)' }}>
                                <span class="mono">${b.channel_id} → ${b.keeper_name}</span>
                                ${canBroadcastTools && html`
                                  <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }} onClick=${() => void handleConnectorUnbind(c.connector_id, b.channel_id)}>
                                    Unbind
                                  </button>
                                `}
                              </div>
                            `)}
                      </div>
                      ${canBroadcastTools && html`
                        <button
                          type="button"
                          class="btn-ghost"
                          style=${{ alignSelf: 'flex-start' }}
                          onClick=${() => setBindTarget({ connectorId: c.connector_id, channelId: '', keeperName: '' })}
                        >
                          + 채널 바인딩
                        </button>
                      `}
                    </article>
                  `)}
                </div>
              `}
        </div>
      `}

      ${section === 'oauth' && isSingleUser && html`
        <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }}>
          ${!canAdminTools && html`
            <div class="dtable-absent" data-testid="tools-oauth-admin-locked" role="status">
              OAuth 앱 설정·연결·스위치·해제는 관리자 전용입니다. 현재 연결 상태만 조회할 수 있습니다.
            </div>
          `}
          <form
            onSubmit=${(e: Event) => {
              e.preventDefault()
              void loadKeeperOAuth(oauthKeeper)
            }}
            style=${{ display: 'flex', gap: 'var(--sp-2)', alignItems: 'center', flexWrap: 'wrap' }}
          >
            <label style=${{ fontSize: 'var(--fs-12)' }}>Keeper:</label>
            ${keeperOptions.length > 0
              ? html`
                  <select
                    aria-label="OAuth 대상 Keeper"
                    value=${oauthKeeper}
                    onChange=${(e: Event) => {
                      const next = (e.target as HTMLSelectElement).value
                      selectOAuthKeeper(next)
                      void loadKeeperOAuth(next)
                    }}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  >
                    ${keeperOptions.map((name) => html`<option key=${name} value=${name}>${name}</option>`)}
                  </select>
                `
              : html`
                  <input
                    type="text"
                    aria-label="OAuth 대상 Keeper"
                    placeholder="Keeper 이름 입력…"
                    value=${oauthKeeper}
                    onInput=${(e: Event) => selectOAuthKeeper((e.target as HTMLInputElement).value)}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  />
                `}
            <button type="submit" class="btn-primary" disabled=${oauthLoading || !oauthKeeper.trim()}>조회</button>
          </form>

          ${activeOAuthFlow && html`
            <div
              data-testid="tools-oauth-active-flow"
              role="status"
              style=${{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--sp-2)',
                padding: 'var(--sp-3)',
                borderRadius: 'var(--radius-sm)',
                border: `1px solid ${activeOAuthFlow.phase === 'failed' ? 'var(--err-border)' : activeOAuthFlow.phase === 'completed' ? 'var(--ok-border)' : 'var(--info-border)'}`,
                background: activeOAuthFlow.phase === 'failed' ? 'var(--err-soft)' : activeOAuthFlow.phase === 'completed' ? 'var(--ok-soft)' : 'var(--info-soft)',
              }}
            >
              <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)' }}>
                <strong style=${{ fontSize: 'var(--fs-12)' }}>
                  ${activeOAuthFlow.providerLabel} · ${activeOAuthFlow.phase}
                </strong>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => {
                    oauthFlowRef.current?.cancel()
                    setActiveOAuthFlow(null)
                  }}
                >
                  닫기
                </button>
              </div>
              <div style=${{ fontSize: 'var(--fs-12)' }}>${activeOAuthFlow.message}</div>
              <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                ${activeOAuthFlow.authorizeUrl && html`
                  <a
                    href=${activeOAuthFlow.authorizeUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn-primary"
                    data-testid="tools-oauth-authorize-link"
                  >
                    OAuth 인증 페이지 열기 ↗
                  </a>
                `}
                ${activeOAuthFlow.deviceCode && html`
                  <span class="mono" data-testid="tools-oauth-device-code" style=${{ padding: 'var(--sp-1) var(--sp-2)', borderRadius: 'var(--radius-sm)', background: 'var(--brass-soft)', color: 'var(--brass-1)', fontWeight: 700 }}>
                    ${activeOAuthFlow.deviceCode}
                  </span>
                `}
              </div>
            </div>
          `}

          ${clientDrawer && html`
            <form
              data-testid="tools-oauth-client-form"
              onSubmit=${handleSaveOAuthClient}
              style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', padding: 'var(--sp-3)', borderRadius: 'var(--radius-sm)', border: '1px solid var(--brass-border)', background: 'var(--bg-1)' }}
            >
              <div class="wka-h">
                <strong style=${{ fontSize: 'var(--fs-12)' }}>내 OAuth 앱 등록 · ${clientDrawer.providerLabel}</strong>
                <button type="button" class="btn-ghost" onClick=${() => setClientDrawer(null)}>닫기</button>
              </div>
              ${oauthCallbackUrl && html`
                <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)', padding: 'var(--sp-1) var(--sp-2)', background: 'var(--bg-2)', borderRadius: 'var(--radius-sm)', overflowWrap: 'anywhere' }}>
                  Callback URL: ${oauthCallbackUrl}
                </div>
              `}
              <input
                type="text"
                aria-label="OAuth Client ID"
                placeholder="Client ID (필수)"
                required
                value=${clientDrawer.clientId}
                onInput=${(e: Event) => {
                  const clientId = (e.target as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, clientId } : null))
                }}
                class="mono"
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
              />
              <input
                type="password"
                aria-label="OAuth Client Secret"
                placeholder="Client Secret (공개 PKCE 앱이면 비워두세요)"
                value=${clientDrawer.clientSecret}
                onInput=${(e: Event) => {
                  const clientSecret = (e.target as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, clientSecret } : null))
                }}
                class="mono"
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
              />
              <input
                type="text"
                aria-label="OAuth Scopes"
                placeholder="Scopes (선택, 공백 구분)"
                value=${clientDrawer.scopes}
                onInput=${(e: Event) => {
                  const scopes = (e.target as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, scopes } : null))
                }}
                class="mono"
                style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
              />
              <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
                <button type="submit" class="btn-primary" disabled=${clientBusy}>
                  ${clientBusy ? '저장 중…' : 'OAuth 앱 저장'}
                </button>
              </div>
            </form>
          `}

          ${oauthProviders.length === 0
            ? html`<div class="dtable-absent">${oauthLoading ? '불러오는 중…' : '연결 가능한 OAuth 제공자가 없습니다.'}</div>`
            : oauthProviders.map((p) => html`
                <div key=${p.provider} style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)', padding: 'var(--sp-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)', flexWrap: 'wrap' }}>
                  <div>
                    <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${p.provider_label ?? p.provider}</div>
                    <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                      ${p.problem
                        ? `오류: ${p.problem}`
                        : p.attached
                          ? `연결됨 · 도구 ${p.tools?.length ?? 0}개 · ${p.switch_problem ? `스위치 오류: ${p.switch_problem}` : (p.enabled === false ? '꺼짐' : '켜짐')}`
                          : '미연결'}
                    </div>
                  </div>
                  ${canAdminTools && html`
                    <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
                      ${p.provider !== 'github' && html`
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${() => setClientDrawer({
                            provider: p.provider,
                            providerLabel: p.provider_label ?? p.provider,
                            clientId: '',
                            clientSecret: '',
                            scopes: '',
                          })}
                        >
                          앱 설정
                        </button>
                      `}
                      ${!p.problem && (!p.attached
                        ? html`<button type="button" class="btn-primary" onClick=${() => handleOAuthAttach(p)}>OAuth 연결</button>`
                        : html`
                            <button type="button" class="btn-ghost" onClick=${() => void handleOAuthSwitch(p.provider, p.enabled === false)}>
                              ${p.enabled === false ? '켜기' : '끄기'}
                            </button>
                            <button type="button" class="btn-ghost" style=${{ color: 'var(--err-fg)' }} onClick=${() => void handleOAuthDisconnect(p.provider)}>
                              연결 해제
                            </button>
                          `)}
                    </div>
                  `}
                </div>
              `)}
        </div>
      `}

      ${section === 'clients' && isSingleUser && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
          ${clientsObs.kind === 'failed' && html`
            <div class="ap-error" role="alert">MCP 클라이언트 조회 실패: ${clientsObs.error.message}</div>
          `}
          <${DataTable}
            data=${clientsList}
            columns=${clientColumns}
            getRowId=${(r: McpClientRow, i: number) => `${r.name}-${i}`}
            virtualizeThreshold=${30}
            maxHeight=${400}
            caption="MCP 클라이언트 목록"
            emptyLabel=${clientsObs.kind === 'failed'
              ? `MCP 클라이언트 조회 실패: ${clientsObs.error.message}`
              : clientsObs.kind === 'loading'
                ? '불러오는 중…'
                : '연결된 MCP 클라이언트가 없습니다.'}
          />
        </div>
      `}
    </div>
  `
}
