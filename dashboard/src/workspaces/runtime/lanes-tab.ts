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
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  apiGet,
  apiMutate,
  currentSessionEpoch,
  formatObserved,
  isEpochCurrent,
  resourceCache,
  sessionEpoch,
} from '../../core'
import { DataTable, VirtualList, type DataTableColumn } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  buildLaneUnifiedDiff,
  deleteLaneFromToml,
  parseLanesFromToml,
  reorderCandidate,
  upsertLaneInToml,
  type EditableLaneKind,
  type ParsedTomlLane,
} from './lane-toml-editor'
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

interface LaneConfigSource {
  readonly sourceText: string
  readonly sourceRevision: string
  readonly sourcePath: string
  readonly epoch: number
  readonly signal: AbortSignal
}

function isCurrentLaneSource(source: LaneConfigSource): boolean {
  return !source.signal.aborted && isEpochCurrent(source.epoch)
}

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
  const [banner, setBanner] = useState<{ kind: 'ok' | 'err' | 'lane-source-error'; text: string } | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  // Failover inline routing/assignment form state
  const [defaultRouteInput, setDefaultRouteInput] = useState('')
  const [assignKeeper, setAssignKeeper] = useState('')
  const [assignRuntime, setAssignRuntime] = useState('')
  const [sourceRevision, setSourceRevision] = useState<string | null>(null)
  const [rawConfig, setRawConfig] = useState<LaneConfigSource | null>(null)
  const sourceRead = useRef<AbortController | null>(null)
  const previewRequest = useRef<AbortController | null>(null)
  const epoch = sessionEpoch.value

  // Visual Runtime Lane CRUD state (/api/v1/runtime/config/raw + /raw/preview)
  const [laneEditor, setLaneEditor] = useState<{
    readonly mode: 'create' | 'edit'
    readonly kind: EditableLaneKind
    readonly id: string
    readonly candidates: readonly string[]
    readonly newCandidate: string
    readonly maxOutputTokens: string
  } | null>(null)
  const [laneDeleteConfirm, setLaneDeleteConfirm] = useState<{
    readonly kind: EditableLaneKind
    readonly id: string
  } | null>(null)
  const [lanePreview, setLanePreview] = useState<{
    readonly source: LaneConfigSource
    readonly nextToml: string
    readonly diff: string
    readonly canSave: boolean
    readonly runtimeValidation: string | null
    readonly validationIssues: readonly string[]
    readonly label: string
  } | null>(null)
  const [laneCasConflict, setLaneCasConflict] = useState<string | null>(null)

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

  const discardLanePreview = () => {
    previewRequest.current?.abort()
    setLanePreview(null)
    setBusy((action) => action === 'lane-preview' ? null : action)
  }

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
    sourceRead.current?.abort()
    const read = new AbortController()
    sourceRead.current = read
    const readEpoch = currentSessionEpoch()
    discardLanePreview()
    setRawConfig(null)
    setBusy((action) => action === 'lane-apply' ? null : action)
    void apiGet<{
      readonly source_revision?: string
      readonly source_text?: string
      readonly path?: string
    }>('/api/v1/runtime/config/raw', { signal: read.signal }).then((res) => {
      if (read.signal.aborted || !isEpochCurrent(readEpoch)) return
      if (!res.ok) {
        setBanner({ kind: 'lane-source-error', text: `runtime.toml 원본 조회 실패: ${res.error.message}` })
        return
      }
      if (typeof res.value.source_revision === 'string') {
        setSourceRevision(res.value.source_revision)
        if (typeof res.value.source_text === 'string' && typeof res.value.path === 'string') {
          setRawConfig({
            sourceText: res.value.source_text,
            sourceRevision: res.value.source_revision,
            sourcePath: res.value.path,
            epoch: readEpoch,
            signal: read.signal,
          })
          setBanner((previous) => previous?.kind === 'lane-source-error' ? null : previous)
          return
        }
      }
      setBanner({ kind: 'lane-source-error', text: 'runtime.toml 원본의 경로, 리비전 또는 내용을 받지 못했습니다.' })
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
    setSourceRevision(null)
    setLaneEditor(null)
    setLaneDeleteConfirm(null)
    return () => {
      sourceRead.current?.abort()
      previewRequest.current?.abort()
    }
  }, [epoch])

  useEffect(() => {
    if (mode === 'failover') loadFailover(false, 'mount')
    else if (mode === 'exact') loadExact('mount')
    else loadFusion('mount')
  }, [mode, runKindFilter, currentCursor, epoch])

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
        <span class="mono" style=${{ ...statusPillStyle(r.status), padding: 'var(--sp-0) var(--sp-2)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
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
        <span class="mono" style=${{ ...statusPillStyle(r.status), padding: 'var(--sp-0) var(--sp-2)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
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

  const declaredTomlLanes = useMemo<readonly ParsedTomlLane[]>(() => {
    if (rawConfig) return parseLanesFromToml(rawConfig.sourceText)
    if (!resolvedData) return []
    return resolvedData.lanes.map((lane) => ({
      kind: 'failover' as const,
      id: lane.id,
      candidates: lane.runtime_ids,
    }))
  }, [rawConfig, resolvedData])

  const availableRuntimeIds = useMemo<readonly string[]>(() => {
    const ids = new Set<string>()
    for (const rt of resolvedData?.runtimes ?? []) {
      if (rt.id) ids.add(rt.id)
    }
    for (const p of probeData?.probe.providers ?? []) {
      if (p.runtime_id) ids.add(p.runtime_id)
    }
    return [...ids]
  }, [resolvedData, probeData])

  const previewProposedLaneToml = async (nextToml: string, label: string) => {
    const snapshot = rawConfig
    if (!snapshot || !isCurrentLaneSource(snapshot)) {
      setBanner({ kind: 'err', text: 'runtime.toml 원본을 불러오지 못해 미리보기를 실행할 수 없습니다.' })
      return
    }
    discardLanePreview()
    const request = new AbortController()
    previewRequest.current = request
    setBusy('lane-preview')
    setBanner(null)
    setLaneCasConflict(null)
    const res = await apiMutate<{
      readonly ok?: boolean
      readonly can_save?: boolean
      readonly runtime_validation?: string | null
      readonly validation?: {
        readonly issues?: readonly {
          readonly severity?: string
          readonly key?: string
          readonly detail?: string
          readonly message?: string
        }[]
      }
    }>('POST', '/api/v1/runtime/config/raw/preview', { source_text: nextToml }, { signal: request.signal })
    if (request.signal.aborted || !isCurrentLaneSource(snapshot)) return
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `레인 검증 미리보기 실패: ${res.error.message}` })
      return
    }
    const rawIssues = Array.isArray(res.value.validation?.issues) ? res.value.validation.issues : []
    const validationIssues = rawIssues
      .map((issue) => {
        const sev = typeof issue.severity === 'string' && issue.severity.trim() ? `[${issue.severity.trim()}] ` : ''
        const key = typeof issue.key === 'string' && issue.key.trim() ? `${issue.key.trim()}: ` : ''
        const detail = typeof issue.detail === 'string' && issue.detail.trim()
          ? issue.detail.trim()
          : typeof issue.message === 'string' && issue.message.trim()
            ? issue.message.trim()
            : ''
        return `${sev}${key}${detail}`.trim()
      })
      .filter(Boolean)
    const diff = buildLaneUnifiedDiff(snapshot.sourceText, nextToml, snapshot.sourcePath)
    setLanePreview({
      source: snapshot,
      nextToml,
      diff,
      canSave: res.value.can_save === true,
      runtimeValidation: typeof res.value.runtime_validation === 'string' && res.value.runtime_validation.trim()
        ? res.value.runtime_validation.trim()
        : null,
      validationIssues,
      label,
    })
  }

  const handlePreviewLaneEditor = async (ev: Event) => {
    ev.preventDefault()
    if (!laneEditor || !rawConfig) return
    const parsedMaxTokens = laneEditor.kind === 'exact_output' && laneEditor.maxOutputTokens.trim()
      ? Number.parseInt(laneEditor.maxOutputTokens.trim(), 10)
      : null
    if (
      laneEditor.kind === 'exact_output'
      && laneEditor.maxOutputTokens.trim()
      && (!Number.isSafeInteger(parsedMaxTokens) || (parsedMaxTokens ?? 0) <= 0)
    ) {
      setBanner({ kind: 'err', text: 'max_output_tokens는 양의 정수를 입력하세요.' })
      return
    }
    const upserted = upsertLaneInToml(rawConfig.sourceText, {
      kind: laneEditor.kind,
      id: laneEditor.id,
      candidates: laneEditor.candidates,
      maxOutputTokens: laneEditor.kind === 'exact_output' ? parsedMaxTokens : undefined,
    })
    if (!upserted.ok) {
      setBanner({ kind: 'err', text: upserted.error })
      return
    }
    await previewProposedLaneToml(
      upserted.value,
      `${laneEditor.mode === 'create' ? '생성' : '수정'}: ${laneEditor.id.trim()} (${laneEditor.kind})`,
    )
  }

  const handlePreviewLaneDelete = async (kind: EditableLaneKind, id: string) => {
    if (!rawConfig) return
    const deleted = deleteLaneFromToml(rawConfig.sourceText, kind, id)
    if (!deleted.ok) {
      setBanner({ kind: 'err', text: deleted.error })
      return
    }
    await previewProposedLaneToml(deleted.value, `삭제: ${id} (${kind})`)
  }

  const handleApplyLanePreview = async () => {
    if (!lanePreview?.canSave || !isCurrentLaneSource(lanePreview.source)) return
    setBusy('lane-apply')
    setBanner(null)
    setLaneCasConflict(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/runtime/config/raw', {
      source_text: lanePreview.nextToml,
      expected_source_revision: lanePreview.source.sourceRevision,
      expected_source_path: lanePreview.source.sourcePath,
    })
    if (!isCurrentLaneSource(lanePreview.source)) return
    setBusy(null)
    if (!res.ok) {
      if (res.error.kind === 'conflict_cas') {
        setLaneCasConflict(res.error.message || 'runtime.toml이 외부에서 변경되었습니다 (409 revision_conflict).')
      } else {
        setBanner({ kind: 'err', text: `runtime.toml 저장 실패: ${res.error.message}` })
      }
      return
    }
    setBanner({ kind: 'ok', text: `레인 변경(${lanePreview.label})이 runtime.toml에 CAS 저장되었습니다.` })
    discardLanePreview()
    setLaneEditor(null)
    setLaneDeleteConfirm(null)
    loadFailover(false, 'manual')
  }

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
          class=${banner.kind === 'ok' ? 'wka-card' : 'ap-error'}
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
                  style=${{ flex: 1, minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
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
                  style=${{ flex: '1 1 120px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <input
                  type="text"
                  aria-label="할당할 Runtime ID"
                  value=${assignRuntime}
                  onInput=${(e: Event) => setAssignRuntime((e.target as HTMLInputElement).value)}
                  placeholder="runtime_id (비우면 기본값)"
                  style=${{ flex: '1 1 140px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <button type="submit" class="btn-primary" disabled=${busy === 'assignment'}>할당</button>
              </div>
            </form>
          </section>

          <!-- Visual Runtime Lane CRUD (/api/v1/runtime/config/raw + /raw/preview, zero $EDITOR) -->
          <section class="wka-card" data-testid="visual-lane-crud" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
            <div class="wka-h">
              <div>
                <h3 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>선언된 레인 CRUD (Failover · Exact Output · CAS Diff)</h3>
                <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                  ${rawConfig
                    ? `runtime.toml rev ${rawConfig.sourceRevision.slice(0, 12)} · ${declaredTomlLanes.length}개 레인`
                    : `${declaredTomlLanes.length}개 레인 (raw 스냅샷 대기 중)`}
                </span>
              </div>
              <button
                type="button"
                class="btn-primary"
                disabled=${!rawConfig}
                onClick=${() => {
                  setLaneDeleteConfirm(null)
                  discardLanePreview()
                  setLaneEditor({
                    mode: 'create',
                    kind: 'failover',
                    id: '',
                    candidates: availableRuntimeIds[0] ? [availableRuntimeIds[0]] : [],
                    newCandidate: '',
                    maxOutputTokens: '8192',
                  })
                }}
              >
                + 새 레인
              </button>
            </div>

            ${laneCasConflict && html`
              <div class="ap-error" role="alert" data-testid="lane-cas-conflict" style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                <span>⚠ 409 CAS 충돌: ${laneCasConflict}</span>
                <button
                  type="button"
                  class="btn-primary"
                  onClick=${() => {
                    setLaneCasConflict(null)
                    discardLanePreview()
                    loadFailover(false, 'manual')
                  }}
                >
                  최신 runtime.toml 다시 불러오기
                </button>
              </div>
            `}

            ${declaredTomlLanes.length === 0
              ? html`<div class="dtable-absent">선언된 레인이 없습니다. "+ 새 레인"을 눌러 첫 레인을 만드세요.</div>`
              : html`
                  <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
                    ${declaredTomlLanes.map((lane) => html`
                      <div
                        key=${`${lane.kind}:${lane.id}`}
                        data-lane-row=${`${lane.kind}:${lane.id}`}
                        style=${{
                          display: 'flex',
                          justifyContent: 'space-between',
                          alignItems: 'center',
                          gap: 'var(--sp-2)',
                          padding: 'var(--sp-2) var(--sp-3)',
                          borderRadius: 'var(--radius-sm)',
                          border: '1px solid var(--line-1)',
                          background: 'var(--bg-2)',
                          flexWrap: 'wrap',
                        }}
                      >
                        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', minWidth: 0 }}>
                          <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                            <span class="mono" style=${{ fontWeight: 600, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>${lane.id}</span>
                            <span class="mono" style=${{ fontSize: 'var(--fs-10)', padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-pill)', background: lane.kind === 'failover' ? 'var(--brass-soft)' : 'var(--info-soft)', color: lane.kind === 'failover' ? 'var(--brass-1)' : 'var(--info-fg)' }}>
                              ${lane.kind}
                            </span>
                            ${lane.maxOutputTokens !== undefined && html`
                              <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>max_tokens=${lane.maxOutputTokens}</span>
                            `}
                          </div>
                          <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)', overflowWrap: 'anywhere' }}>
                            ${lane.candidates.length > 0 ? lane.candidates.join(' → ') : '(후보 없음)'}
                          </div>
                        </div>
                        <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexShrink: 0 }}>
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${!rawConfig}
                            onClick=${() => {
                              setLaneDeleteConfirm(null)
                              discardLanePreview()
                              setLaneEditor({
                                mode: 'edit',
                                kind: lane.kind,
                                id: lane.id,
                                candidates: [...lane.candidates],
                                newCandidate: '',
                                maxOutputTokens: lane.maxOutputTokens ? String(lane.maxOutputTokens) : '',
                              })
                            }}
                          >
                            편집
                          </button>
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${!rawConfig}
                            style=${{ color: 'var(--err-fg)' }}
                            onClick=${() => {
                              setLaneEditor(null)
                              discardLanePreview()
                              setLaneDeleteConfirm({ kind: lane.kind, id: lane.id })
                            }}
                          >
                            삭제
                          </button>
                        </div>
                      </div>
                    `)}
                  </div>
                `}

            ${laneEditor && html`
              <form
                data-testid="lane-editor-form"
                onSubmit=${handlePreviewLaneEditor}
                style=${{
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 'var(--sp-2)',
                  padding: 'var(--sp-3)',
                  borderRadius: 'var(--radius-sm)',
                  border: '1px solid var(--brass-border)',
                  background: 'var(--bg-1)',
                }}
              >
                <div class="wka-h">
                  <strong style=${{ fontSize: 'var(--fs-13)' }}>
                    ${laneEditor.mode === 'create' ? '새 레인 생성' : `레인 편집 · ${laneEditor.id}`}
                  </strong>
                  <button type="button" class="btn-ghost" onClick=${() => { setLaneEditor(null); discardLanePreview() }}>닫기</button>
                </div>

                <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 'var(--sp-2)' }}>
                  <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                    <span>레인 종류</span>
                    <select
                      aria-label="레인 종류"
                      disabled=${laneEditor.mode === 'edit'}
                      value=${laneEditor.kind}
                      onChange=${(e: Event) => {
                        const kind = (e.target as HTMLSelectElement).value as EditableLaneKind
                        setLaneEditor((cur) => (cur ? { ...cur, kind } : null))
                        discardLanePreview()
                      }}
                      style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    >
                      <option value="failover">Failover Lane ([runtime.lanes.*])</option>
                      <option value="exact_output">Exact Output Lane ([runtime.exact_output_lanes.*])</option>
                    </select>
                  </label>

                  <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                    <span>레인 ID</span>
                    <input
                      type="text"
                      aria-label="레인 ID"
                      required
                      disabled=${laneEditor.mode === 'edit'}
                      placeholder="예: coding-fast"
                      value=${laneEditor.id}
                      onInput=${(e: Event) => {
                        const id = (e.target as HTMLInputElement).value
                        setLaneEditor((cur) => (cur ? { ...cur, id } : null))
                        discardLanePreview()
                      }}
                      class="mono"
                      style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    />
                  </label>

                  ${laneEditor.kind === 'exact_output' && html`
                    <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                      <span>max_output_tokens (선택)</span>
                      <input
                        type="number"
                        aria-label="max_output_tokens"
                        value=${laneEditor.maxOutputTokens}
                        onInput=${(e: Event) => {
                          const maxOutputTokens = (e.target as HTMLInputElement).value
                          setLaneEditor((cur) => (cur ? { ...cur, maxOutputTokens } : null))
                          discardLanePreview()
                        }}
                        class="mono tnum"
                        style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                      />
                    </label>
                  `}
                </div>

                <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
                  <span style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
                    후보 Runtime 순서 (${laneEditor.candidates.length}개 · 위에서 아래로 우선순위)
                  </span>
                  ${laneEditor.candidates.map((cand, idx) => html`
                    <div key=${`${cand}-${idx}`} data-lane-candidate=${cand} style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', padding: 'var(--sp-1) var(--sp-2)', borderRadius: 'var(--radius-sm)', border: '1px solid var(--line-1)', background: 'var(--bg-2)' }}>
                      <span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${idx + 1}. ${cand}</span>
                      <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
                        <button
                          type="button"
                          class="btn-ghost"
                          aria-label=${`${cand} 위로 이동`}
                          disabled=${idx === 0}
                          onClick=${() => {
                            setLaneEditor((cur) => (cur ? { ...cur, candidates: reorderCandidate(cur.candidates, idx, 'up') } : null))
                            discardLanePreview()
                          }}
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          class="btn-ghost"
                          aria-label=${`${cand} 아래로 이동`}
                          disabled=${idx === laneEditor.candidates.length - 1}
                          onClick=${() => {
                            setLaneEditor((cur) => (cur ? { ...cur, candidates: reorderCandidate(cur.candidates, idx, 'down') } : null))
                            discardLanePreview()
                          }}
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          class="btn-ghost"
                          aria-label=${`${cand} 후보 제거`}
                          style=${{ color: 'var(--err-fg)' }}
                          onClick=${() => {
                            setLaneEditor((cur) => (cur ? { ...cur, candidates: cur.candidates.filter((_, i) => i !== idx) } : null))
                            discardLanePreview()
                          }}
                        >
                          ×
                        </button>
                      </div>
                    </div>
                  `)}

                  <div style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                    <input
                      type="text"
                      list="lane-runtime-candidates"
                      aria-label="추가할 후보 Runtime ID"
                      placeholder="provider.model-id"
                      value=${laneEditor.newCandidate}
                      onInput=${(e: Event) => {
                        const newCandidate = (e.target as HTMLInputElement).value
                        setLaneEditor((cur) => (cur ? { ...cur, newCandidate } : null))
                      }}
                      class="mono"
                      style=${{ flex: '1 1 200px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    />
                    <datalist id="lane-runtime-candidates">
                      ${availableRuntimeIds.map((rid) => html`<option key=${rid} value=${rid} />`)}
                    </datalist>
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${() => {
                        const next = laneEditor.newCandidate.trim()
                        if (!next) return
                        setLaneEditor((cur) => {
                          if (!cur) return null
                          if (cur.candidates.includes(next)) return { ...cur, newCandidate: '' }
                          return { ...cur, candidates: [...cur.candidates, next], newCandidate: '' }
                        })
                        discardLanePreview()
                      }}
                    >
                      + 후보 추가
                    </button>
                  </div>
                </div>

                <div style=${{ display: 'flex', gap: 'var(--sp-2)', justifyContent: 'flex-end' }}>
                  <button type="submit" class="btn-primary" disabled=${busy === 'lane-preview'}>
                    ${busy === 'lane-preview' ? '검증 중…' : 'Diff 미리보기 (Preview)'}
                  </button>
                </div>
              </form>
            `}

            ${laneDeleteConfirm && html`
              <div
                data-testid="lane-delete-confirm"
                role="alert"
                style=${{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: 'var(--sp-2)',
                  flexWrap: 'wrap',
                  padding: 'var(--sp-2) var(--sp-3)',
                  borderRadius: 'var(--radius-sm)',
                  border: '1px solid var(--err-border)',
                  background: 'var(--err-soft)',
                }}
              >
                <span style=${{ fontSize: 'var(--fs-12)', color: 'var(--err-fg)' }}>
                  <strong>${laneDeleteConfirm.id}</strong> (${laneDeleteConfirm.kind}) 레인을 <code>runtime.toml</code>에서 삭제할까요?
                </span>
                <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
                  <button type="button" class="btn-ghost" onClick=${() => setLaneDeleteConfirm(null)}>취소</button>
                  <button
                    type="button"
                    class="btn-primary"
                    disabled=${busy === 'lane-preview'}
                    onClick=${() => void handlePreviewLaneDelete(laneDeleteConfirm.kind, laneDeleteConfirm.id)}
                  >
                    삭제 Diff 미리보기
                  </button>
                </div>
              </div>
            `}

            ${lanePreview && html`
              <div
                data-testid="lane-diff-preview"
                style=${{
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 'var(--sp-2)',
                  padding: 'var(--sp-3)',
                  borderRadius: 'var(--radius-sm)',
                  border: '1px solid var(--info-border)',
                  background: 'var(--bg-1)',
                }}
              >
                <div class="wka-h">
                  <strong style=${{ fontSize: 'var(--fs-12)' }}>Unified Diff 미리보기 · ${lanePreview.label}</strong>
                  <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
                    <button type="button" class="btn-ghost" onClick=${() => discardLanePreview()}>취소</button>
                    <button
                      type="button"
                      class="btn-primary"
                      disabled=${!lanePreview.canSave || busy === 'lane-apply'}
                      onClick=${() => void handleApplyLanePreview()}
                    >
                      ${busy === 'lane-apply' ? '저장 중…' : '변경 적용 (CAS Save)'}
                    </button>
                  </div>
                </div>
                ${lanePreview.runtimeValidation && html`
                  <div class="ap-error" role="alert">런타임 검증 오류: ${lanePreview.runtimeValidation}</div>
                `}
                ${lanePreview.validationIssues.length > 0 && html`
                  <div class="ap-error" role="alert" data-testid="lane-validation-issues">
                    ${lanePreview.validationIssues.map((issue, idx) => html`
                      <div key=${idx}>스키마 검증 오류: ${issue}</div>
                    `)}
                  </div>
                `}
                ${!lanePreview.canSave && !lanePreview.runtimeValidation && lanePreview.validationIssues.length === 0 && html`
                  <div class="ap-error" role="alert">서버 미리보기 검증(can_save=false)을 통과하지 못해 저장할 수 없습니다.</div>
                `}
                <pre
                  class="mono"
                  style=${{
                    margin: 0,
                    padding: 'var(--sp-2)',
                    background: 'var(--bg-0)',
                    border: '1px solid var(--line-1)',
                    borderRadius: 'var(--radius-sm)',
                    fontSize: 'var(--fs-11)',
                    overflowX: 'auto',
                    lineHeight: 1.45,
                  }}
                >
                  ${lanePreview.diff}
                </pre>
              </div>
            `}
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
                        padding: 'var(--sp-0) var(--sp-1)',
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
                      <span class="mono" style=${{ ...statusPillStyle(r.status), padding: 'var(--sp-0) var(--sp-2)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)' }}>
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
                <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                  <span>Keeper</span>
                  <input
                    type="text"
                    required
                    value=${fusionKeeper}
                    onInput=${(e: Event) => setFusionKeeper((e.target as HTMLInputElement).value)}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  />
                </label>
                <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                  <span>토폴로지 (닫힌 합타입)</span>
                  <select
                    value=${fusionTopology}
                    onChange=${(e: Event) => setFusionTopology((e.target as HTMLSelectElement).value as FusionTopology)}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  >
                    ${FUSION_TOPOLOGIES.map((t) => html`<option key=${t.value} value=${t.value}>${t.label}</option>`)}
                  </select>
                </label>
                <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                  <span>프리셋 (선택)</span>
                  <input
                    type="text"
                    placeholder="기본 프리셋"
                    value=${fusionPreset}
                    onInput=${(e: Event) => setFusionPreset((e.target as HTMLInputElement).value)}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  />
                </label>
              </div>
              <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                <span>패널 질문 (Free Text)</span>
                <textarea
                  rows=${3}
                  required
                  value=${fusionPrompt}
                  onInput=${(e: Event) => setFusionPrompt((e.target as HTMLTextAreaElement).value)}
                  style=${{ padding: 'var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)', resize: 'vertical' }}
                />
              </label>
              <div style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--sp-2)' }}>
                <label style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
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
