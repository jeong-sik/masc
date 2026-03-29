import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/empty-state'
import { StatusChip } from '../common/status-chip'
import { statusLabel as operationStatusLabel } from '../../lib/status-label'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  ChainHistoryEventSummary,
  CommandPlaneChainOverlay,
  CommandPlaneChainRunNode,
  CommandPlaneDetachmentCard,
  CommandPlaneOperationCard,
} from '../../types'
import {
  clearCommandPlaneChainRun,
  commandPlaneChainError,
  commandPlaneChainFocusOperationId,
  commandPlaneChainLoading,
  commandPlaneChainRun,
  commandPlaneChainRunError,
  commandPlaneChainRunLoading,
  commandPlaneChainSummary,
  commandPlaneSnapshot,
  focusCommandPlaneChainOperation,
  loadCommandPlaneChainRun,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
} from '../../command-store'
import { navigate } from '../../router'
import {
  actionDisabled,
  chainStatusTone,
  deadlineLabel,
  expiryTone,
  fire,
  formatElapsed,
  formatPercent,
  getMermaid,
  historySummary,
  incrementMermaidRenderCount,
  relativeTime,
  surfaceRouteParams,
  toneClass,
} from './helpers'



function MermaidGraph({ source }: { source: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.textContent = ''
    setError(null)

    const render = async () => {
      try {
        const mermaid = await getMermaid()
        const { svg } = await mermaid.render(`command-chain-${incrementMermaidRenderCount()}`, source)
        if (cancelled || !hostRef.current) return
        const parser = new DOMParser()
        const doc = parser.parseFromString(svg, 'image/svg+xml')
        const svgEl = doc.documentElement
        if (svgEl instanceof SVGElement) {
          hostRef.current.textContent = ''
          hostRef.current.appendChild(svgEl)
        }
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Mermaid 렌더링에 실패했습니다')
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.textContent = ''
    }
  }, [source])

  return html`
    <div class="mt-3 min-h-[160px]">
      ${error ? html`<${EmptyState} message=${error} compact />` : null}
      <div class="overflow-auto rounded-[10px] p-3 bg-[rgba(9,12,20,0.7)] cmd-chain-graph" ref=${hostRef}></div>
    </div>
  `
}

function ChainOperationListItem(
  { overlay, selected, onSelect }: { overlay: CommandPlaneChainOverlay; selected: boolean; onSelect: () => void },
) {
  const chain = overlay.operation.chain
  const runtime = overlay.runtime
  return html`
    <button type="button" class="w-full text-left text-inherit font-[inherit] cursor-pointer bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-chain-item ${selected ? 'selected' : ''}" onClick=${onSelect}>
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${overlay.operation.objective}</strong>
          <div class="cmd-card rounded-xl-sub">${overlay.operation.operation_id}</div>
        </div>
        <${StatusChip} label=${chain?.status ?? overlay.operation.status} tone=${chainStatusTone(chain?.status)} />
      </div>
      <div class="cmd-tag rounded-full-row">
        <span class="cmd-tag rounded-full">${chain?.kind ?? 'chain_dsl'}</span>
        ${chain?.chain_id ? html`<span class="cmd-tag rounded-full">${chain.chain_id}</span>` : null}
        ${runtime ? html`<span class="cmd-tag rounded-full ${chainStatusTone(chain?.status)}">${formatPercent(runtime.progress)} progress</span>` : null}
      </div>
      <div class="cmd-card rounded-xl-sub">${historySummary(overlay.history)}</div>
    </button>
  `
}

function ChainHistoryRow({ item }: { item: ChainHistoryEventSummary }) {
  return html`
    <article class="cmd-chain-history-row text-red-300">
      <div class="flex justify-between gap-3 items-start">
        <strong>${item.chain_id ?? '알 수 없는 체인'}</strong>
        <${StatusChip} label=${item.event} tone=${chainStatusTone(item.event)} />
      </div>
      <div class="cmd-card rounded-xl-sub">${relativeTime(item.timestamp)}</div>
      <div class="cmd-card rounded-xl-sub">${historySummary(item)}</div>
    </article>
  `
}

