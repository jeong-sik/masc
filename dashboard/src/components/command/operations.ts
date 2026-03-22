import { html } from 'htm/preact'
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

function operationStatusLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'active':
      return '가동 중'
    case 'paused':
      return '일시정지'
    case 'failed':
      return '실패'
    case 'completed':
    case 'done':
      return '완료'
    case 'disconnected':
      return '끊김'
    case 'preview':
      return '미리보기'
    case 'captured':
      return '기록됨'
    default:
      return value?.trim() || '확인 필요'
  }
}

function MermaidGraph({ source }: { source: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.innerHTML = ''
    setError(null)

    const render = async () => {
      try {
        const mermaid = await getMermaid()
        const { svg } = await mermaid.render(`command-chain-${incrementMermaidRenderCount()}`, source)
        if (cancelled || !hostRef.current) return
        hostRef.current.innerHTML = svg
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Mermaid 렌더링에 실패했습니다')
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.innerHTML = ''
    }
  }, [source])

  return html`
    <div class="mt-3 min-h-[160px]">
      ${error ? html`<div class="empty-state error">${error}</div>` : null}
      <div class="command-chain-graph" ref=${hostRef}></div>
    </div>
  `
}

function ChainOperationListItem(
  { overlay, selected, onSelect }: { overlay: CommandPlaneChainOverlay; selected: boolean; onSelect: () => void },
) {
  const chain = overlay.operation.chain
  const runtime = overlay.runtime
  return html`
    <button class="command-chain-item ${selected ? 'selected' : ''}" onClick=${onSelect}>
      <div class="command-card-head">
        <div>
          <strong>${overlay.operation.objective}</strong>
          <div class="command-card-sub">${overlay.operation.operation_id}</div>
        </div>
        <span class="command-chip ${chainStatusTone(chain?.status)}">${chain?.status ?? overlay.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${chain?.kind ?? 'chain_dsl'}</span>
        ${chain?.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
        ${runtime ? html`<span class="command-tag ${chainStatusTone(chain?.status)}">${formatPercent(runtime.progress)} progress</span>` : null}
      </div>
      <div class="command-card-sub">${historySummary(overlay.history)}</div>
    </button>
  `
}

function ChainHistoryRow({ item }: { item: ChainHistoryEventSummary }) {
  return html`
    <article class="command-chain-history-row text-red-300">
      <div class="command-guide-head">
        <strong>${item.chain_id ?? '알 수 없는 체인'}</strong>
        <span class="command-chip ${chainStatusTone(item.event)}">${item.event}</span>
      </div>
      <div class="command-card-sub">${relativeTime(item.timestamp)}</div>
      <div class="command-card-sub">${historySummary(item)}</div>
    </article>
  `
}

