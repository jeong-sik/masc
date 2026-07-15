// MASC Dashboard — Gate / HITL Surface
// Pending external effects wait here for Human judgment without blocking the
// Keeper lane. Configured allow and Auto Judge share this same Gate contract.
//
// Data source: gateData.value?.approval_queue (KeeperApprovalQueueItem[]).
// Actions: respondToKeeperApproval(id, 'approve' | 'reject').
// The live decision model is the closed set {approve, reject};
// there is no defer/undo endpoint, so the prototype's 보류/되돌리기 controls are
// intentionally not rendered. History is read-only from recent_resolved.
// Visual layout ports the keeper-v2 .ap-* design.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type {
  KeeperApprovalQueueItem,
  KeeperResolvedApprovalItem,
  GateDecisionSource,
  GateMode,
  HitlContextSummary,
  HitlSummaryStatus,
} from '../../types'
import { TELEMETRY_AUTO_REFRESH_MS } from '../../config/constants'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { formatDateTimeKo, formatDurationCompound } from '../../lib/format-time'
import {
  keeperResolvedApprovalDecisionClass,
  keeperResolvedApprovalDecisionLabel,
  type KeeperResolvedApprovalDecision,
} from '../../lib/keeper-approval-decision'
import { navigate } from '../../router'
import { AgentAvatar } from '../overview/agent-avatar'
import { LoadingState } from '../common/feedback-state'
import {
  gateData,
  gateError,
  gateLoading,
  gateApprovalActing,
  refreshGate,
  respondToKeeperApproval,
  setKeeperGateMode,
} from '../gate-store'

type ApprovalsView = 'queue' | 'history'
type ApprovalHistoryFilter = 'all' | KeeperResolvedApprovalDecision

const APPROVAL_HISTORY_FILTERS: ReadonlyArray<{
  id: ApprovalHistoryFilter
  label: string
  predicate: (item: KeeperResolvedApprovalItem) => boolean
}> = [
  { id: 'all', label: '전체', predicate: () => true },
  { id: 'approve', label: '승인', predicate: item => item.decision === 'approve' },
  { id: 'reject', label: '거부', predicate: item => item.decision === 'reject' },
  { id: 'edit', label: '수정됨', predicate: item => item.decision === 'edit' },
  { id: 'unknown', label: '처리됨', predicate: item => item.decision === 'unknown' },
]
const DEFAULT_APPROVAL_HISTORY_FILTER = APPROVAL_HISTORY_FILTERS[0]!

// Aside preview caps. The recent list is a preview of recent_resolved — the full
// set lives in the 이력 (history) tab, so its overflow is expected.
const ASIDE_RECENT_LIMIT = 5

// seconds-waited → compound elapsed + "대기" suffix ("2시간 5분 대기").
// Delegates to the shared formatDurationCompound so long HITL waits render with
// an hour tier; the prior bespoke minute-only formatter broke down at scale
// ("150분 0초 대기" for 2.5h). Non-finite / negative input clamps to 0 so the
// queue never surfaces an "확인 필요" label in the age slot.
function apAge(sec: number | null | undefined): string {
  const s = typeof sec === 'number' && Number.isFinite(sec) ? Math.max(0, Math.round(sec)) : 0
  return `${formatDurationCompound(s)} 대기`
}

