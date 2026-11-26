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
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import { isEpochCurrent, sessionEpoch } from '../../core/auth'
import { markViewSynced } from '../../core/observer'
import { formatObserved, observedValue, resourceCache } from '../../core/resource-cache'
import { timeWindow, type TimeWindow } from '../../core/time-window'
import { apiGet, apiGetV2, apiMutate } from '../../core/transport'
import { InlineSpinner } from '../../components/common/inline-spinner'
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

const WORLD_KEY = 'kn:memory:world'
const MEMORY_TOPICS = ['memory', 'world_memory', 'librarian']

function memoryDiffKey(win: TimeWindow) {
  return `kn:memory:diff:${win}`
}

function loadWorld(reason: 'mount' | 'manual') {
  return resourceCache.fetch<WorldMemoryViewModel>(
    WORLD_KEY,
    async (signal) => {
      const world = await apiGetV2('/api/v1/memory/world', {
        signal,
        decode: (raw) => {
          const decoded = decodeWorldMemory(raw)
          if (!decoded.ok) throw new Error(decoded.error)
          return decoded.value
        },
      })
      if (world.ok || (world.error.kind !== 'not_found' && world.error.status !== 404)) return world
      return apiGet('/api/v1/dashboard/workspace-memory-inventory', {
        signal,
        decode: (raw) => {
          const decoded = decodeWorkspaceInventoryFallback(raw)
          if (!decoded.ok) throw new Error(decoded.error)
          return decoded.value
        },
      })
    },
    { ttlMs: 12_000, topics: MEMORY_TOPICS, reason },
  )
}

function loadMemoryDiff(win: TimeWindow, reason: 'mount' | 'manual') {
  return resourceCache.fetch<WorldDiffViewModel>(
    memoryDiffKey(win),
    (signal) => apiGetV2(buildWorldMemoryDiffUrl(win), {
      signal,
      decode: (raw) => {
        const decoded = decodeWorldDiff(raw)
        if (!decoded.ok) throw new Error(decoded.error)
        if (decoded.value.window !== win) throw new Error(`서버가 ${win} 기간에 해당하는 Diff를 반환하지 않았습니다.`)
        return decoded.value
      },
    }),
    { ttlMs: 12_000, topics: MEMORY_TOPICS, reason },
  )
}

function summarizeDiffEntry(entry: unknown, idx: number): string {
  if (typeof entry === 'string') {
    const trimmed = entry.trim()
    return trimmed ? trimmed.slice(0, 96) : `항목 #${idx + 1}`
  }
  if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
    const rec = entry as Record<string, unknown>
    const parts: string[] = []
    for (const key of ['claim', 'summary', 'title', 'claim_id', 'id', 'path', 'keeper', 'category']) {
      const val = rec[key]
      if (typeof val === 'string' && val.trim()) {
        parts.push(val.trim())
        if (parts.length >= 2) break
      }
    }
    if (parts.length > 0) return parts.join(' · ').slice(0, 120)
  }
  return `항목 #${idx + 1}`
}