function ChainRunNodeRow({ node }: { node: CommandPlaneChainRunNode }) {
  return html`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${node.id}</strong>
        <span class="command-chip ${chainStatusTone(node.status)}">${node.status ?? '확인 필요'}</span>
      </div>
      <div class="command-card-sub">
        ${node.type ?? '노드'}
        ${typeof node.duration_ms === 'number' ? ` · ${node.duration_ms}ms` : ''}
      </div>
      ${node.error ? html`<div class="command-card-sub text-red-300">${node.error}</div>` : null}
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
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="command-card-sub">${op.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')}">${operationStatusLabel(op.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>트레이스</span><span class="font-mono">${op.trace_id}</span>
        <span>자율성</span><span>${op.autonomy_level ?? '정보 없음'}</span>
        <span>예산 등급</span><span>${op.budget_class ?? 'standard'}</span>
        <span>출처</span><span>${op.source ?? 'managed'}</span>
        <span>최근 갱신</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${chain
        ? html`
            <div class="command-tag-row">
              <span class="command-tag">${chain.kind}</span>
              <span class="command-tag ${chainStatusTone(chain.status)}">${operationStatusLabel(chain.status)}</span>
              ${chain.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
              ${chain.run_id ? html`<span class="command-tag">실행 ${chain.run_id}</span>` : null}
            </div>
          `
        : null}
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">체크포인트 ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${() => {
            setCommandPlaneSurface('swarm')
            navigate('operations', {
              ...surfaceRouteParams('swarm'),
              operation_id: op.operation_id,
              ...(runId ? { run_id: runId } : {}),
            })
          }}
        >
          스웜 실시간 보기
        </button>
        ${chain
          ? html`
              <button
                class="control-btn ghost"
                onClick=${() => {
                  focusCommandPlaneChainOperation(op.operation_id)
                  setCommandPlaneSurface('chains')
                  navigate('operations', { ...surfaceRouteParams('chains'), operation: op.operation_id })
                }}
              >
                체인 열기
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? '일시정지 중…' : '일시정지'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? '회수 중…' : '회수'}
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? '재개 중…' : '재개'}
              </button>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="command-card p-3">
      <div class="command-card-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="command-card-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(detachment.status)}">${detachment.status ?? 'active'}</span>
      </div>
      <div class="command-card-grid">
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
      <div class="command-tag-row">
        ${detachment.heartbeat_deadline
          ? html`<span class="command-tag ${expiryTone(detachment.heartbeat_deadline)}">
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
    <div class="command-surface-grid">
      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">작전</div>
        </div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
        </div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
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
    <div class="command-grid">
      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
        </div>
        <article class="command-guide-card ${chainStatusTone(summary?.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${chainStatusTone(summary?.connection.status)}">${summary?.connection.status ?? 'disconnected'}</span>
          </div>
          <p>${summary?.connection.message ?? '체인 요약은 MASC 프록시를 통해 집계됩니다.'}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${summary?.connection.base_url ?? '정보 없음'}</span>
            <span>연결된 작전</span><span>${summary?.summary?.linked_operations ?? 0}</span>
            <span>활성 체인</span><span>${summary?.summary?.active_chains ?? 0}</span>
            <span>최근 실패</span><span>${summary?.summary?.recent_failures ?? 0}</span>
            <span>마지막 이벤트</span><span>${relativeTime(summary?.summary?.last_history_event_at)}</span>
          </div>
        </article>

        ${commandPlaneChainError.value
          ? html`<div class="empty-state error">${commandPlaneChainError.value}</div>`
          : null}

        ${commandPlaneChainLoading.value && !summary
          ? html`<div class="empty-state">체인 오버레이 불러오는 중…</div>`
          : overlays.length > 0
            ? html`
                <div class="command-chain-list">
                  ${overlays.map(overlay => html`
                    <${ChainOperationListItem}
                      overlay=${overlay}
                      selected=${selectedOverlay?.operation.operation_id === overlay.operation.operation_id}
                      onSelect=${() => focusCommandPlaneChainOperation(overlay.operation.operation_id)}
                    />
                  `)}
                </div>
              `
            : html`<div class="empty-state">체인 기반 작전이 아직 없습니다.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>최근 이력</strong>
            <span class="command-chip">${summary?.recent_history.length ?? 0}</span>
          </div>
          ${summary && summary.recent_history.length > 0
            ? html`
                <div class="command-card-stack">
                  ${summary.recent_history.slice(0, 6).map(item => html`<${ChainHistoryRow} item=${item} />`)}
                </div>
              `
            : html`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
        </div>
        ${selectedOverlay
          ? html`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${selectedOverlay.operation.objective}</strong>
                    <div class="command-card-sub">${selectedOverlay.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${chainStatusTone(selectedOverlay.operation.chain?.status)}">
                    ${selectedOverlay.operation.chain?.status ?? selectedOverlay.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${selectedOverlay.operation.chain?.kind ?? 'chain_dsl'}</span>
                  <span>체인 ID</span><span>${selectedOverlay.operation.chain?.chain_id ?? 'goal-driven'}</span>
                  <span>실행 ID</span><span>${selectedRunId ?? '아직 구체화되지 않음'}</span>
                  <span>진행률</span><span>${formatPercent(selectedOverlay.runtime?.progress)}</span>
                  <span>경과</span><span>${formatElapsed(selectedOverlay.runtime?.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${relativeTime(selectedOverlay.operation.chain?.last_sync_at ?? selectedOverlay.operation.updated_at)}</span>
                </div>
                ${selectedOverlay.operation.chain?.goal
                  ? html`<div class="command-card-foot">${selectedOverlay.operation.chain.goal}</div>`
                  : null}
              </article>

              ${selectedOverlay.mermaid
                ? html`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${selectedOverlay.operation.chain?.chain_id ?? 'graph'}</span>
                      </div>
                      <${MermaidGraph} source=${selectedOverlay.mermaid} />
                    </div>
                  `
                : html`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${run?.success === false ? 'bad' : 'ok'}">
                    ${run
                      ? (run.success === false ? '실패' : isPreviewRun ? '미리보기' : '기록됨')
                      : '대기 중'}
                  </span>
                </div>
                ${commandPlaneChainRunLoading.value
                  ? html`<div class="empty-state">실행 상세 불러오는 중…</div>`
                  : commandPlaneChainRunError.value
                    ? html`<div class="empty-state error">${commandPlaneChainRunError.value}</div>`
                    : run && run.nodes.length > 0
                      ? html`
                          <div class="command-card-grid">
                            <span>체인</span><span>${run.chain_id}</span>
                            <span>실행</span><span>${run.run_id ?? '미리보기만 있음'}</span>
                            <span>지속시간</span><span>${run.duration_ms != null ? `${run.duration_ms}ms` : '정보 없음'}</span>
                            <span>노드</span><span>${run.nodes.length}</span>
                          </div>
                          ${isPreviewRun
                            ? html`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`
                            : null}
                          <div class="command-card-stack">
                            ${run.nodes.map(node => html`<${ChainRunNodeRow} node=${node} />`)}
                          </div>
                        `
                      : html`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `
          : html`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `
}
