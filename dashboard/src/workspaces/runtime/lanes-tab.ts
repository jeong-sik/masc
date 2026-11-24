/**
 * Runtime L1 Tab 3: Lanes & Exact Output
 *
 * - Clean flat top segmented mode: `Failover | Exact Output | Fusion` (zero 4-row filter stack).
 * - Failover: Virtualized DataTable of active vs outside-lane probes (/api/v1/runtime/resolved,
 *   /api/v1/dashboard/runtime-probe) — zero horizontal overflow at 1440px, <1,000 DOM even with
 *   200+ probes! Plus inline default route & keeper assignment (POST /api/v1/runtime/config/{routing,assignment}).
 * - Exact Output: Virtualized GET /api/v1/dashboard/exact-lane-runs (filterable by
 *   exact_output | task_verification | goal_verification, cursor pagination) + click opens
 *   read-only onInspect Quick-Peek Drawer showing slot observations, schema status, and raw payload
 *   (/api/v1/dashboard/exact-lane-runs/:run_id).
 * - Fusion: /api/v1/dashboard/fusion-runs + Fusion launch modal (POST /api/v1/keepers/:k/fusion,
 *   strictly closed topology union Simple | Refine | Conditional | Judge_of_judges | Staged_judge_of_judges).
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  apiGet,
  apiMutate,
  formatObserved,
  resourceCache,
} from '../../core'
import { DataTable, VirtualList, type DataTableColumn } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  FUSION_TOPOLOGIES,
  formatMs,
  formatUnixTime,
  toObservedNumber,
  type ExactLaneRunRow,
  type ExactLaneRunsPayload,
  type ExactRunKind,
  type FusionRunRow,
  type FusionRunsPayload,
  type FusionTopology,
  type RuntimeProbePayload,
  type RuntimeProbeProviderRow,
  type RuntimeResolvedPayload,
  type WorkspaceViewProps,
} from './types'

type LanesMode = 'failover' | 'exact' | 'fusion'

interface ProbePartitionRow extends RuntimeProbeProviderRow {
  readonly scopeBand: 'active_lane' | 'outside_lane'
}

export function partitionProbeRows(
  resolved: RuntimeResolvedPayload | null,
  probe: RuntimeProbePayload | null,
): { readonly active: readonly ProbePartitionRow[]; readonly outside: readonly ProbePartitionRow[]; readonly all: readonly ProbePartitionRow[] } {
  const activeRuntimeIds = new Set<string>()
  if (resolved) {
    if (resolved.default_runtime) activeRuntimeIds.add(resolved.default_runtime.id)
    for (const lane of resolved.lanes) {
      for (const id of lane.runtime_ids) activeRuntimeIds.add(id)
    }
  }
  const active: ProbePartitionRow[] = []
  const outside: ProbePartitionRow[] = []
  for (const row of probe?.probe.providers ?? []) {
    const band = activeRuntimeIds.has(row.runtime_id) ? 'active_lane' : 'outside_lane'
    const tagged: ProbePartitionRow = { ...row, scopeBand: band }
    if (band === 'active_lane') active.push(tagged)
    else outside.push(tagged)
  }
  return { active, outside, all: [...active, ...outside] }
}

function resolveInitialMode(entityTab?: string): LanesMode {
  const t = (entityTab ?? '').trim().toLowerCase()
  if (t === 'exact' || t === 'fusion') return t
  if (typeof window !== 'undefined') {
    const mode = new URLSearchParams(window.location.search).get('mode')?.toLowerCase()
    if (mode === 'exact' || mode === 'fusion') return mode
  }
  return 'failover'
}

function statusPillStyle(status: string) {
  const s = status.toLowerCase()
  if (s === 'reachable' || s === 'succeeded' || s === 'completed' || s === 'approved' || s === 'committed') {
    return { background: 'var(--ok-soft)', border: '1px solid var(--ok-border)', color: 'var(--ok-fg)' }
  }
  if (s === 'running' || s === 'skipped_cli' || s === 'skipped_native_auth' || s === 'warming_up') {
    return { background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)' }
  }
  if (s === 'cancelled' || s === 'superseded' || s === 'deferred') {
    return { background: 'var(--warn-soft)', border: '1px solid var(--warn-border)', color: 'var(--warn-fg)' }
  }
  return { background: 'var(--err-soft)', border: '1px solid var(--err-border)', color: 'var(--err-fg)' }
}

export function LanesTab(props: WorkspaceViewProps) {
  const [mode, setMode] = useState<LanesMode>(() => resolveInitialMode(props.entityTab))
  const [probeFilter, setProbeFilter] = useState<'all' | 'active_lane' | 'outside_lane'>('all')
  const [banner, setBanner] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  // Failover inline routing/assignment form state
  const [defaultRouteInput, setDefaultRouteInput] = useState('')
  const [assignKeeper, setAssignKeeper] = useState('')
  const [assignRuntime, setAssignRuntime] = useState('')
  const [sourceRevision, setSourceRevision] = useState<string | null>(null)

  // Exact Output pagination & filter state
  const [runKindFilter, setRunKindFilter] = useState<'all' | ExactRunKind>('all')
  const [cursorStack, setCursorStack] = useState<readonly { startedAt: number; runId: string }[]>([])
  const currentCursor = cursorStack[cursorStack.length - 1] ?? null

  // Fusion launch modal state
  const [fusionModalOpen, setFusionModalOpen] = useState(false)
  const [fusionKeeper, setFusionKeeper] = useState('')
  const [fusionPrompt, setFusionPrompt] = useState('')
  const [fusionPreset, setFusionPreset] = useState('')
  const [fusionTopology, setFusionTopology] = useState<FusionTopology>('simple')
  const [fusionWebTools, setFusionWebTools] = useState(false)

  const resolvedObs = resourceCache.observe<RuntimeResolvedPayload>('runtime:resolved').value
  const probeObs = resourceCache.observe<RuntimeProbePayload>('runtime:probe').value

  const exactKey = `runtime:exact-runs:${runKindFilter}:${currentCursor ? `${currentCursor.startedAt}:${currentCursor.runId}` : 'head'}`
  const exactObs = resourceCache.observe<ExactLaneRunsPayload>(exactKey).value
  const fusionObs = resourceCache.observe<FusionRunsPayload>('runtime:fusion-runs').value

  const loadFailover = (forceProbe = false, reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<RuntimeResolvedPayload>(
      'runtime:resolved',
      (signal) => apiGet<RuntimeResolvedPayload>('/api/v1/runtime/resolved', { signal }),
      { ttlMs: 15_000, topics: ['runtime', 'config'], reason },
    )
    void resourceCache.fetch<RuntimeProbePayload>(
      'runtime:probe',
      (signal) => apiGet<RuntimeProbePayload>(
        `/api/v1/dashboard/runtime-probe${forceProbe ? '?force=true' : ''}`,
        { signal },
      ),
      { ttlMs: 20_000, topics: ['runtime_probe'], reason: forceProbe ? 'manual' : reason },
    )
    void apiGet<{ readonly source_revision?: string }>('/api/v1/runtime/config/raw').then((res) => {
      if (res.ok && typeof res.value.source_revision === 'string') {
        setSourceRevision(res.value.source_revision)
      }
    })
  }

  const loadExact = (reason: 'mount' | 'manual' = 'mount') => {
    const qs = new URLSearchParams({ limit: '50' })
    if (runKindFilter !== 'all') qs.set('run_kind', runKindFilter)
    if (currentCursor) {
      qs.set('before_started_at', String(currentCursor.startedAt))
      qs.set('before_run_id', currentCursor.runId)
    }
    void resourceCache.fetch<ExactLaneRunsPayload>(
      exactKey,
      (signal) => apiGet<ExactLaneRunsPayload>(`/api/v1/dashboard/exact-lane-runs?${qs.toString()}`, { signal }),
      { ttlMs: 15_000, topics: ['exact_lane_runs'], reason },
    )
  }

  const loadFusion = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<FusionRunsPayload>(
      'runtime:fusion-runs',
      (signal) => apiGet<FusionRunsPayload>('/api/v1/dashboard/fusion-runs', { signal }),
      { ttlMs: 15_000, topics: ['fusion_run_status'], reason },
    )
  }

  useEffect(() => {
    if (mode === 'failover') loadFailover(false, 'mount')
    else if (mode === 'exact') loadExact('mount')
    else loadFusion('mount')
  }, [mode, runKindFilter, currentCursor])

  const resolvedData = resolvedObs.kind === 'value' ? resolvedObs.data : null
  const probeData = probeObs.kind === 'value' ? probeObs.data : null

  useEffect(() => {
    if (resolvedData) {
      if (!defaultRouteInput && resolvedData.default_route) {
        setDefaultRouteInput(resolvedData.default_route)
      }
      if (!assignKeeper && resolvedData.assignments[0]) {
        setAssignKeeper(resolvedData.assignments[0].keeper)
      }
      if (!fusionKeeper && resolvedData.assignments[0]) {
        setFusionKeeper(resolvedData.assignments[0].keeper)
      }
    }
  }, [resolvedData])

  const probePartition = useMemo(
    () => partitionProbeRows(resolvedData, probeData),
    [resolvedData, probeData],
  )

  const filteredProbes = useMemo(() => {
    if (probeFilter === 'active_lane') return probePartition.active
    if (probeFilter === 'outside_lane') return probePartition.outside
    return probePartition.all
  }, [probePartition, probeFilter])

  const activeFailed = useMemo(
    () => probePartition.active.filter((p) => p.reachable === false).length,
    [probePartition.active],
  )
  const outsideFailed = useMemo(
    () => probePartition.outside.filter((p) => p.reachable === false).length,
    [probePartition.outside],
  )

  const exactColumns = useMemo<readonly DataTableColumn<ExactLaneRunRow>[]>(() => [
    {
      id: 'run_id',
      header: 'Run ID',
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)' }}>${r.run_id.slice(0, 14)}</span>`,
    },
    {
      id: 'kind',
      header: '종류',
      sortable: true,
      sortValue: (r) => r.run_kind,
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--info-fg)' }}>${r.run_kind}</span>`,
    },
    {
      id: 'lane',
      header: '레인',
      sortable: true,
      sortValue: (r) => r.lane,
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${r.lane}</span>`,
    },
    {
      id: 'actor',
      header: 'Actor',
      cell: (r) => html`<${KeeperBadge} id=${r.actor} size="sm" />`,
    },
    {
      id: 'status',
      header: '상태',
      sortable: true,
      sortValue: (r) => r.status,
      cell: (r) => html`
        <span class="mono" style=${{ ...statusPillStyle(r.status), padding: '1px 7px', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
          ${r.status}
        </span>
      `,
    },
    {
      id: 'elapsed',
      header: '소요(s)',
      numeric: true,
      observed: (r) => toObservedNumber(r.elapsed_s, true),
      formatValue: (v) => `${Number(v).toFixed(2)}s`,
    },
    {
      id: 'started',
      header: '시작 시각',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.started_at,
      cell: (r) => html`<span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${formatUnixTime(r.started_at)}</span>`,
    },
  ], [])

  const fusionColumns = useMemo<readonly DataTableColumn<FusionRunRow>[]>(() => [
    {
      id: 'run_id',
      header: 'Run ID',
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)' }}>${r.run_id.slice(0, 14)}</span>`,
    },
    {
      id: 'keeper',
      header: 'Keeper',
      cell: (r) => html`<${KeeperBadge} id=${r.keeper} size="sm" />`,
    },
    {
      id: 'preset',
      header: '프리셋',
      sortable: true,
      accessor: (r) => r.preset,
    },
    {
      id: 'topology',
      header: '토폴로지',
      sortable: true,
      sortValue: (r) => r.topology,
      cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--brass-1)' }}>${r.topology}</span>`,
    },
    {
      id: 'status',
      header: '상태',
      sortable: true,
      sortValue: (r) => r.status,
      cell: (r) => html`
        <span class="mono" style=${{ ...statusPillStyle(r.status), padding: '1px 7px', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
          ${r.status}
        </span>
      `,
    },
    {
      id: 'started',
      header: '시작 시각',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.started_at,
      cell: (r) => html`<span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${formatUnixTime(r.started_at)}</span>`,
    },
  ], [])

  const handleSaveDefaultRoute = async (ev: Event) => {
    ev.preventDefault()
    if (!defaultRouteInput.trim()) return
    setBusy('routing')
    setBanner(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/runtime/config/routing', {
      lane: 'default',
      runtime_id: defaultRouteInput.trim(),
    })
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `기본 라우트 변경 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `기본 라우트가 ${defaultRouteInput.trim()} 로 갱신되었습니다.` })
    loadFailover(false, 'manual')
  }

  const handleSaveAssignment = async (ev: Event) => {
    ev.preventDefault()
    if (!assignKeeper.trim()) return
    setBusy('assignment')
    setBanner(null)
    const prev = resolvedData?.assignments.find((a) => a.keeper === assignKeeper.trim())
    const prevRuntimeId = prev && prev.assignment_source === 'explicit' ? prev.resolved.id : null
    const expected_assignment_revision = sourceRevision
      ? {
          state: 'runtime_config_present',
          source_revision: sourceRevision,
          assignment: prevRuntimeId
            ? { state: 'assigned', runtime_id: prevRuntimeId }
            : { state: 'missing' },
        }
      : { state: 'runtime_config_missing' }

    const res = await apiMutate<unknown>('POST', '/api/v1/runtime/config/assignment', {
      keeper_name: assignKeeper.trim(),
      runtime_id: assignRuntime.trim() ? assignRuntime.trim() : null,
      expected_assignment_revision,
    })
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `Keeper 할당 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `${assignKeeper.trim()} 런타임 할당이 반영되었습니다.` })
    loadFailover(false, 'manual')
  }

  const handleInspectExactRun = async (row: ExactLaneRunRow) => {
    props.onInspect({
      title: `Exact Run · ${row.lane}`,
      subtitle: `${row.run_id} (${row.status})`,
      kind: 'exact_lane_run',
      data: row,
      render: () => html`<div class="dtable-absent">상세 페이로드 불러오는 중…</div>`,
    })
    const res = await apiGet<{ readonly run?: ExactLaneRunRow } & ExactLaneRunRow>(
      `/api/v1/dashboard/exact-lane-runs/${encodeURIComponent(row.run_id)}`,
    )
    const detail: ExactLaneRunRow = res.ok ? (res.value.run ?? res.value) : row
    const errMsg = res.ok ? null : res.error.message

    props.onInspect({
      title: `Exact Run · ${detail.lane}`,
      subtitle: `${detail.run_id} · ${detail.run_kind} · ${detail.status}`,
      kind: 'exact_lane_run',
      data: detail,
      render: () => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          ${errMsg && html`<div class="ap-error">상세 API 조회 오류: ${errMsg}</div>`}
          <div class="wka-card" style=${{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 'var(--sp-2)', fontSize: 'var(--fs-12)' }}>
            <div><span style=${{ color: 'var(--fg-3)' }}>Status:</span> <span class="mono">${detail.status}</span></div>
            <div><span style=${{ color: 'var(--fg-3)' }}>Slot:</span> <span class="mono">${detail.selected_slot ?? '없음'}</span></div>
            <div><span style=${{ color: 'var(--fg-3)' }}>Origin:</span> <span class="mono">${detail.completion_origin ?? '없음'}</span></div>
            <div><span style=${{ color: 'var(--fg-3)' }}>Subject:</span> <span class="mono">${detail.subject_id ?? '없음'}</span></div>
          </div>

          <div class="wka-card">
            <h4 style=${{ margin: '0 0 var(--sp-1)', fontSize: 'var(--fs-12)' }}>스키마 / 페이로드 가용성</h4>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
              Input: ${detail.payload_availability?.input?.state ?? 'unobserved'} ·
              Output: ${detail.payload_availability?.output?.state ?? (detail.status === 'running' ? 'running (null)' : 'unobserved')}
            </div>
            ${detail.code && html`
              <div style=${{ marginTop: 'var(--sp-1)', color: 'var(--err-fg)', fontSize: 'var(--fs-12)' }}>
                ${detail.code}: ${detail.detail ?? ''}
              </div>
            `}
          </div>

          <div class="wka-card">
            <h4 style=${{ margin: '0 0 var(--sp-1)', fontSize: 'var(--fs-12)' }}>슬롯 관측 (Slot Observations)</h4>
            <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', background: 'var(--bg-0)', padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)' }}>
              ${JSON.stringify(detail.slot_observations ?? { state: 'unobserved' }, null, 2)}
            </pre>
          </div>

          <div class="wka-card">
            <h4 style=${{ margin: '0 0 var(--sp-1)', fontSize: 'var(--fs-12)' }}>Raw Output Payload</h4>
            <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', background: 'var(--bg-0)', padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)' }}>
              ${detail.output !== undefined ? JSON.stringify(detail.output, null, 2) : '없음'}
            </pre>
          </div>
        </div>
      `,
    })
  }

  const handleInspectFusionRun = async (row: FusionRunRow) => {
    const res = await apiGet<unknown>(`/api/v1/dashboard/fusion-runs/${encodeURIComponent(row.run_id)}`)
    props.onInspect({
      title: `Fusion · ${row.preset}`,
      subtitle: `${row.run_id} (${row.topology} · ${row.status})`,
      kind: 'fusion_run',
      data: res.ok ? res.value : row,
      render: () => html`
        <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', background: 'var(--bg-0)', padding: 'var(--sp-3)', borderRadius: 'var(--radius-sm)' }}>
          ${JSON.stringify(res.ok ? res.value : row, null, 2)}
        </pre>
      `,
    })
  }

  const handleLaunchFusion = async (ev: Event) => {
    ev.preventDefault()
    if (!fusionKeeper.trim() || !fusionPrompt.trim()) return
    setBusy('fusion')
    setBanner(null)
    const body = {
      prompt: fusionPrompt.trim(),
      topology: fusionTopology,
      web_tools: fusionWebTools,
      ...(fusionPreset.trim() ? { preset: fusionPreset.trim() } : {}),
    }
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/keepers/${encodeURIComponent(fusionKeeper.trim())}/fusion`,
      body,
    )
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `Fusion 실행 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `${fusionKeeper.trim()} Fusion (${fusionTopology}) 실행을 요청했습니다.` })
    setFusionModalOpen(false)
    setFusionPrompt('')
    loadFusion('manual')
  }

  const exactData = exactObs.kind === 'value' ? exactObs.data : null
  const fusionData = fusionObs.kind === 'value' ? fusionObs.data : null

  return html`
    <div class="ov" data-testid="runtime-lanes-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · LANES & EXACT OUTPUT</span>
          <h1>페일오버 레인 · Exact Output · Fusion 패널</h1>
        </div>
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <div class="ap-viewseg" role="tablist" aria-label="레인 모드 선택">
            <button
              type="button"
              role="tab"
              aria-selected=${mode === 'failover'}
              class=${`ap-viewbtn ${mode === 'failover' ? 'on' : ''}`}
              onClick=${() => setMode('failover')}
            >
              Failover
            </button>
            <button
              type="button"
              role="tab"
              aria-selected=${mode === 'exact'}
              class=${`ap-viewbtn ${mode === 'exact' ? 'on' : ''}`}
              onClick=${() => setMode('exact')}
            >
              Exact Output
            </button>
            <button
              type="button"
              role="tab"
              aria-selected=${mode === 'fusion'}
              class=${`ap-viewbtn ${mode === 'fusion' ? 'on' : ''}`}
              onClick=${() => setMode('fusion')}
            >
              Fusion
            </button>
          </div>
          ${mode === 'failover' && html`
            <button type="button" class="btn-ghost" onClick=${() => loadFailover(true, 'manual')}>
              강제 프로브
            </button>
          `}
          ${mode === 'fusion' && html`
            <button type="button" class="btn-primary" onClick=${() => setFusionModalOpen((v) => !v)}>
              + Fusion 실행
            </button>
          `}
        </div>
      </header>

      ${banner && html`
        <div
          role="status"
          class=${banner.kind === 'err' ? 'ap-error' : 'wka-card'}
          style=${banner.kind === 'ok' ? { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' } : undefined}
        >
          ${banner.text}
        </div>
      `}

      ${mode === 'failover' && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-4)', minWidth: 0 }}>
          <section class="ov-kpis" aria-label="레인 프로브 요약">
            <div class="ov-kpi">
              <div class="ov-kpi-k">기본 라우트</div>
              <div class="ov-kpi-v" style=${{ fontSize: 'var(--fs-14)' }}>${resolvedData?.default_route ?? '없음'}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">활성 레인 프로브 (실패)</div>
              <div class=${`ov-kpi-v ${activeFailed > 0 ? 'bad' : 'ok'}`}>
                ${probePartition.active.length} (${activeFailed})
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">외부 레인 프로브 (격리)</div>
              <div class=${`ov-kpi-v ${outsideFailed > 0 ? 'warn' : ''}`}>
                ${probePartition.outside.length} (${outsideFailed})
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">선언된 페일오버 레인</div>
              <div class="ov-kpi-v">${resolvedData?.lanes.length ?? 0}</div>
            </div>
          </section>

          <!-- Inline Default Route & Keeper Assignment Controls -->
          <section style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 'var(--sp-3)', minWidth: 0 }}>
            <form class="wka-card" onSubmit=${handleSaveDefaultRoute} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
              <h3 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>기본 라우트 설정 (/runtime/config/routing)</h3>
              <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
                <input
                  type="text"
                  aria-label="기본 라우트 ID"
                  value=${defaultRouteInput}
                  onInput=${(e: Event) => setDefaultRouteInput((e.target as HTMLInputElement).value)}
                  placeholder="lane 또는 runtime ID"
                  style=${{ flex: 1, minWidth: 0, padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <button type="submit" class="btn-primary" disabled=${busy === 'routing'}>적용</button>
              </div>
            </form>

            <form class="wka-card" onSubmit=${handleSaveAssignment} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
              <h3 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>Keeper 런타임 할당 (/runtime/config/assignment)</h3>
              <div style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                <input
                  type="text"
                  aria-label="Keeper 이름"
                  value=${assignKeeper}
                  onInput=${(e: Event) => setAssignKeeper((e.target as HTMLInputElement).value)}
                  placeholder="keeper"
                  style=${{ flex: '1 1 120px', minWidth: 0, padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <input
                  type="text"
                  aria-label="할당할 Runtime ID"
                  value=${assignRuntime}
                  onInput=${(e: Event) => setAssignRuntime((e.target as HTMLInputElement).value)}
                  placeholder="runtime_id (비우면 기본값)"
                  style=${{ flex: '1 1 140px', minWidth: 0, padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <button type="submit" class="btn-primary" disabled=${busy === 'assignment'}>할당</button>
              </div>
            </form>
          </section>

          <!-- Virtualized Probes DataTable (<1,000 DOM even with 200+ probes!) -->
          <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
            <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
              <div class="ap-viewseg" role="group" aria-label="프로브 범위 필터">
                <button type="button" class=${`ap-viewbtn ${probeFilter === 'all' ? 'on' : ''}`} onClick=${() => setProbeFilter('all')}>
                  전체 (${probePartition.all.length})
                </button>
                <button type="button" class=${`ap-viewbtn ${probeFilter === 'active_lane' ? 'on' : ''}`} onClick=${() => setProbeFilter('active_lane')}>
                  활성 레인 (${probePartition.active.length})
                </button>
                <button type="button" class=${`ap-viewbtn ${probeFilter === 'outside_lane' ? 'on' : ''}`} onClick=${() => setProbeFilter('outside_lane')}>
                  외부 레인 (${probePartition.outside.length})
                </button>
              </div>
              <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                ${probeData ? `상태: ${probeData.refresh_state} · 캐시 ${probeData.cache_hit ? 'HIT' : 'MISS'}` : '대기 중'}
              </span>
            </div>

            <div
              class="wka-card"
              data-testid="failover-probes-list"
              style=${{ padding: 0, overflowX: 'auto', minWidth: 0 }}
            >
              <div
                class="mono"
                aria-hidden="true"
                style=${{
                  display: 'grid',
                  gridTemplateColumns: '78px minmax(0, 1.3fr) minmax(0, 1.3fr) 128px 64px 76px',
                  gap: 'var(--sp-2)',
                  padding: 'var(--sp-2) var(--sp-3)',
                  background: 'var(--bg-2)',
                  borderBottom: '1px solid var(--line-1)',
                  fontSize: 'var(--fs-11)',
                  color: 'var(--fg-3)',
                  fontWeight: 600,
                }}
              >
                <span>대역</span>
                <span>RUNTIME ID</span>
                <span>제공자 / 모델</span>
                <span>프로브 상태</span>
                <span style=${{ textAlign: 'right' }}>HTTP</span>
                <span style=${{ textAlign: 'right' }}>지연</span>
              </div>
              <${VirtualList}
                items=${filteredProbes}
                estimateSize=${44}
                height=${400}
                ariaLabel="런타임 프로브 목록"
                getItemKey=${(r: ProbePartitionRow) => `${r.scopeBand}:${r.runtime_id}`}
                empty=${html`
                  <div class="dtable-absent" style=${{ padding: 'var(--sp-4)' }}>
                    ${probeObs.kind === 'loading' ? '프로브 불러오는 중…' : '표시할 런타임 프로브가 없습니다.'}
                  </div>
                `}
                renderItem=${(r: ProbePartitionRow) => html`
                  <div
                    style=${{
                      display: 'grid',
                      gridTemplateColumns: '78px minmax(0, 1.3fr) minmax(0, 1.3fr) 128px 64px 76px',
                      gap: 'var(--sp-2)',
                      alignItems: 'center',
                      height: '44px',
                      padding: '0 var(--sp-3)',
                      borderBottom: '1px solid var(--line-1)',
                      fontSize: 'var(--fs-12)',
                      minWidth: 0,
                    }}
                  >
                    <span
                      class="mono"
                      style=${{
                        fontSize: 'var(--fs-10)',
                        padding: '2px var(--sp-1)',
                        borderRadius: 'var(--radius-pill)',
                        background: r.scopeBand === 'active_lane' ? 'var(--brass-soft)' : 'var(--idle-soft)',
                        color: r.scopeBand === 'active_lane' ? 'var(--brass-1)' : 'var(--fg-3)',
                        textAlign: 'center',
                      }}
                    >
                      ${r.scopeBand === 'active_lane' ? 'ACTIVE' : 'OUTSIDE'}
                    </span>
                    <span class="mono" style=${{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      ${r.runtime_id}
                    </span>
                    <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: 'var(--fg-2)' }}>
                      ${r.provider_display_name} · <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${r.model_id}</span>
                    </span>
                    <span>
                      <span class="mono" style=${{ ...statusPillStyle(r.status), padding: '2px var(--sp-2)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
                        ${r.status}
                      </span>
                    </span>
                    <span class="mono tnum" style=${{ textAlign: 'right', color: r.http_status === null ? 'var(--fg-4)' : 'var(--fg-1)' }}>
                      ${r.http_status === null ? '미보고' : r.http_status}
                    </span>
                    <span class="mono tnum" style=${{ textAlign: 'right', color: r.latency_ms === null ? 'var(--fg-4)' : 'var(--fg-1)' }}>
                      ${r.latency_ms === null ? '미보고' : formatMs(r.latency_ms)}
                    </span>
                  </div>
                `}
              />
            </div>
          </section>
        </div>
      `}

      ${mode === 'exact' && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
            <div class="ap-viewseg" role="group" aria-label="Exact 실행 종류 필터">
              ${(['all', 'exact_output', 'task_verification', 'goal_verification'] as const).map((k) => html`
                <button
                  key=${k}
                  type="button"
                  class=${`ap-viewbtn ${runKindFilter === k ? 'on' : ''}`}
                  onClick=${() => {
                    setRunKindFilter(k)
                    setCursorStack([])
                  }}
                >
                  ${k === 'all' ? '전체' : k}
                </button>
              `)}
            </div>
            <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
              <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                총 ${formatObserved(exactObs, (d) => `${d.total}건`)} · 행 클릭으로 [⤢] 상세 열기
              </span>
              <button
                type="button"
                class="btn-ghost"
                disabled=${cursorStack.length === 0}
                onClick=${() => setCursorStack((s) => s.slice(0, -1))}
              >
                ← 이전
              </button>
              <button
                type="button"
                class="btn-ghost"
                disabled=${!exactData?.has_more || !exactData.runs.length}
                onClick=${() => {
                  const last = exactData?.runs[exactData.runs.length - 1]
                  if (last) setCursorStack((s) => [...s, { startedAt: last.started_at, runId: last.run_id }])
                }}
              >
                다음 →
              </button>
            </div>
          </div>

          <${DataTable}
            data=${exactData?.runs ?? []}
            columns=${exactColumns}
            getRowId=${(r: ExactLaneRunRow) => r.run_id}
            onRowClick=${(r: ExactLaneRunRow) => void handleInspectExactRun(r)}
            virtualizeThreshold=${25}
            maxHeight=${460}
            caption="Exact Output 실행 이력"
            emptyLabel=${exactObs.kind === 'loading' ? '불러오는 중…' : 'Exact Output 실행 기록이 없습니다.'}
          />
        </div>
      `}

      ${mode === 'fusion' && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          ${fusionModalOpen && html`
            <form
              class="wka-card"
              data-testid="fusion-launch-form"
              onSubmit=${handleLaunchFusion}
              style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', borderColor: 'var(--brass-border)' }}
            >
              <div class="wka-h">
                <h3>Fusion 패널 Fan-Out 실행 (POST /api/v1/keepers/:k/fusion)</h3>
                <button type="button" class="btn-ghost" onClick=${() => setFusionModalOpen(false)}>닫기</button>
              </div>
              <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 'var(--sp-2)' }}>
                <label style=${{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: 'var(--fs-12)' }}>
                  <span>Keeper</span>
                  <input
                    type="text"
                    required
                    value=${fusionKeeper}
                    onInput=${(e: Event) => setFusionKeeper((e.target as HTMLInputElement).value)}
                    style=${{ padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  />
                </label>
                <label style=${{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: 'var(--fs-12)' }}>
                  <span>토폴로지 (닫힌 합타입)</span>
                  <select
                    value=${fusionTopology}
                    onChange=${(e: Event) => setFusionTopology((e.target as HTMLSelectElement).value as FusionTopology)}
                    style=${{ padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  >
                    ${FUSION_TOPOLOGIES.map((t) => html`<option key=${t.value} value=${t.value}>${t.label}</option>`)}
                  </select>
                </label>
                <label style=${{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: 'var(--fs-12)' }}>
                  <span>프리셋 (선택)</span>
                  <input
                    type="text"
                    placeholder="기본 프리셋"
                    value=${fusionPreset}
                    onInput=${(e: Event) => setFusionPreset((e.target as HTMLInputElement).value)}
                    style=${{ padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  />
                </label>
              </div>
              <label style=${{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: 'var(--fs-12)' }}>
                <span>패널 질문 (Free Text)</span>
                <textarea
                  rows=${3}
                  required
                  value=${fusionPrompt}
                  onInput=${(e: Event) => setFusionPrompt((e.target as HTMLTextAreaElement).value)}
                  style=${{ padding: '8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)', resize: 'vertical' }}
                />
              </label>
              <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--sp-2)' }}>
                <label style=${{ display: 'inline-flex', alignItems: 'center', gap: '6px', fontSize: 'var(--fs-12)' }}>
                  <input
                    type="checkbox"
                    checked=${fusionWebTools}
                    onChange=${(e: Event) => setFusionWebTools((e.target as HTMLInputElement).checked)}
                  />
                  <span>web_tools 허용</span>
                </label>
                <button type="submit" class="btn-primary" disabled=${busy === 'fusion'}>
                  ${busy === 'fusion' ? '실행 중…' : 'Fusion 실행'}
                </button>
              </div>
            </form>
          `}

          <${DataTable}
            data=${fusionData?.runs ?? []}
            columns=${fusionColumns}
            getRowId=${(r: FusionRunRow) => r.run_id}
            onRowClick=${(r: FusionRunRow) => void handleInspectFusionRun(r)}
            virtualizeThreshold=${25}
            maxHeight=${440}
            caption="Fusion 실행 목록"
            emptyLabel=${fusionObs.kind === 'loading' ? '불러오는 중…' : 'Fusion 실행 이력이 없습니다.'}
          />
        </div>
      `}
    </div>
  `
}
