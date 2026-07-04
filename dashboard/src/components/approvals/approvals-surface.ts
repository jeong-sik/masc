// MASC Dashboard — Approvals Surface
// Dedicated operator view of the Keeper HITL approval queue: keeper tool calls
// gated above the risk threshold wait here for an approve / approve+always / reject
// decision. This is a focused, standalone surface; the broader Governance panel
// (Command surface) keeps its rules/decisions/monitoring role and shares the SAME
// underlying signal + action, so resolving here updates both.
//
// Data source: governanceData.value?.approval_queue (KeeperApprovalQueueItem[]).
// Actions: respondToKeeperApproval(id, 'approve' | 'reject', rememberRule).
// The live decision model is the closed set {approve, reject} (+ rememberRule);
// there is no defer/undo endpoint, so the prototype's 보류/되돌리기/처리이력 are
// intentionally not rendered. Visual layout ports the keeper-v2 .ap-* design.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type {
  KeeperApprovalQueueItem,
  KeeperResolvedApprovalItem,
  HitlContextSummary,
  HitlSummaryStatus,
} from '../../types'
import { TELEMETRY_AUTO_REFRESH_MS } from '../../config/constants'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { formatDateTimeKo } from '../../lib/format-time'
import {
  keeperApprovalRiskLabel,
  keeperApprovalRiskVisualBand,
  type KeeperApprovalRiskVisualBand,
} from '../../lib/governance-risk-level'
import {
  keeperResolvedApprovalDecisionClass,
  keeperResolvedApprovalDecisionLabel,
} from '../../lib/keeper-approval-decision'
import { navigate } from '../../router'
import { AgentAvatar } from '../overview/agent-avatar'
import { LoadingState } from '../common/feedback-state'
import {
  governanceData,
  governanceError,
  governanceLoading,
  governanceApprovalActing,
  refreshGovernance,
  respondToKeeperApproval,
} from '../governance-store'

function apSev(riskLevel: string | null | undefined): KeeperApprovalRiskVisualBand {
  return keeperApprovalRiskVisualBand(riskLevel)
}

// Prototype's .ap-kind chip leads with a glyph (data.jsx APPROVAL_KIND). The live
// queue item has no `kind` taxonomy field, so we do NOT fabricate a kind glyph;
// instead the chip leads with a glyph derived from the real risk visual band —
// the icon affordance the prototype shows, keyed only off data we actually have.
// Exhaustive over KeeperApprovalRiskVisualBand so a new band is a compile error.
function apSevGlyph(band: KeeperApprovalRiskVisualBand): string {
  switch (band) {
    case 'bad':
      return '⚠' // ⚠ destructive / irreversible
    case 'warn':
      return '▲' // ▲ elevated
    case 'accent':
      return '◆' // ◆ moderate
    case 'info':
      return '●' // ● low
  }
}

// seconds-waited → "N분 N초 대기" (prototype apAge).
function apAge(sec: number | null | undefined): string {
  const s = Math.max(0, Math.round(sec ?? 0))
  const m = Math.floor(s / 60)
  const r = s % 60
  return m ? `${m}분 ${r}초 대기` : `${r}초 대기`
}