function ChainRunNodeRow({ node }: { node: CommandPlaneChainRunNode }) {
  return html`
    <article class="p-3 rounded-[10px] bg-[rgba(9,12,20,0.5)] border border-solid border-[var(--white-6)]">
      <div class="flex justify-between gap-3 items-start">
        <strong>${node.id}</strong>
        <${StatusChip} label=${node.status ?? '확인 필요'} tone=${chainStatusTone(node.status)} />
      </div>
      <div class="cmd-card rounded-xl-sub">
        ${node.type ?? '노드'}
        ${typeof node.duration_ms === 'number' ? ` · ${node.duration_ms}ms` : ''}
      </div>
      ${node.error ? html`<div class="cmd-card rounded-xl-sub text-red-300">${node.error}</div>` : null}
    </article>
  `
}

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
  const chain = op.chain
  const runId = chain?.run_id ?? null
  return html`
    <article class="cmd-card rounded-xl">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="cmd-card rounded-xl-sub">${op.operation_id}</div>
        </div>
        <${StatusChip} label=${operationStatusLabel(op.status)} tone=${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>유닛</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>트레이스</span><span class="font-mono">${op.trace_id}</span>
        <span>예산 등급</span><span>${op.budget_class ?? 'standard'}</span>
        <span>출처</span><span>${op.source ?? 'managed'}</span>
        <span>최근 갱신</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${chain
        ? html`
            <div class="cmd-tag rounded-full-row">
              <span class="cmd-tag rounded-full">${chain.kind}</span>
              <span class="cmd-tag rounded-full ${chainStatusTone(chain.status)}">${operationStatusLabel(chain.status)}</span>
              ${chain.chain_id ? html`<span class="cmd-tag rounded-full">${chain.chain_id}</span>` : null}
              ${chain.run_id ? html`<span class="cmd-tag rounded-full">실행 ${chain.run_id}</span>` : null}
            </div>
          `
        : null}
      ${op.checkpoint_ref
        ? html`<div class="cmd-card rounded-xl-foot">체크포인트 ${op.checkpoint_ref}</div>`
        : null}
      <div class="flex gap-3 flex-wrap mt-3">
        <${ActionButton}
          variant="ghost"
          onClick=${() => {
            setCommandPlaneSurface('swarm')
            navigate('command', {
              ...surfaceRouteParams('swarm'),
              operation_id: op.operation_id,
              ...(runId ? { run_id: runId } : {}),
            })
          }}
        >
          스웜 실시간 보기
        <//>
        ${chain
          ? html`
              <${ActionButton}
                variant="ghost"
                onClick=${() => {
                  focusCommandPlaneChainOperation(op.operation_id)
                  setCommandPlaneSurface('chains')
                  navigate('command', { ...surfaceRouteParams('chains'), operation: op.operation_id })
                }}
              >
                체인 열기
              <//>
            `
          : null}
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <${ActionButton} variant="ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? '일시정지 중…' : '일시정지'}
              <//>
              <${ActionButton} variant="ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? '회수 중…' : '회수'}
              <//>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <${ActionButton} variant="ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? '재개 중…' : '재개'}
              <//>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="cmd-card rounded-xl p-3">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="cmd-card rounded-xl-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <${StatusChip} label=${detachment.status ?? 'active'} tone=${toneClass(detachment.status)} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>유닛</span><span>${card.assigned_unit_label ?? detachment.assigned_unit_id}</span>
        <span>리더</span><span>${detachment.leader_id ?? '미지정'}</span>
        <span>편성</span><span>${detachment.roster.length}</span>
        <span>세션</span><span>${detachment.session_id ?? '연결 없음'}</span>
        <span>런타임</span><span>${detachment.runtime_kind ?? 'managed'}</span>
        <span>런타임 참조</span><span>${detachment.runtime_ref ?? '정보 없음'}</span>
        <span>진행 흔적</span><span>${relativeTime(detachment.last_progress_at)}</span>
        <span>하트비트</span><span>${deadlineLabel(detachment.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${relativeTime(detachment.updated_at)}</span>
      </div>
      <div class="cmd-tag rounded-full-row">
        ${detachment.heartbeat_deadline
          ? html`<span class="cmd-tag rounded-full ${expiryTone(detachment.heartbeat_deadline)}">
              기한 ${detachment.heartbeat_deadline}
            </span>`
          : null}
      </div>
    </article>
  `
}