function compactText(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function approvalTitle(item: KeeperApprovalQueueItem): string {
  return `${item.tool_name} Gate 요청`
}

function approvalWorkSummary(item: KeeperApprovalQueueItem): string | null {
  return item.task_id ? `task ${item.task_id}` : null
}

function decisionSourceLabel(source: GateDecisionSource | null | undefined): string {
  switch (source) {
    case 'always_allowed': return 'Always Allowed'
    case 'auto_judge': return 'Auto Judge'
    case 'human_operator': return 'Human'
    default: return '판단 주체 미확인'
  }
}

function ResolvedApprovalItem({ item }: { item: KeeperResolvedApprovalItem }) {
  const decision = keeperResolvedApprovalDecisionLabel(item.decision)
  return html`
    <li
      class="ap-history-item"
      data-testid="approval-history-item"
      data-approval-id=${item.id}
    >
      <span class=${`ap-history-decision ${keeperResolvedApprovalDecisionClass(item.decision)}`}>${decision}</span>
      <span class="ap-history-tool mono">${item.tool_name}</span>
      <span class="ap-history-keeper">${item.keeper_name}</span>
      <span class="ap-history-source">${decisionSourceLabel(item.decision_source)}</span>
      <span class="ap-history-id mono">${item.id}</span>
      ${item.resolved_at
        ? html`<span class="ap-history-at">${formatDateTimeKo(item.resolved_at)}</span>`
        : null}
    </li>
  `
}

function resolvedAtMs(item: KeeperResolvedApprovalItem): number {
  const parsed = item.resolved_at ? Date.parse(item.resolved_at) : Number.NaN
  return Number.isFinite(parsed) ? parsed : 0
}

function ApHistory({ items }: { items: KeeperResolvedApprovalItem[] }) {
  const [filter, setFilter] = useState<ApprovalHistoryFilter>('all')
  const sorted = useMemo(
    () => [...items].sort((a, b) => resolvedAtMs(b) - resolvedAtMs(a)),
    [items],
  )
  const activeFilter = APPROVAL_HISTORY_FILTERS.find(item => item.id === filter)
    ?? DEFAULT_APPROVAL_HISTORY_FILTER
  const shown = sorted.filter(activeFilter.predicate)
  const counts = useMemo(() => ({
    approve: sorted.filter(item => item.decision === 'approve').length,
    reject: sorted.filter(item => item.decision === 'reject').length,
    keepers: new Set(sorted.map(item => item.keeper_name)).size,
  }), [sorted])

  return html`
    <section class="ap-hist" data-testid="approvals-history-view">
      <div class="ap-hist-summary" aria-label="승인 이력 요약">
        <div class="ap-hist-stat"><b class="mono ok">${counts.approve}</b> 승인</div>
        <div class="ap-hist-stat"><b class="mono bad">${counts.reject}</b> 거부</div>
        <div class="ap-hist-stat"><b class="mono">${counts.keepers}</b> 관련 키퍼</div>
      </div>
      <div class="ap-hist-filters" role="tablist" aria-label="승인 이력 필터">
        ${APPROVAL_HISTORY_FILTERS.map(option => html`
          <button
            key=${option.id}
            type="button"
            class=${`ap-hist-f ${filter === option.id ? 'on' : ''}`}
            aria-pressed=${filter === option.id}
            onClick=${() => setFilter(option.id)}
          >${option.label}</button>
        `)}
      </div>
      ${shown.length > 0
        ? html`
            <ul class="ap-history-list ap-hist-list">
              ${shown.map(item => html`<${ResolvedApprovalItem} key=${item.id} item=${item} />`)}
            </ul>
          `
        : html`
            <div class="ap-clear compact" data-testid="approvals-history-empty">
              <div class="ico">${'✓'}</div>
              <h3>해당 필터의 처리 이력이 없습니다</h3>
              <div class="ap-clear-sub">최근 처리 projection에 일치하는 항목이 없습니다.</div>
            </div>
          `}
    </section>
  `
}

function approvalDetailRows(item: KeeperApprovalQueueItem): Array<{ label: string; value: string }> {
  return [
    { label: '키퍼', value: item.keeper_name },
    { label: '작업', value: item.tool_name },
    { label: '상태', value: 'Human 판단 대기 · Keeper lane nonblocking' },
    { label: '대기', value: apAge(item.waiting_s) },
    { label: '작업', value: approvalWorkSummary(item) },
    { label: '턴', value: typeof item.turn_id === 'number' ? `turn ${item.turn_id}` : null },
    { label: '요청시각', value: compactText(item.requested_at) },
    { label: '입력', value: compactText(item.input_preview) || '입력 미리보기 없음' },
  ].filter((row): row is { label: string; value: string } => Boolean(row.value))
}

// Open this keeper's workspace conversation (work.ts idiom).
function openKeeperWorkspace(name: string): void {
  navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

// Render the HITL context-summary worker's Human briefing. `available`
// carries the LLM-generated summary a Human reads before deciding;
// `pending`/`failed` are surfaced (not hidden) so a stuck or errored summary is
// visible rather than silently absent. `not_requested`/`null` render nothing.
function renderAvailableSummary(summary: HitlContextSummary) {
  return html`
    <div class="ap-summary sev-summary" data-testid="approval-summary" data-summary-state="available">
      <div class="ap-summary-head">
        <span class="ap-summary-label">🧭 컨텍스트 요약</span>
        <span class="ap-summary-uncertainty">${summary.judgment === 'require_human' ? 'Human 판단 필요' : summary.judgment === 'approve' ? '승인 제안' : '거부 제안'}</span>
      </div>
      <p class="ap-summary-text">${summary.context_summary}</p>
      ${summary.key_questions.length
        ? html`<ul class="ap-summary-questions">
            ${summary.key_questions.map(q => html`<li>${q}</li>`)}
          </ul>`
        : null}
      ${summary.rationale.trim()
        ? html`<p class="ap-summary-rationale">${summary.rationale.trim()}</p>`
        : null}
    </div>
  `
}

function approvalSummaryBlock(status: HitlSummaryStatus | null | undefined) {
  if (!status) return null
  switch (status.status) {
    case 'not_requested':
      return null
    case 'pending':
      return html`<div class="ap-summary ap-summary-pending" data-testid="approval-summary" data-summary-state="pending">
        <span class="ap-summary-label">🧭 컨텍스트 요약 생성 중…</span>
      </div>`
    case 'failed':
      return html`<div class="ap-summary ap-summary-failed" data-testid="approval-summary" data-summary-state="failed">
        <span class="ap-summary-label">컨텍스트 요약 실패${status.retryable ? ' · 재시도 예정' : ''}</span>
        ${status.reason ? html`<span class="ap-summary-reason">${status.reason}</span>` : null}
      </div>`
    case 'available':
      return renderAvailableSummary(status.summary)
    default: {
      // Exhaustive over HitlSummaryStatus — a new backend variant fails typecheck here.
      const _never: never = status
      return _never
    }
  }
}

function ApprovalCard({
  item,
  selected,
  onSelect,
}: {
  item: KeeperApprovalQueueItem
  selected: boolean
  onSelect: (id: string) => void
}) {
  const actingId = gateApprovalActing.value
  const busy = actingId === item.id
  const anyBusy = Boolean(actingId)
  const title = approvalTitle(item)

  return html`
    <article
      class="ap-card sev-info"
      data-testid="approval-card"
      data-approval-id=${item.id}
      data-selected=${selected ? 'true' : 'false'}
    >
      <div class="ap-rail"></div>
      <div class="ap-main">
        <div class="ap-h">
          <span class="ap-kind sev-info">● Human HITL</span>
          <span class="ap-tool mono">${item.tool_name}</span>
          <span class="ap-id mono">${item.id}</span>
          <span class="ap-age sev-info">${apAge(item.waiting_s)}</span>
          <button
            type="button"
            class="ap-detail-toggle"
            aria-pressed=${selected}
            onClick=${() => onSelect(item.id)}
            title="요청 상세 보기"
          >상세</button>
        </div>
        <h3 class="ap-title">${title}</h3>
        <p class="ap-detail">Keeper lane은 계속 진행하며 이 요청만 판단을 기다립니다.</p>
        ${approvalSummaryBlock(item.summary_status)}
        <div class="ap-req">
          <${AgentAvatar} name=${item.keeper_name} size="sm" />
          <div class="ap-req-body">
            <div class="ap-req-who">
              <button
                type="button"
                class="ap-klink"
                onClick=${() => openKeeperWorkspace(item.keeper_name)}
                title=${`${item.keeper_name} 대화 열기`}
              >${item.keeper_name}</button>
              ${item.task_id
                ? html`<button
                    type="button"
                    class="ap-req-task mono"
                    onClick=${() => navigate('workspace', { section: 'work' })}
                    title="작업 보기"
                  >task ${item.task_id}</button>`
                : null}
              <span class="ap-req-meta mono">nonblocking</span>
            </div>
            <div class="ap-req-quote">
              ${item.input_preview?.trim() ? `“${item.input_preview.trim()}”` : '입력 미리보기 없음'}
            </div>
          </div>
        </div>
        <div class="ap-actions">
          <button
            type="button"
            class="ap-act approve"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '승인'}</button>
          <button
            type="button"
            class="ap-act deny"
            onClick=${() => void respondToKeeperApproval(item.id, 'reject')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '거부'}</button>
          <button
            type="button"
            class="ap-act ghost"
            onClick=${() => openKeeperWorkspace(item.keeper_name)}
            title="맥락 보기"
            disabled=${anyBusy}
          >대화에서 검토 →</button>
        </div>
      </div>
    </article>
  `
}

function ApprovalDetailPanel({
  item,
  variant = 'rail',
}: {
  item: KeeperApprovalQueueItem | null
  variant?: 'rail' | 'inline'
}) {
  if (!item) return null
  const rows = approvalDetailRows(item)

  return html`
    <aside
      class=${`ap-detail-panel ap-detail-panel-${variant}`}
      data-testid=${variant === 'inline' ? 'approval-detail-panel-inline' : 'approval-detail-panel'}
      data-approval-id=${item.id}
    >
      <div class="ap-detail-panel-head">
        <span class="ap-kind sev-info">● Gate request</span>
        <div class="ap-detail-panel-title">
          <strong>${approvalTitle(item)}</strong>
          <span class="mono">${item.id}</span>
        </div>
      </div>
      <dl class="ap-dossier">
        ${rows.map(row => html`
          <div class="ap-dossier-row" key=${row.label}>
            <dt>${row.label}</dt>
            <dd>${row.value}</dd>
          </div>
        `)}
      </dl>
    </aside>
  `
}

const GATE_MODES: ReadonlyArray<{ mode: GateMode; label: string }> = [
  { mode: 'manual', label: 'Human' },
  { mode: 'auto_judge', label: 'Auto Judge' },
  { mode: 'always_allow', label: 'Always Allow' },
]

function ApAside({
  openCount,
  resolvedItems,
}: {
  openCount: number
  resolvedItems: KeeperResolvedApprovalItem[]
}) {
  const hitl = gateData.value?.hitl
  const recent = [...resolvedItems]
    .sort((a, b) => resolvedAtMs(b) - resolvedAtMs(a))
    .slice(0, ASIDE_RECENT_LIMIT)
  const gateMode = hitl?.gate_mode
  const acting = gateApprovalActing.value
  const modeDisabled = acting !== null
  return html`
    <aside class="ap-aside" data-testid="approvals-aside">
      <section class="wka-card ap-auto-card">
        <div class="wka-h">
          <h3>Gate 모드</h3>
        </div>
        <div class="wka-auto">
          <div class="wka-auto-top">
            <span class="wka-auto-lbl">
              Gate 모드
              <b>${GATE_MODES.find(option => option.mode === gateMode?.mode)?.label ?? '확인 필요'}</b>
            </span>
            <div class="ap-viewseg" role="radiogroup" aria-label="Gate 모드" data-testid="gate-mode-selector">
              ${GATE_MODES.map(option => html`
                <button
                  key=${option.mode}
                  type="button"
                  class=${`ap-viewbtn ${gateMode?.mode === option.mode ? 'on' : ''}`}
                  role="radio"
                  aria-checked=${gateMode?.mode === option.mode}
                  onClick=${() => void setKeeperGateMode(option.mode)}
                  disabled=${modeDisabled}
                >${option.label}</button>
              `)}
            </div>
          </div>
          <div class="wka-auto-stat">열린 승인 ${openCount.toLocaleString()}건</div>
          <div class="wka-auto-note">
            Human은 사람이 판단하고, Auto Judge는 LLM이 판단하며, Always Allow는 workspace의 명시적 선택입니다.
          </div>
          ${gateMode?.state === 'invalid' || gateMode?.read_error
            ? html`<div class="ap-env-warn mono">Gate mode invalid: ${gateMode.read_error ?? '상태 파싱 실패'}</div>`
            : null}
        </div>
      </section>

      <section class="wka-card">
        <div class="wka-h">
          <h3>최근 처리</h3>
          <span class="mono">${resolvedItems.length}</span>
        </div>
        ${recent.length > 0
          ? html`
              <ul class="ap-recent-list">
                ${recent.map(item => html`
                  <li class="ap-recent-row" key=${item.id}>
                    <span class=${`ap-history-decision ${keeperResolvedApprovalDecisionClass(item.decision)}`}>
                      ${keeperResolvedApprovalDecisionLabel(item.decision)}
                    </span>
                    <span class="ap-recent-body">
                      <span class="ap-recent-top">
                        <span class="mono">${item.tool_name}</span>
                        <span>${item.keeper_name}</span>
                      </span>
                      <span class="ap-recent-sub mono">${item.id}</span>
                    </span>
                  </li>
                `)}
              </ul>
            `
          : html`<div class="ap-side-empty">최근 처리 projection 없음</div>`}
      </section>
    </aside>
  `
}

export function ApprovalsSurface() {
  useEffect(() => {
    void refreshGate()
    const disposeAutoRefresh = setupVisibleAutoRefresh(refreshGate, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
    }
  }, [])

  const items = gateData.value?.approval_queue ?? []
  const resolvedItems = gateData.value?.recent_resolved ?? []
  const error = gateError.value
  // First load only: gateResource is stale-while-revalidate, so a refetch
  // keeps the previous data — gateData is null ONLY before the first load
  // resolves. Show a loading state then, instead of asserting the empty queue.
  const firstLoad = gateLoading.value && gateData.value === null
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [view, setView] = useState<ApprovalsView>('queue')
  const selectedItem = items.find(item => item.id === selectedId) ?? items[0] ?? null

  const stats = useMemo(() => {
    const longest = items.reduce((max, i) => Math.max(max, i.waiting_s ?? 0), 0)
    const keepers = new Set(items.map(i => i.keeper_name)).size
    return { longest, keepers }
  }, [items])

  return html`
    <main class="ov ov-2col ss-surface ap-surface bg-surface-page text-text-primary" data-screen-label="Gate HITL 큐" data-testid="approvals-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">HITL</span>
            <h1>Gate · HITL 큐</h1>
            <p class="ov-sub">
              외부 효과 요청의 정확한 입력을 Human이 판단하는 비동기 큐 ·
              <span>Keeper lane은 대기 중에도 다른 활동을 계속</span>
            </p>
          </div>
          <div class="ap-head-actions">
            <div class="ap-viewseg" role="tablist" aria-label="승인 큐 보기">
              <button
                type="button"
                class=${`ap-viewbtn ${view === 'queue' ? 'on' : ''}`}
                aria-selected=${view === 'queue'}
                onClick=${() => setView('queue')}
              >
                큐${items.length > 0 ? html`<span class="ap-viewbtn-n mono">${items.length}</span>` : null}
              </button>
              <button
                type="button"
                class=${`ap-viewbtn ${view === 'history' ? 'on' : ''}`}
                aria-selected=${view === 'history'}
                onClick=${() => setView('history')}
              >이력</button>
            </div>
            ${view === 'queue' && items.length > 0
              ? html`<span class="ap-sla mono" title="가장 오래 대기 중인 건">최장 대기 ${apAge(stats.longest)}</span>`
              : null}
          </div>
        </header>

        ${error ? html`<div class="ap-error" role="alert" data-testid="approvals-error">${error}</div>` : null}

        ${firstLoad
          ? html`<${LoadingState}>Gate 큐 불러오는 중...<//>`
          : view === 'history'
            ? html`<${ApHistory} items=${resolvedItems} />`
          : html`
        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(3, 1fr)' }}>
          <div class="ov-kpi">
            <div class="ov-kpi-k">열린 승인</div>
            <div class=${`ov-kpi-v ${items.length ? 'warn' : 'ok'}`}>${items.length}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">관련 Keeper</div>
            <div class="ov-kpi-v" data-testid="gate-kpi-keepers">${stats.keepers}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">처리 완료</div>
            <div class="ov-kpi-v volt">${resolvedItems.length}</div>
          </div>
        </section>

        ${items.length > 0
          ? html`
              <div class="ap-workspace" data-testid="approvals-workspace">
                <div class="ap-queue" data-testid="approvals-queue">
                  ${items.map(item => html`
                    <${Fragment} key=${item.id}>
                      <${ApprovalCard}
                        item=${item}
                        selected=${selectedItem?.id === item.id}
                        onSelect=${setSelectedId}
                      />
                      ${selectedItem?.id === item.id
                        ? html`<${ApprovalDetailPanel} item=${item} variant="inline" />`
                        : null}
                    <//>
                  `)}
                </div>
                <${ApprovalDetailPanel} item=${selectedItem} variant="rail" />
              </div>
            `
          : null}
        ${items.length === 0 && !error
          ? html`
              <div class="ap-clear" data-testid="approvals-empty">
                <div class="ico">${'✓'}</div>
                <h3>열린 Human 판단이 없습니다</h3>
                <div class="ap-clear-sub">HITL 큐가 비어 있습니다 — keeper들은 계속 진행 중입니다.</div>
              </div>
            `
          : null}
      `}
      </div>
      ${!firstLoad ? html`
        <${ApAside}
          openCount=${items.length}
          resolvedItems=${resolvedItems}
        />
      ` : null}
    </main>
  `
}