function compactText(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function joinUnique(values: Array<string | null | undefined>): string | null {
  const seen: string[] = []
  for (const value of values) {
    const compact = compactText(value)
    if (compact && !seen.includes(compact)) seen.push(compact)
  }
  return seen.length ? seen.join(' · ') : null
}

function approvalTitle(item: KeeperApprovalQueueItem): string {
  return compactText(item.action_key) || `${item.tool_name} 실행 승인 요청`
}

function approvalWorkSummary(item: KeeperApprovalQueueItem): string | null {
  return joinUnique([
    item.task_id ? `task ${item.task_id}` : null,
    item.runtime_contract?.task_id ? `runtime task ${item.runtime_contract.task_id}` : null,
    item.goal_id ? `goal ${item.goal_id}` : null,
    ...(item.goal_ids ?? []).map(id => `goal ${id}`),
    item.runtime_contract?.goal_id ? `runtime goal ${item.runtime_contract.goal_id}` : null,
    ...(item.runtime_contract?.goal_ids ?? []).map(id => `runtime goal ${id}`),
  ])
}

function approvalRuntimeSummary(item: KeeperApprovalQueueItem): string | null {
  return joinUnique([
    item.runtime_contract?.sandbox_profile ? `sandbox ${item.runtime_contract.sandbox_profile}` : null,
    item.sandbox_target ? `target ${item.sandbox_target}` : null,
    item.runtime_contract?.network_mode ? `network ${item.runtime_contract.network_mode}` : null,
    item.runtime_contract?.backend ? `backend ${item.runtime_contract.backend}` : null,
  ])
}

function approvalRuleSummary(item: KeeperApprovalQueueItem): string | null {
  return item.rule_match
    ? joinUnique([
        item.rule_match.rule_id ? `rule ${item.rule_match.rule_id}` : null,
        item.rule_match.matched_by ? `matched by ${item.rule_match.matched_by}` : null,
      ])
    : null
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
      <span class="ap-history-id mono">${item.id}</span>
      ${item.resolved_at
        ? html`<span class="ap-history-at">${formatDateTimeKo(item.resolved_at)}</span>`
        : null}
    </li>
  `
}

function approvalDetailRows(item: KeeperApprovalQueueItem): Array<{ label: string; value: string }> {
  return [
    { label: '키퍼', value: item.keeper_name },
    { label: '도구', value: item.tool_name },
    { label: '위험도', value: keeperApprovalRiskLabel(item.risk_level) },
    { label: '대기', value: apAge(item.waiting_s) },
    { label: '작업', value: approvalWorkSummary(item) },
    { label: '런타임', value: approvalRuntimeSummary(item) },
    { label: '선택 모델', value: compactText(item.selected_model) },
    { label: '턴', value: typeof item.turn_id === 'number' ? `turn ${item.turn_id}` : null },
    { label: '요청시각', value: compactText(item.requested_at) },
    { label: '판단', value: joinUnique([item.disposition, item.disposition_reason]) },
    { label: '규칙', value: approvalRuleSummary(item) },
    { label: '입력', value: compactText(item.input_preview) || '입력 미리보기 없음' },
  ].filter((row): row is { label: string; value: string } => Boolean(row.value))
}

// Open this keeper's workspace conversation (work.ts idiom).
function openKeeperWorkspace(name: string): void {
  navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

// Render the HITL context-summary worker's operator briefing. `available`
// carries the LLM-generated summary the operator reads before deciding;
// `pending`/`failed` are surfaced (not hidden) so a stuck or errored summary is
// visible rather than silently absent. `not_requested`/`null` render nothing.
function renderAvailableSummary(summary: HitlContextSummary) {
  return html`
    <div class="ap-summary sev-summary" data-testid="approval-summary" data-summary-state="available">
      <div class="ap-summary-head">
        <span class="ap-summary-label">🧭 컨텍스트 요약</span>
        ${typeof summary.uncertainty === 'number'
          ? html`<span class="ap-summary-uncertainty" title="요약 불확실도">불확실도 ${Math.round(summary.uncertainty * 100)}%</span>`
          : null}
      </div>
      <p class="ap-summary-text">${summary.context_summary}</p>
      ${summary.key_questions.length
        ? html`<ul class="ap-summary-questions">
            ${summary.key_questions.map(q => html`<li>${q}</li>`)}
          </ul>`
        : null}
      ${summary.suggested_options.length
        ? html`<ul class="ap-summary-options">
            ${summary.suggested_options.map(
              opt => html`<li class="ap-summary-option">
                <span class="ap-summary-option-label">${opt.label}</span>
                <span class="ap-summary-option-rationale">${opt.rationale}</span>
                ${opt.estimated_risk_delta
                  ? html`<span class="ap-summary-option-risk">${keeperApprovalRiskLabel(opt.estimated_risk_delta)}</span>`
                  : null}
              </li>`,
            )}
          </ul>`
        : null}
      ${summary.risk_rationale?.trim()
        ? html`<p class="ap-summary-rationale">${summary.risk_rationale.trim()}</p>`
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
  const sev = apSev(item.risk_level)
  const actingId = governanceApprovalActing.value
  const busy = actingId === item.id
  const anyBusy = Boolean(actingId)
  const title = approvalTitle(item)
  const sandbox = item.runtime_contract?.sandbox_profile?.trim() || item.sandbox_target?.trim() || null
  const detailReason = item.disposition_reason?.trim() || null

  return html`
    <article
      class=${`ap-card sev-${sev}`}
      data-testid="approval-card"
      data-approval-id=${item.id}
      data-selected=${selected ? 'true' : 'false'}
    >
      <div class="ap-rail"></div>
      <div class="ap-main">
        <div class="ap-h">
          <span class=${`ap-kind sev-${sev}`}>${apSevGlyph(sev)} ${keeperApprovalRiskLabel(item.risk_level)}</span>
          <span class="ap-tool mono">${item.tool_name}</span>
          <span class="ap-id mono">${item.id}</span>
          <span class=${`ap-age sev-${sev}`}>${apAge(item.waiting_s)}</span>
          <button
            type="button"
            class="ap-detail-toggle"
            aria-pressed=${selected}
            onClick=${() => onSelect(item.id)}
            title="요청 상세 보기"
          >상세</button>
        </div>
        <h3 class="ap-title">${title}</h3>
        ${detailReason ? html`<p class="ap-detail">${detailReason}</p>` : null}
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
              ${item.task_id || item.goal_id
                ? html`<button
                    type="button"
                    class="ap-req-goal mono"
                    onClick=${() => navigate('workspace', { section: 'work' })}
                    title="작업 보기"
                  >${[item.task_id ? `task ${item.task_id}` : null, item.goal_id ? `goal ${item.goal_id}` : null]
                    .filter(Boolean)
                    .join(' · ')}</button>`
                : null}
              ${sandbox ? html`<span class="ap-req-meta mono">sandbox ${sandbox}</span>` : null}
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
            class="ap-act always"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve', true)}
            title="승인하고 동일 요청을 자동 승인하는 Always 규칙을 저장합니다"
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '항상 승인'}</button>
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
  const sev = apSev(item.risk_level)
  const rows = approvalDetailRows(item)

  return html`
    <aside
      class=${`ap-detail-panel ap-detail-panel-${variant}`}
      data-testid=${variant === 'inline' ? 'approval-detail-panel-inline' : 'approval-detail-panel'}
      data-approval-id=${item.id}
    >
      <div class="ap-detail-panel-head">
        <span class=${`ap-kind sev-${sev}`}>${apSevGlyph(sev)} ${keeperApprovalRiskLabel(item.risk_level)}</span>
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

export function ApprovalsSurface() {
  useEffect(() => {
    void refreshGovernance()
    const disposeAutoRefresh = setupVisibleAutoRefresh(refreshGovernance, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
    }
  }, [])

  const items = governanceData.value?.approval_queue ?? []
  const resolvedItems = governanceData.value?.recent_resolved ?? []
  const error = governanceError.value
  // First load only: governanceResource is stale-while-revalidate, so a refetch
  // keeps the previous data — governanceData is null ONLY before the first load
  // resolves. Show a loading state then, instead of asserting the empty queue.
  const firstLoad = governanceLoading.value && governanceData.value === null
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const selectedItem = items.find(item => item.id === selectedId) ?? items[0] ?? null

  const stats = useMemo(() => {
    // "비가역 · 위험" counts the bad visual band only (critical), matching the red
    // sev-bad card rail and the prototype's `sev === 'bad'` KPI. The broader
    // high+critical predicate over-counts: a `high` item renders the warn (amber)
    // band, so including it made the red-styled KPI claim irreversible items that
    // no card flags red.
    const irreversible = items.filter(i => keeperApprovalRiskVisualBand(i.risk_level) === 'bad').length
    const longest = items.reduce((max, i) => Math.max(max, i.waiting_s ?? 0), 0)
    const keepers = new Set(items.map(i => i.keeper_name)).size
    return { irreversible, longest, keepers }
  }, [items])

  return html`
    <main class="ov ss-surface bg-surface-page text-text-primary" data-screen-label="승인 큐" data-testid="approvals-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">HITL</span>
            <h1>승인 · HITL 큐</h1>
            <p class="ov-sub">
              keeper가 위험·비가역 행동 전 결재를 청한 항목 ·
              <span title="감독자가 보는 단일 결재 지점">operator가 직접 승인·거부</span>
            </p>
          </div>
          ${items.length > 0
            ? html`<span class="ap-sla mono" title="가장 오래 대기 중인 건">최장 대기 ${apAge(stats.longest)}</span>`
            : null}
        </header>

        ${error ? html`<div class="ap-error" role="alert" data-testid="approvals-error">${error}</div>` : null}

        ${firstLoad
          ? html`<${LoadingState}>승인 큐 불러오는 중...<//>`
          : html`
        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div class="ov-kpi">
            <div class="ov-kpi-k">열린 승인</div>
            <div class=${`ov-kpi-v ${items.length ? 'warn' : 'ok'}`}>${items.length}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">비가역 · 위험</div>
            <div class=${`ov-kpi-v ${stats.irreversible ? 'bad' : ''}`} data-testid="approvals-kpi-irreversible">${stats.irreversible}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">최장 대기</div>
            <div class="ov-kpi-v">${items.length ? apAge(stats.longest) : '—'}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">관련 키퍼</div>
            <div class="ov-kpi-v volt">${stats.keepers}</div>
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
                <h3>열린 승인이 없습니다</h3>
                <div class="ap-clear-sub">HITL 큐가 비어 있습니다 — keeper들이 결재 대기 없이 진행 중입니다.</div>
              </div>
            `
          : null}
        ${resolvedItems.length > 0
          ? html`
              <section class="ap-history" data-testid="approvals-history">
                <h2 class="ap-history-title">최근 처리 (${resolvedItems.length})</h2>
                <ul class="ap-history-list">
                  ${resolvedItems.map(item => html`
                    <${ResolvedApprovalItem} key=${item.id} item=${item} />
                  `)}
                </ul>
              </section>
            `
          : null}
      `}
      </div>
    </main>
  `
}