export function MemoryTab(_props: WorkspaceViewProps) {
  const activeWin: TimeWindow = timeWindow.value
  const epoch = sessionEpoch.value
  const worldObs = resourceCache.observe<WorldMemoryViewModel>(WORLD_KEY).value
  const diffObs = resourceCache.observe<WorldDiffViewModel>(memoryDiffKey(activeWin)).value
  const world = worldObs.kind === 'value' ? worldObs.data : null
  const diffData = diffObs.kind === 'value' ? diffObs.data : null
  const [section, setSection] = useState<MemorySection>('claims')
  const visibleSection = world === null ? 'diff' : section
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

  useEffect(() => {
    void loadWorld('mount')
    setActBusy(null)
    setActFeedback(null)
    setActKeeper(null)
  }, [epoch])
  useEffect(() => {
    void loadMemoryDiff(activeWin, 'mount')
  }, [activeWin, epoch])
  useEffect(() => {
    if (worldObs.kind === 'value' && !worldObs.stale
        && diffObs.kind === 'value' && !diffObs.stale) markViewSynced()
  }, [worldObs, diffObs])

  const refresh = () => Promise.all([loadWorld('manual'), loadMemoryDiff(timeWindow.peek(), 'manual')])

  const executeRecoveryAct = async (
    keeper: string,
    kind: RecoveryActKind,
    override?: { observed?: string; turnLog?: string; line?: number; store?: string; at?: number; offset?: number },
  ) => {
    if (!isEpochCurrent(epoch)) return
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
    if (!isEpochCurrent(epoch)) return
    setActBusy(null)
    if (!res.ok) {
      const isRefused = res.error.status === 409
      setActFeedback({
        kind: isRefused ? 'warn' : 'err',
        message: `${keeper} (${kind}) ${isRefused ? '거부됨' : '실패'}: ${res.error.message}`,
      })
      return
    }
    const summary = typeof res.value === 'string' ? res.value : JSON.stringify(res.value)
    setActFeedback({
      kind: 'ok',
      message: `${keeper} → ${kind}: ${summary}`,
    })
    resourceCache.invalidateTopic('memory')
    await refresh()
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
        <div class="kn-stack-1">
          <span>${r.claim}</span>
          <span class="mono kn-sub-id">
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
          ? html`<span class="mono kn-sub-id">${r.snapshotSha.slice(0, 12)}… (${formatBytes(r.snapshotBytes)})</span>`
          : html`<span class="dtable-absent">없음</span>`,
    },
    {
      id: 'recovery',
      header: 'Recovery Acts',
      cell: (r) => html`
        <div class="kn-actions">
          <button
            type="button"
            class="btn-ghost kn-btn-compact"
            disabled=${actBusy !== null}
            onClick=${() => void executeRecoveryAct(r.keeper, 'resume')}
          >
            resume
          </button>
          ${r.snapshotSha && html`
            <button
              type="button"
              class="kn-btn-warn kn-btn-compact"
              disabled=${actBusy !== null}
              onClick=${() => void executeRecoveryAct(r.keeper, 'adopt', { observed: r.snapshotSha! })}
            >
              adopt
            </button>
          `}
          <button
            type="button"
            class="btn-ghost kn-btn-compact"
            onClick=${() => {
              setActKeeper(r.keeper)
              setActKind(r.snapshotSha ? 'adopt' : 'restart_reading')
              setActObserved(r.snapshotSha ?? '')
              setActTurnLog('')
              setActLine('0')
              setActStore('')
              setActAt('0')
              setActOffset('0')
            }}
          >
            고급 복구…
          </button>
        </div>
      `,
    },
  ], [actBusy, epoch])

  const activeDiffList = diffData
    ? diffSubTab === 'added'
      ? diffData.added
      : diffSubTab === 'updated'
        ? diffData.updated
        : diffData.retracted
    : []

  const syncPill = (() => {
    const worldLoading = worldObs.kind === 'loading'
    const diffLoading = diffObs.kind === 'loading'
    const worldStale = worldObs.kind === 'value' && worldObs.stale
    const diffStale = diffObs.kind === 'value' && diffObs.stale
    const parts: string[] = []
    if (worldLoading && diffLoading) {
      parts.push('World Memory · Diff 불러오는 중…')
    } else if (worldLoading) {
      parts.push('World Memory 불러오는 중…')
    } else if (diffLoading) {
      parts.push(`${activeWin} 메모리 Diff 불러오는 중…`)
    }
    if (worldStale && diffStale) {
      parts.push('마지막 조회')
    } else if (worldStale) {
      parts.push('World Memory · 마지막 조회')
    } else if (diffStale) {
      parts.push(`${activeWin} Diff · 마지막 조회`)
    }
    if (parts.length === 0) return null
    return {
      tone: (worldStale || diffStale ? 'warn' : 'info') as 'warn' | 'info',
      loading: worldLoading || diffLoading,
      text: parts.join(' · '),
    }
  })()

  return html`
    <div class="kn-scroll-body">
      <div class="kn-toolbar">
        <div class="kn-chips">
          ${world && html`<span class="kn-badge kn-badge--info">
            ${world.sourceKind === 'world_memory_db'
              ? 'MVCC World DB'
              : world.sourceKind === 'workspace_inventory_fallback'
                ? 'Legacy Inventory Fallback'
                : 'Legacy Ledger'}
          </span>`}
          ${world?.ledgerSha256 && html`
            <span class="mono kn-sub-id">
              sha256:${world.ledgerSha256.slice(0, 12)}
            </span>
          `}
        </div>
        <div class="kn-toolbar-status-slot">
          ${syncPill && html`
            <span class=${`kn-status-pill kn-status-pill--${syncPill.tone}`} role="status" title=${syncPill.text}>
              ${syncPill.loading && html`<${InlineSpinner} size="xs" />`}
              <span class="kn-status-pill-text">${syncPill.text}</span>
            </span>
          `}
        </div>
        <div class="kn-actions">
          <button type="button" class="btn-ghost" onClick=${() => void refresh()}>새로고침</button>
        </div>
      </div>

      ${worldObs.kind === 'failed' && html`<div class="kn-notice kn-notice--err" role="alert">World Memory 조회 실패. ${worldObs.error.message}</div>`}
      ${(worldObs.kind === 'absent' || worldObs.kind === 'unreported') && html`<p role="status">서버에서 World Memory를 확인할 수 없습니다.</p>`}

      ${diffObs.kind === 'failed' && html`<div class="kn-notice kn-notice--err" role="alert">${activeWin} 메모리 Diff 조회 실패. ${diffObs.error.message}</div>`}
      ${(diffObs.kind === 'absent' || diffObs.kind === 'unreported') && html`<p role="status">서버에서 ${activeWin} 메모리 Diff를 확인할 수 없습니다.</p>`}

      ${(world || diffData) && html`
        <div class="ov-kpis">
          ${world && html`
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
          `}
          <div class="ov-kpi">
            <div class="ov-kpi-k">Window Diff (${activeWin})</div>
            <div class="ov-kpi-v kn-kpi-compact">
              ${formatObserved(diffObs, diff => `+${diff.counts.added} / ~${diff.counts.updated} / -${diff.counts.retracted}`)}
            </div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Retrieval Heat (H/W/C/0x)</div>
            <div class="ov-kpi-v kn-kpi-compact">
              ${formatObserved(diffObs, ({ retrievalHeat }) => `${retrievalHeat.hot}/${retrievalHeat.warm}/${retrievalHeat.cold}/${retrievalHeat.neverRetrieved}`)}
            </div>
          </div>
          ${world?.worldMvcc && html`
            <div class="ov-kpi">
              <div class="ov-kpi-k">MVCC Rev / Edges</div>
              <div class="ov-kpi-v kn-kpi-compact">
                r${world.worldMvcc.digestRevision ?? '없음'} · ${world.worldMvcc.edgesCount}
              </div>
            </div>
          `}
        </div>
      `}

      ${diffData && html`<${UPlotChart}
          id="world-memory-flow"
          title=${`Memory Flow (Added ▲ / Retracted ▼ vs Net Total · ${activeWin})`}
          subtitle=${html`<span class="mono kn-sub-id">scope=world · window=${activeWin}</span>`}
          data=${flowChartData}
          series=${MEMORY_FLOW_SERIES}
          height=${210}
          emptyLabel="선택한 기간 내 메모리 변동 틱이 없습니다."
      />`}

      ${world && html`
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
                  ${world.briefing.buildingRemaining === null
                    ? '브리핑 생성 중'
                    : `브리핑 생성 중 · ${world.briefing.buildingTarget - world.briefing.buildingRemaining}/${world.briefing.buildingTarget}`}
                </span>
              `}
            </div>
          </div>
          ${world.briefing.error && html`<div class="kn-notice kn-notice--err">${world.briefing.error}</div>`}
          ${world.briefing.text
            ? html`<${MarkdownContent} class="kn-body-md" text=${world.briefing.text} />`
            : html`<span class="dtable-absent">World Briefing 본문이 아직 생성되지 않았습니다.</span>`}
        </section>
      `}

      ${(world || diffData) && html`
        <div class="kn-chips" role="tablist" aria-label="World Memory 상세 섹션">
          ${world && html`
            <button type="button" role="tab" class="kn-chip" aria-selected=${visibleSection === 'claims'} onClick=${() => setSection('claims')}>
              Claims <span class="kn-chip-count">${world.claims.length}</span>
            </button>
            <button type="button" role="tab" class="kn-chip" aria-selected=${visibleSection === 'conflicts'} onClick=${() => setSection('conflicts')}>
              Active Conflicts <span class="kn-chip-count">${world.activeConflicts.length}</span>
            </button>
          `}
          <button type="button" role="tab" class="kn-chip" aria-selected=${visibleSection === 'diff'} onClick=${() => setSection('diff')}>
            Temporal Diff (${activeWin})
          </button>
          ${world && html`<button type="button" role="tab" class="kn-chip" aria-selected=${visibleSection === 'writers'} onClick=${() => setSection('writers')}>
            Librarian Writers <span class="kn-chip-count">${world.writers.length}</span>
          </button>`}
        </div>

        ${world && visibleSection === 'claims' && html`
          <${DataTable}
            data=${world.claims}
            columns=${claimColumns}
            getRowId=${(r: WorldClaimRow) => r.claimId}
            caption="World Memory Claims 목록"
            emptyLabel="기록된 World Claim이 없습니다."
          />
        `}

        ${world && visibleSection === 'conflicts' && html`
          <div class="kn-stack-2" role="region" aria-label="Side-by-Side Active Conflicts Inspector">
            <div class="kn-notice kn-notice--info" role="note">
              읽기 전용 충돌 검사기 (Read-Only): 현재 서버에는 World Memory 충돌 해소 쓰기 API가 노출되어 있지 않습니다. 허위 해소 버튼을 제공하지 않으며, 각 Keeper의 원천 사실과 경합 주장을 나란히 비교할 수 있습니다.
            </div>
            ${world.activeConflicts.length === 0
              ? html`<div class="kn-section"><span class="dtable-absent">활성 메모리 충돌이 없습니다 (0).</span></div>`
              : world.activeConflicts.map((cf) => html`
                  <section key=${cf.conflictId} class="kn-section">
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
                          <${MarkdownContent} class="kn-body-md" text=${cc.claim ?? '(원문 미해석)'} />
                          <div class="kn-row-meta mono">
                            <span>sha:${cc.claimSha256.slice(0, 10)}</span>
                            ${cc.path && html`<span>${cc.path}</span>`}
                            ${cc.resolved && html`<span class="kn-badge kn-badge--ok">resolved</span>`}
                          </div>
                        </article>
                      `)}
                    </div>
                  </section>
                `)}
          </div>
        `}

        ${visibleSection === 'diff' && html`
          <section class="kn-section" aria-label="Temporal Memory Diff">
            <div class="kn-toolbar">
              <div class="kn-chips" role="group" aria-label="Diff 유형">
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'added'} onClick=${() => setDiffSubTab('added')}>
                  Added <span class="kn-chip-count">${diffData ? diffData.counts.added : '—'}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'updated'} onClick=${() => setDiffSubTab('updated')}>
                  Updated <span class="kn-chip-count">${diffData ? diffData.counts.updated : '—'}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${diffSubTab === 'retracted'} onClick=${() => setDiffSubTab('retracted')}>
                  Retracted <span class="kn-chip-count">${diffData ? diffData.counts.retracted : '—'}</span>
                </button>
              </div>
              ${diffData && (diffData.counts.incompleteBatches > 0 || diffData.counts.abortedBatches > 0) && html`
                <span class="kn-badge kn-badge--warn">
                  Incomplete: ${diffData.counts.incompleteBatches} · Aborted: ${diffData.counts.abortedBatches}
                </span>
              `}
            </div>
            ${diffData !== null && (activeDiffList.length === 0
              ? html`<span class="dtable-absent">${activeWin} 기간 내 ${diffSubTab} 항목이 없습니다.</span>`
              : activeDiffList.map((entry, idx) => html`
                  <details key=${idx} class="ap-disclosure" data-testid="memory-diff-entry">
                    <summary class="ap-disclosure-trigger">
                      <span class="kn-diff-summary-text">${summarizeDiffEntry(entry, idx)}</span>
                      <span class="mono kn-sub-id">JSON ▸</span>
                    </summary>
                    <div class="ap-disclosure-body">
                      <pre class="kn-diff-box">${JSON.stringify(entry, null, 2)}</pre>
                    </div>
                  </details>
                `))}
          </section>
        `}

        ${world && visibleSection === 'writers' && html`
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
                class="kn-section kn-recovery-box"
                onSubmit=${(e: Event) => {
                  e.preventDefault()
                  void executeRecoveryAct(actKeeper, actKind)
                }}
              >
                <div class="kn-section-head">
                  <strong>Recovery Act — ${actKeeper} (POST /api/v1/keepers/${actKeeper}/memory/act)</strong>
                  <button type="button" class="btn-ghost" onClick=${() => setActKeeper(null)}>닫기</button>
                </div>
                <div class="kn-grid-auto">
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