export function OperationsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${CARD_STANDARD} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">작전</h3>
        </div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="cmd-card rounded-xl-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<${EmptyState} message="관리형 또는 투영된 작전이 없습니다." compact />`}
      </section>
      <section class="${CARD_STANDARD} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">분견대</h3>
        </div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="cmd-card rounded-xl-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<${EmptyState} message="투영된 분견대가 없습니다." compact />`}
      </section>
    </div>
  `
}

export function ChainsSurface() {
  const summary = commandPlaneChainSummary.value
  const overlays = summary?.operations ?? []
  const focusedOperationId = commandPlaneChainFocusOperationId.value
  const selectedOverlay =
    overlays.find(item => item.operation.operation_id === focusedOperationId)
    ?? overlays[0]
    ?? null
  const selectedRunId = selectedOverlay?.operation.chain?.run_id ?? null
  const run = commandPlaneChainRun.value?.run ?? selectedOverlay?.preview_run ?? null
  const isPreviewRun = !commandPlaneChainRun.value?.run && !!selectedOverlay?.preview_run

  useEffect(() => {
    if (selectedRunId) {
      void loadCommandPlaneChainRun(selectedRunId)
    } else {
      clearCommandPlaneChainRun()
    }
  }, [selectedRunId])

  return html`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${CARD_STANDARD} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">체인</h3>
        </div>
        <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${chainStatusTone(summary?.connection.status)}">
          <div class="flex justify-between gap-3 items-start">
            <strong>native chain 연결</strong>
            <${StatusChip} label=${summary?.connection.status ?? 'disconnected'} tone=${chainStatusTone(summary?.connection.status)} />
          </div>
          <p>${summary?.connection.message ?? '체인 요약은 MASC 프록시를 통해 집계됩니다.'}</p>
          <div class="cmd-card rounded-xl-grid">
            <span>기준 URL</span><span>${summary?.connection.base_url ?? '정보 없음'}</span>
            <span>연결된 작전</span><span>${summary?.summary?.linked_operations ?? 0}</span>
            <span>활성 체인</span><span>${summary?.summary?.active_chains ?? 0}</span>
            <span>최근 실패</span><span>${summary?.summary?.recent_failures ?? 0}</span>
            <span>마지막 이벤트</span><span>${relativeTime(summary?.summary?.last_history_event_at)}</span>
          </div>
        </article>

        ${commandPlaneChainError.value
          ? html`<${EmptyState} message=${commandPlaneChainError.value} compact />`
          : null}

        ${commandPlaneChainLoading.value && !summary
          ? html`<${EmptyState} message="체인 오버레이 불러오는 중…" compact />`
          : overlays.length > 0
            ? html`
                <div class="flex flex-col gap-3 mt-3.5">
                  ${overlays.map(overlay => html`
                    <${ChainOperationListItem}
                      overlay=${overlay}
                      selected=${selectedOverlay?.operation.operation_id === overlay.operation.operation_id}
                      onSelect=${() => focusCommandPlaneChainOperation(overlay.operation.operation_id)}
                    />
                  `)}
                </div>
              `
            : html`<${EmptyState} message="체인 기반 작전이 아직 없습니다." compact />`}

        <div class="flex flex-col gap-3 mt-3.5">
          <div class="flex justify-between gap-3 items-start">
            <strong>최근 이력</strong>
            <${StatusChip} label=${String(summary?.recent_history.length ?? 0)} />
          </div>
          ${summary && summary.recent_history.length > 0
            ? html`
                <div class="cmd-card rounded-xl-stack">
                  ${summary.recent_history.slice(0, 6).map(item => html`<${ChainHistoryRow} item=${item} />`)}
                </div>
              `
            : html`<${EmptyState} message="최근 체인 이력이 없습니다." compact />`}
        </div>
      </section>

      <section class="${CARD_STANDARD} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">체인 상세</h3>
        </div>
        ${selectedOverlay
          ? html`
              <article class="cmd-card rounded-xl">
                <div class="cmd-card rounded-xl-head">
                  <div>
                    <strong>${selectedOverlay.operation.objective}</strong>
                    <div class="cmd-card rounded-xl-sub">${selectedOverlay.operation.operation_id}</div>
                  </div>
                  <${StatusChip} label=${selectedOverlay.operation.chain?.status ?? selectedOverlay.operation.status} tone=${chainStatusTone(selectedOverlay.operation.chain?.status)} />
                </div>
                <div class="cmd-card rounded-xl-grid">
                  <span>종류</span><span>${selectedOverlay.operation.chain?.kind ?? 'chain_dsl'}</span>
                  <span>체인 ID</span><span>${selectedOverlay.operation.chain?.chain_id ?? 'goal-driven'}</span>
                  <span>실행 ID</span><span>${selectedRunId ?? '아직 구체화되지 않음'}</span>
                  <span>진행률</span><span>${formatPercent(selectedOverlay.runtime?.progress)}</span>
                  <span>경과</span><span>${formatElapsed(selectedOverlay.runtime?.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${relativeTime(selectedOverlay.operation.chain?.last_sync_at ?? selectedOverlay.operation.updated_at)}</span>
                </div>
                ${selectedOverlay.operation.chain?.goal
                  ? html`<div class="cmd-card rounded-xl-foot">${selectedOverlay.operation.chain.goal}</div>`
                  : null}
              </article>

              ${selectedOverlay.mermaid
                ? html`
                    <div class="mt-3.5 p-4 bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl">
                      <div class="flex justify-between gap-3 items-start">
                        <strong>Mermaid 그래프</strong>
                        <${StatusChip} label=${selectedOverlay.operation.chain?.chain_id ?? 'graph'} />
                      </div>
                      <${MermaidGraph} source=${selectedOverlay.mermaid} />
                    </div>
                  `
                : html`<${EmptyState} message="기록된 Mermaid 그래프가 아직 없습니다." compact />`}

              <div class="mt-3.5 p-4 bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl">
                <div class="flex justify-between gap-3 items-start">
                  <strong>실행 상세</strong>
                  <${StatusChip} label=${run
                      ? (run.success === false ? '실패' : isPreviewRun ? '미리보기' : '기록됨')
                      : '대기 중'} tone=${run?.success === false ? 'bad' : 'ok'} />
                </div>
                ${commandPlaneChainRunLoading.value
                  ? html`<${EmptyState} message="실행 상세 불러오는 중…" compact />`
                  : commandPlaneChainRunError.value
                    ? html`<${EmptyState} message=${commandPlaneChainRunError.value} compact />`
                    : run && run.nodes.length > 0
                      ? html`
                          <div class="cmd-card rounded-xl-grid">
                            <span>체인</span><span>${run.chain_id}</span>
                            <span>실행</span><span>${run.run_id ?? '미리보기만 있음'}</span>
                            <span>지속시간</span><span>${run.duration_ms != null ? `${run.duration_ms}ms` : '정보 없음'}</span>
                            <span>노드</span><span>${run.nodes.length}</span>
                          </div>
                          ${isPreviewRun
                            ? html`<div class="cmd-card rounded-xl-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`
                            : null}
                          <div class="cmd-card rounded-xl-stack">
                            ${run.nodes.map(node => html`<${ChainRunNodeRow} node=${node} />`)}
                          </div>
                        `
                      : html`<${EmptyState} message="이 작전의 run-store 상세는 아직 없습니다." compact />`}
              </div>
            `
          : html`<${EmptyState} message="그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요." compact />`}
      </section>
    </div>
  `
}
