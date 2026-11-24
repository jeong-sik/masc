/**
 * `3 Knowledge > World Memory & Librarian` Tab (`memory-tab.ts` — BRAND NEW!)
 *
 * - Wired to `GET /api/v1/memory/world` (`V2Envelope`, handles both MVCC DB & legacy ledger shapes per `#36`,
 *   with graceful 404 fallback to `/api/v1/dashboard/workspace-memory-inventory`).
 * - Wired to `GET /api/v1/memory/diff?scope=world&window=24h|7d|30d` (ALWAYS passes `scope=world`,
 *   automatically synced to the global `timeWindow` signal!).
 * - `UPlotChart` Memory Flow (`Added ▲ / Retracted ▼` vs `Net Total`, shared `masc-telemetry` crosshair).
 * - World Briefing + Claims `DataTable` (support count + Source-Bound badge).
 * - Side-by-Side Active Conflicts Inspector with honest read-only notice (`#24` A+5).
 * - Temporal Diff (`added | updated | retracted`).
 * - Librarian Writers Status Table with direct 1-click Recovery Acts
 *   (`POST /api/v1/keepers/:k/memory/act`: `resume | adopt | restart_reading | skip_item | skip_line`).
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import { markViewSynced } from '../../core/observer'
import { observedValue, resourceCache } from '../../core/resource-cache'
import { TIME_WINDOWS, setTimeWindow, timeWindow, type TimeWindow } from '../../core/time-window'
import { apiGet, apiGetV2, apiMutate } from '../../core/transport'
import { err, ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  DataTable,
  UPlotChart,
  type DataTableColumn,
  type UPlotSeriesSpec,
} from '../../components/primitives'
import {
  buildMemoryFlowSeries,
  buildMemoryRecoveryPayload,
  buildWorldMemoryDiffUrl,
  decodeWorkspaceInventoryFallback,
  decodeWorldDiff,
  decodeWorldMemory,
  formatBytes,
  type LibrarianWriterRow,
  type WorldClaimRow,
  type WorldDiffViewModel,
  type WorldMemoryViewModel,
  type WorkspaceViewProps,
} from './types'

type MemorySection = 'claims' | 'conflicts' | 'diff' | 'writers'
type RecoveryActKind = 'resume' | 'adopt' | 'restart_reading' | 'skip_item' | 'skip_line'

const MEMORY_FLOW_SERIES: readonly UPlotSeriesSpec[] = [
  { label: 'Added ▲', colorToken: '--ok-fg', width: 1.75, fillAlpha: 0.14 },
  { label: 'Retracted ▼', colorToken: '--err-fg', width: 1.75, fillAlpha: 0.12 },
  { label: 'Net Total', colorToken: '--info-fg', width: 2.0 },
]

export function MemoryTab(_props: WorkspaceViewProps) {
  const activeWin: TimeWindow = timeWindow.value
  const [world, setWorld] = useState<WorldMemoryViewModel | null>(null)
  const [diffData, setDiffData] = useState<WorldDiffViewModel | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [section, setSection] = useState<MemorySection>('claims')
  const [diffSubTab, setDiffSubTab] = useState<'added' | 'updated' | 'retracted'>('added')

  // Librarian Recovery Act panel state
  const [actKeeper, setActKeeper] = useState<string | null>(null)
  const [actKind, setActKind] = useState<RecoveryActKind>('adopt')
  const [actObserved, setActObserved] = useState('')
  const [actTurnLog, setActTurnLog] = useState('')
  const [actLine, setActLine] = useState('0')
  const [actStore, setActStore] = useState('')
  const [actAt, setActAt] = useState('0')
  const [actOffset, setActOffset] = useState('0')
  const [actBusy, setActBusy] = useState<string | null>(null)
  const [actFeedback, setActFeedback] = useState<{ kind: 'ok' | 'err' | 'warn'; message: string } | null>(null)

  const loadWorldAndDiff = useCallback(async (win: TimeWindow, reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const diffUrl = buildWorldMemoryDiffUrl(win)
    const obs = await resourceCache.fetch<{ world: WorldMemoryViewModel; diff: WorldDiffViewModel | null }>(
      `kn:memory:world:${win}`,
      async (signal) => {
        const [worldRes, diffRes] = await Promise.all([
          apiGetV2<unknown>('/api/v1/memory/world', { signal }),
          apiGetV2<unknown>(diffUrl, { signal }),
        ])

        let decodedWorld: WorldMemoryViewModel | null = null
        if (worldRes.ok) {
          const dec = decodeWorldMemory(worldRes.value)
          if (!dec.ok) {
            return err({
              kind: 'decode',
              status: 200,
              code: 'world_memory_decode',
              message: dec.error,
              retryable: false,
            })
          }
          decodedWorld = dec.value
        } else if (worldRes.error.kind === 'not_found' || worldRes.error.status === 404) {
          // Graceful fallback to legacy workspace-memory-inventory per TUI `#6`
          const fallbackRes = await apiGet<unknown>('/api/v1/dashboard/workspace-memory-inventory', { signal })
          if (!fallbackRes.ok) return fallbackRes
          const dec = decodeWorkspaceInventoryFallback(fallbackRes.value)
          if (!dec.ok) {
            return err({
              kind: 'decode',
              status: 200,
              code: 'inventory_decode',
              message: dec.error,
              retryable: false,
            })
          }
          decodedWorld = dec.value
        } else {
          return worldRes
        }

        let decodedDiff: WorldDiffViewModel | null = null
        if (diffRes.ok) {
          const d = decodeWorldDiff(diffRes.value)
          if (d.ok) decodedDiff = d.value
        }

        return ok({ world: decodedWorld, diff: decodedDiff })
      },
      { ttlMs: 12_000, topics: ['memory', 'world_memory', 'librarian'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setWorld(obs.data.world)
      setDiffData(obs.data.diff)
      markViewSynced()
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [])

  useEffect(() => {
    void loadWorldAndDiff(activeWin, 'mount')
  }, [activeWin, loadWorldAndDiff])

  const executeRecoveryAct = async (
    keeper: string,
    kind: RecoveryActKind,
    override?: { observed?: string; turnLog?: string; line?: number; store?: string; at?: number; offset?: number },
  ) => {
    const payloadRes = buildMemoryRecoveryPayload({
      action: kind,
      observed: override?.observed ?? actObserved,
      turnLog: override?.turnLog ?? actTurnLog,
      line: override?.line ?? Number(actLine),
      store: override?.store ?? actStore,
      at: override?.at ?? (actStore.trim() ? Number(actAt) : undefined),
      offset: override?.offset ?? Number(actOffset),
    })
    if (!payloadRes.ok) {
      setActFeedback({ kind: 'err', message: payloadRes.error })
      return
    }
    setActBusy(`${keeper}:${kind}`)
    setActFeedback(null)
    const res = await apiMutate<unknown>(
      'POST',
      `/api/v1/keepers/${encodeURIComponent(keeper)}/memory/act`,
      payloadRes.value,
    )
    setActBusy(null)
    if (!res.ok) {
      setActFeedback({ kind: 'err', message: `${keeper} (${kind}) 실패: ${res.error.message}` })
      return
    }
    const summary = typeof res.value === 'string' ? res.value : JSON.stringify(res.value)
    const isRefused = typeof summary === 'string' && summary.includes('refused')
    setActFeedback({
      kind: isRefused ? 'warn' : 'ok',
      message: `${keeper} → ${kind}: ${summary}`,
    })
    resourceCache.invalidateTopic('memory')
    await loadWorldAndDiff(activeWin, 'manual')
  }

  const flowChartData = useMemo<uPlot.AlignedData>(() => {
    if (!diffData) return [[], [], [], []]
    const s = buildMemoryFlowSeries(diffData)
    return [s.timestamps, s.added, s.retracted, s.netTotal]
  }, [diffData])

  const claimColumns = useMemo<readonly DataTableColumn<WorldClaimRow>[]>(() => [
    {
      id: 'claim',
      header: 'Claim',
      sortable: true,
      sortValue: (r) => r.claim,
      cell: (r) => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', minWidth: 0 }}>
          <span>${r.claim}</span>
          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            ${r.claimId}${r.category ? ` · ${r.category}` : ''}${r.scope ? ` · ${r.scope}` : ''}
          </span>
        </div>
      `,
    },
    {
      id: 'stage',
      header: 'Stage',
      sortable: true,
      accessor: (r) => r.stage,
      cell: (r) => html`<span class="kn-badge">${r.stage}</span>`,
    },
    {
      id: 'supportCount',
      header: 'Support',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.supportCount,
      observed: (r) => observedValue(r.supportCount),
    },
    {
      id: 'sourceBound',
      header: '근거 유형',
      cell: (r) => r.hasSourceBound
        ? html`<span class="kn-badge kn-badge--ok">Source-Bound</span>`
        : html`<span class="kn-badge kn-badge--idle">Ordinary</span>`,
    },
    {
      id: 'keepers',
      header: '지지 Keeper',
      cell: (r) => r.supportingKeepers.length === 0
        ? html`<span class="dtable-absent">없음</span>`
        : html`
            <div class="kn-chips">
              ${r.supportingKeepers.slice(0, 4).map((k) => html`<${KeeperBadge} key=${k} id=${k} size="sm" />`)}
              ${r.supportingKeepers.length > 4 && html`<span class="kn-chip-count">+${r.supportingKeepers.length - 4}</span>`}
            </div>
          `,
    },
  ], [])

  const writerColumns = useMemo<readonly DataTableColumn<LibrarianWriterRow>[]>(() => [
    {
      id: 'keeper',
      header: 'Keeper',
      sortable: true,
      sortValue: (r) => r.keeper,
      cell: (r) => html`<${KeeperBadge} id=${r.keeper} portrait=${true} size="sm" />`,
    },
    {
      id: 'state',
      header: 'Writer State',
      sortable: true,
      accessor: (r) => r.state,
      cell: (r) => {
        const tone = r.state === 'open' || r.state === 'idle'
          ? 'ok'
          : r.state === 'stopped' || r.state === 'refused_at_bottom'
            ? 'err'
            : 'warn'
        return html`
          <span class=${`kn-badge kn-badge--${tone}`}>
            ${r.state}${r.stopReason ? ` (${r.stopReason})` : ''}
          </span>
        `
      },
    },
    {
      id: 'snapshot',
      header: 'Snapshot File',
      cell: (r) => r.snapshotFault
        ? html`<span class="kn-badge kn-badge--err">Fault: ${r.snapshotFault}</span>`
        : r.snapshotSha
          ? html`<span class="mono" style=${{ fontSize: 'var(--fs-11)' }}>${r.snapshotSha.slice(0, 12)}… (${formatBytes(r.snapshotBytes)})</span>`
          : html`<span class="dtable-absent">없음</span>`,
    },
    {
      id: 'recovery',
      header: 'Recovery Acts',
      cell: (r) => html`
        <div class="kn-actions">
          <button
            type="button"
            class="btn-ghost"
            style=${{ padding: 'var(--sp-1) var(--sp-2)' }}
            disabled=${actBusy !== null}
            onClick=${() => void executeRecoveryAct(r.keeper, 'resume')}
          >
            resume
          </button>
          ${r.snapshotSha && html`
            <button
              type="button"
              class="kn-btn-warn"
              style=${{ padding: 'var(--sp-1) var(--sp-2)' }}
              disabled=${actBusy !== null}
              onClick=${() => void executeRecoveryAct(r.keeper, 'adopt', { observed: r.snapshotSha! })}
            >
              adopt
            </button>
          `}
          <button
            type="button"
            class="btn-ghost"
            style=${{ padding: 'var(--sp-1) var(--sp-2)' }}
            onClick=${() => {
              setActKeeper(r.keeper)
              setActKind(r.snapshotSha ? 'adopt' : 'restart_reading')
              setActObserved(r.snapshotSha ?? '')
            }}
          >
            고급 복구…
          </button>
        </div>
      `,
    },
  ], [actBusy])

  const activeDiffList = diffData
    ? diffSubTab === 'added'
      ? diffData.added
      : diffSubTab === 'updated'
        ? diffData.updated
        : diffData.retracted
    : []

  return html`
    <div class="kn-scroll-body">
      <div class="kn-toolbar">
        <div class="kn-chips">
          <span class="kn-badge kn-badge--info">
            ${world?.sourceKind === 'world_memory_db'
              ? 'MVCC World DB'
              : world?.sourceKind === 'workspace_inventory_fallback'
                ? 'Legacy Inventory Fallback'
                : 'Legacy Ledger'}
          </span>
          ${world?.ledgerSha256 && html`
            <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
              sha256:${world.ledgerSha256.slice(0, 12)}
            </span>
          `}
        </div>
        <div class="kn-actions">
          <div class="kn-chips" role="group" aria-label="전역 시간 창 (timeWindow)">
            ${TIME_WINDOWS.map((w) => html`
              <button
                key=${w}
                type="button"
                class="kn-chip mono"
                aria-pressed=${activeWin === w}
                onClick=${() => setTimeWindow(w)}
              >
                ${w}
              </button>
            `)}
          </div>
          <button type="button" class="btn-ghost" onClick=${() => void loadWorldAndDiff(activeWin, 'manual')}>새로고침</button>
        </div>
      </div>

      ${loadError && html`<div class="kn-notice kn-notice--err" role="alert">${loadError}</div>`}
      ${loading && !world && html`<span class="dtable-absent">World Memory 불러오는 중…</span>`}

      ${world && html`
        <div class="ov-kpis">
          <div class="ov-kpi">
            <div class="ov-kpi-k">Claims</div>
            <div class="ov-kpi-v">${world.ledgerState === 'missing' ? '없음' : String(world.claimsCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Facts</div>
            <div class="ov-kpi-v">${world.ledgerState === 'missing' ? '없음' : String(world.factsCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Active Conflicts</div>
            <div class=${`ov-kpi-v ${world.conflictsCount > 0 ? 'warn' : 'ok'}`}>${String(world.conflictsCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Window Diff (${activeWin})</div>
            <div class="ov-kpi-v" style=${{ fontSize: 'var(--fs-14)' }}>
              ${diffData ? `+${diffData.counts.added} / ~${diffData.counts.updated} / -${diffData.counts.retracted}` : '없음'}
            </div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Retrieval Heat (H/W/C/0x)</div>
            <div class="ov-kpi-v" style=${{ fontSize: 'var(--fs-14)' }}>
              ${diffData
                ? `${diffData.retrievalHeat.hot}/${diffData.retrievalHeat.warm}/${diffData.retrievalHeat.cold}/${diffData.retrievalHeat.neverRetrieved}`
                : '없음'}
            </div>
          </div>
          ${world.worldMvcc && html`
            <div class="ov-kpi">
              <div class="ov-kpi-k">MVCC Rev / Edges</div>
              <div class="ov-kpi-v" style=${{ fontSize: 'var(--fs-14)' }}>
                r${world.worldMvcc.digestRevision ?? '없음'} · ${world.worldMvcc.edgesCount}
              </div>
            </div>
          `}
        </div>

        <${UPlotChart}
          id="world-memory-flow"
          title=${`Memory Flow (Added ▲ / Retracted ▼ vs Net Total · ${activeWin})`}
          subtitle=${html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>scope=world · window=${activeWin}</span>`}
          data=${flowChartData}
          series=${MEMORY_FLOW_SERIES}
          height=${210}
          emptyLabel="선택한 기간 내 메모리 변동 틱이 없습니다."
        />

        <section class="kn-section" aria-label="World Briefing">
          <div class="kn-section-head">
            <h3 class="kn-section-title">World Briefing</h3>
            <div class="kn-chips">
              <span class=${`kn-badge ${world.briefing.status === 'current' ? 'kn-badge--ok' : world.briefing.status === 'stale' ? 'kn-badge--warn' : 'kn-badge--idle'}`}>
                ${world.briefing.status}
              </span>
              <span class="kn-badge">Sources: ${world.briefing.sourceIdsCount}</span>
              ${world.briefing.buildingTarget !== null && html`
                <span class="kn-badge kn-badge--info">
                  Building: ${world.briefing.buildingTarget - (world.briefing.buildingRemaining ?? 0)}/${world.briefing.buildingTarget}
                </span>
              `}
            </div>
          </div>
          ${world.briefing.error && html`<div class="kn-notice kn-notice--err">${world.briefing.error}</div>`}
          ${world.briefing.text
            ? html`<div style=${{ fontSize: 'var(--fs-13)', whiteSpace: 'pre-wrap' }}>${world.briefing.text}</div>`
            : html`<span class="dtable-absent">World Briefing 본문이 아직 생성되지 않았습니다.</span>`}
        </section>

        <div class="kn-chips" role="tablist" aria-label="World Memory 상세 섹션">
          <button type="button" role="tab" class="kn-chip" aria-selected=${section === 'claims'} aria-pressed=${section === 'claims'} onClick=${() => setSection('claims')}>
            Claims <span class="kn-chip-count">${world.claims.length}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${section === 'conflicts'} aria-pressed=${section === 'conflicts'} onClick=${() => setSection('conflicts')}>
            Active Conflicts <span class="kn-chip-count">${world.activeConflicts.length}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${section === 'diff'} aria-pressed=${section === 'diff'} onClick=${() => setSection('diff')}>
            Temporal Diff (${activeWin})
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${section === 'writers'} aria-pressed=${section === 'writers'} onClick=${() => setSection('writers')}>
            Librarian Writers <span class="kn-chip-count">${world.writers.length}</span>
          </button>
        </div>

        ${section === 'claims' && html`
          <${DataTable}
            data=${world.claims}
            columns=${claimColumns}
            getRowId=${(r: WorldClaimRow) => r.claimId}
            caption="World Memory Claims 목록"
            emptyLabel="기록된 World Claim이 없습니다."
          />
        `}

        ${section === 'conflicts' && html`
          <section class="kn-section" aria-label="Side-by-Side Active Conflicts Inspector">
            <div class="kn-notice kn-notice--info" role="note">
              읽기 전용 충돌 검사기 (Read-Only): 현재 서버에는 World Memory 충돌 해소 쓰기 API가 노출되어 있지 않습니다. 허위 해소 버튼을 제공하지 않으며, 각 Keeper의 원천 사실과 경합 주장을 나란히 비교할 수 있습니다.
            </div>
            ${world.activeConflicts.length === 0
              ? html`<span class="dtable-absent">활성 메모리 충돌이 없습니다 (0).</span>`
              : world.activeConflicts.map((cf) => html`
                  <div key=${cf.conflictId} class="kn-section" style=${{ background: 'var(--bg-1)' }}>
                    <div class="kn-section-head">
                      <strong>${cf.description || cf.conflictId}</strong>
                      <span class="kn-badge kn-badge--warn">경합 주장 ${cf.memberCount}건</span>
                    </div>
                    <div class="kn-conflict-grid">
                      ${cf.competingClaims.map((cc, idx) => html`
                        <article key=${`${cc.keeperId}-${cc.claimSha256}-${idx}`} class="kn-conflict-card">
                          <div class="kn-row-top">
                            <${KeeperBadge} id=${cc.keeperId} size="sm" />
                            <span class="kn-badge">${cc.storeKind}</span>
                          </div>
                          <div style=${{ fontSize: 'var(--fs-13)' }}>${cc.claim ?? '(원문 미해석)'}</div>
                          <div class="kn-row-meta mono">
                            <span>sha:${cc.claimSha256.slice(0, 10)}</span>
                            ${cc.path && html`<span>${cc.path}</span>`}
                            ${cc.resolved && html`<span class="kn-badge kn-badge--ok">resolved</span>`}
                          </div>
                        </article>
                      `)}
                    </div>
                  </div>
                `)}
          </section>
        `}

        ${section === 'diff' && html`
          <section class="kn-section" aria-label="Temporal Memory Diff">
            <div class="kn-toolbar">
              <div class="kn-chips" role="group" aria-label="Diff 유형">
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'added'} onClick=${() => setDiffSubTab('added')}>
                  Added <span class="kn-chip-count">${diffData?.counts.added ?? 0}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'updated'} onClick=${() => setDiffSubTab('updated')}>
                  Updated <span class="kn-chip-count">${diffData?.counts.updated ?? 0}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'retracted'} onClick=${() => setDiffSubTab('retracted')}>
                  Retracted <span class="kn-chip-count">${diffData?.counts.retracted ?? 0}</span>
                </button>
              </div>
              ${diffData && (diffData.counts.incompleteBatches > 0 || diffData.counts.abortedBatches > 0) && html`
                <span class="kn-badge kn-badge--warn">
                  Incomplete: ${diffData.counts.incompleteBatches} · Aborted: ${diffData.counts.abortedBatches}
                </span>
              `}
            </div>
            ${activeDiffList.length === 0
              ? html`<span class="dtable-absent">${activeWin} 기간 내 ${diffSubTab} 항목이 없습니다.</span>`
              : activeDiffList.map((entry, idx) => html`
                  <pre key=${idx} class="kn-diff-box">${JSON.stringify(entry, null, 2)}</pre>
                `)}
          </section>
        `}

        ${section === 'writers' && html`
          <section class="kn-section" aria-label="Librarian Writers 상태 및 복구">
            <div class="kn-section-head">
              <h3 class="kn-section-title">Librarian Writers Status & 1-Click Recovery Acts</h3>
              <div class="kn-chips">
                <span class=${`kn-badge ${world.writersMode === 'running' ? 'kn-badge--ok' : 'kn-badge--idle'}`}>
                  ${world.writersMode}
                </span>
                <span class="kn-badge kn-badge--err">Errors: ${world.writersErrorCount}</span>
                <span class="kn-badge kn-badge--warn">Warns: ${world.writersWarnCount}</span>
              </div>
            </div>

            ${actFeedback && html`
              <div class=${`kn-notice kn-notice--${actFeedback.kind}`} role="status">${actFeedback.message}</div>
            `}

            <${DataTable}
              data=${world.writers}
              columns=${writerColumns}
              getRowId=${(r: LibrarianWriterRow) => r.keeper}
              caption="Librarian Writer 상태 및 복구 작업"
              emptyLabel="이 프로세스에서 실행 중인 Librarian Writer가 없습니다."
            />

            ${actKeeper && html`
              <form
                class="kn-section"
                style=${{ background: 'var(--bg-1)', borderColor: 'var(--line-2)' }}
                onSubmit=${(e: Event) => {
                  e.preventDefault()
                  void executeRecoveryAct(actKeeper, actKind)
                }}
              >
                <div class="kn-section-head">
                  <strong>Recovery Act — ${actKeeper} (POST /api/v1/keepers/${actKeeper}/memory/act)</strong>
                  <button type="button" class="btn-ghost" onClick=${() => setActKeeper(null)}>닫기</button>
                </div>
                <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 'var(--sp-2)' }}>
                  <select
                    class="kn-select"
                    value=${actKind}
                    onChange=${(e: Event) => setActKind((e.target as HTMLSelectElement).value as RecoveryActKind)}
                    aria-label="복구 액션 선택"
                  >
                    <option value="resume">resume</option>
                    <option value="adopt">adopt (snapshot sha256)</option>
                    <option value="restart_reading">restart_reading (turn_log id)</option>
                    <option value="skip_item">skip_item (target)</option>
                    <option value="skip_line">skip_line (byte offset)</option>
                  </select>

                  ${(actKind === 'adopt' || actKind === 'restart_reading') && html`
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder=${actKind === 'adopt' ? 'snapshot SHA-256' : 'turn_log Log_started ID'}
                      value=${actObserved}
                      onInput=${(e: Event) => setActObserved((e.target as HTMLInputElement).value)}
                      aria-label="observed 값"
                    />
                  `}

                  ${actKind === 'skip_item' && html`
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder="turn_log ID"
                      value=${actTurnLog}
                      onInput=${(e: Event) => setActTurnLog((e.target as HTMLInputElement).value)}
                      aria-label="turn_log ID"
                    />
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="line offset"
                      value=${actLine}
                      onInput=${(e: Event) => setActLine((e.target as HTMLInputElement).value)}
                      aria-label="line offset"
                    />
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder="store (head_item일 때만)"
                      value=${actStore}
                      onInput=${(e: Event) => setActStore((e.target as HTMLInputElement).value)}
                      aria-label="store"
                    />
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="at index (head_item일 때만)"
                      value=${actAt}
                      onInput=${(e: Event) => setActAt((e.target as HTMLInputElement).value)}
                      aria-label="at index"
                    />
                  `}

                  ${actKind === 'skip_line' && html`
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="byte offset"
                      value=${actOffset}
                      onInput=${(e: Event) => setActOffset((e.target as HTMLInputElement).value)}
                      aria-label="byte offset"
                    />
                  `}
                </div>
                <div class="kn-actions">
                  <button type="submit" class="kn-btn-warn" disabled=${actBusy !== null}>
                    ${actBusy ? '실행 중…' : `${actKind} 실행`}
                  </button>
                </div>
              </form>
            `}
          </section>
        `}
      `}
    </div>
  `
}
