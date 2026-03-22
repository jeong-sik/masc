import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { governanceToneClass } from '../lib/tone'
import type { GovernanceFilter } from './governance-utils'
import {
  governanceData,
  governanceError,
  governanceFilter,
  governanceLoading,
  governanceStarting,
  governanceTopicInput,
  refreshGovernance,
  respondToExecutionOrder,
  selectDecision,
  selectedDecisionKey,
  submitBrief,
  submitPetition,
} from './governance-store'
import {
  caseStatusLabel,
  filteredItemsByFilter,
  formatAgeSummary,
  itemKey,
  kindLabel,
} from './governance-utils'
import {
  DecisionDetail,
  GuardrailPane,
} from './governance-panels'

// Re-export for consumers that import from './governance'
export { refreshGovernance, loadRuntimeParams } from './governance-store'

function GovernanceSummaryStrip() {
  const data = governanceData.value
  const summary = data?.summary
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const isStale = (oldestAge != null && oldestAge > 86400) || (lastActivityAge != null && lastActivityAge > 86400)
  const itemCount = data?.items?.length ?? 0
  const activityCount = data?.activity?.length ?? 0

  return html`
    ${isStale ? html`
      <div class="governance-stale-warning rounded-md">
        모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
        ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
        테스트 잔재일 가능성이 높습니다.
      </div>
    ` : null}
    <div class="flex flex-wrap gap-x-3 gap-y-1 mb-1 text-[var(--text-muted)] text-[length:var(--fs-xs)]">
      <span>진행 중 ${itemCount}건 / 활동 ${activityCount}건</span>
      ${data?.generated_at ? html`<span>${data.generated_at}</span>` : null}
    </div>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-2.5 mb-3">
      <div class="board-summary-item flex flex-col gap-1">
        <span class="board-summary-label text-[color:var(--text-muted)] text-[length:var(--fs-xs)] tracking-[0.06em] uppercase">열린 케이스</span>
        <strong>${summary?.cases_open ?? itemCount}</strong>
      </div>
      <div class="board-summary-item flex flex-col gap-1">
        <span class="board-summary-label text-[color:var(--text-muted)] text-[length:var(--fs-xs)] tracking-[0.06em] uppercase">판정 대기</span>
        <strong>${summary?.pending_ruling ?? 0}</strong>
      </div>
      <div class="board-summary-item flex flex-col gap-1">
        <span class="board-summary-label text-[color:var(--text-muted)] text-[length:var(--fs-xs)] tracking-[0.06em] uppercase">자동집행 준비</span>
        <strong>${summary?.ready_auto_execute ?? 0}</strong>
      </div>
      <div class="board-summary-item flex flex-col gap-1">
        <span class="board-summary-label text-[color:var(--text-muted)] text-[length:var(--fs-xs)] tracking-[0.06em] uppercase">관리자 승인 대기</span>
        <strong>${summary?.needs_human_gate ?? 0}</strong>
      </div>
      <div class="board-summary-item flex flex-col gap-1">
        <span class="board-summary-label text-[color:var(--text-muted)] text-[length:var(--fs-xs)] tracking-[0.06em] uppercase">집행 완료</span>
        <strong>${summary?.executed ?? 0}</strong>
      </div>
    </div>
  `
}

function GovernanceToolbar() {
  return html`
    <${Card} title="청원 콘솔" class="section mb-3.5">
      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-2 items-center">
          <input
            class="control-input rounded-lg"
            type="text"
            placeholder="청원 제목을 입력하세요..."
            value=${governanceTopicInput.value}
            onInput=${(event: Event) => {
              governanceTopicInput.value = (event.target as HTMLInputElement).value
            }}
            onKeyDown=${(event: KeyboardEvent) => {
              if (event.key === 'Enter') submitPetition()
            }}
            disabled=${governanceStarting.value}
          />
          <button
            class="control-btn rounded-lg secondary"
            onClick=${submitPetition}
            disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
          >
            ${governanceStarting.value ? '접수 중...' : '청원 접수'}
          </button>
          <button class="control-btn rounded-lg ghost" onClick=${refreshGovernance} disabled=${governanceLoading.value}>
            ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
        <div class="flex flex-wrap gap-2">
          ${(
            [
              ['open', '진행 중'],
              ['pending_ruling', '판정 대기'],
              ['needs_human_gate', '승인 대기'],
              ['executed', '집행 완료'],
              ['blocked', '보류/종결'],
            ] as Array<[GovernanceFilter, string]>
          ).map(([key, label]) => html`
            <button
              class="control-btn rounded-lg ${governanceFilter.value === key ? 'is-active' : 'ghost'}"
              onClick=${async () => {
                governanceFilter.value = key
                await refreshGovernance()
              }}
            >
              ${label}
            </button>
          `)}
        </div>
        ${governanceError.value ? html`<div class="mt-2.5 border border-[rgba(239,68,68,0.35)] py-2 px-2.5 text-[#f7b6b6] text-[length:var(--fs-sm)] rounded-lg">${governanceError.value}</div>` : null}
      </div>
    <//>
  `
}

function DecisionInbox() {
  const items = filteredItemsByFilter(governanceFilter.value, governanceData.value?.items ?? [])
  return html`
    <${Card} title="사건 수신함" class="section mb-3.5">
      <div class="flex flex-col gap-2 governance-inbox">
        ${items.length === 0
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요.</div>`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button
                  class="council-row gap-3 cursor-pointer ${selected ? 'selected' : ''}"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="min-w-0">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class="governance-kind rounded-full">${kindLabel(item.kind)}</span>
                      <span class="text-[#e8f0ff] text-[length:var(--fs-md)] font-semibold break-words">${item.topic}</span>
                    </div>
                    <div class="mt-1 flex flex-wrap gap-2 text-[#8ea9d6] text-[length:var(--fs-xs)]">
                      <span>${item.truth_summary || '사실 요약이 아직 없습니다'}</span>
                      ${item.last_activity_at
                        ? html`<span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="governance-chip rounded-full-row">
                      ${item.origin ? html`<span class="governance-chip rounded-full text-[#95a9cd]">${item.origin}</span>` : null}
                      ${item.risk_class ? html`<span class="governance-chip rounded-full">${item.risk_class}</span>` : null}
                      ${item.provenance ? html`<span class="governance-chip rounded-full">${item.provenance}</span>` : null}
                      ${item.status === 'needs_human_gate'
                        ? html`<span class="governance-chip rounded-full warn">관리자 승인 필요</span>`
                        : null}
                      ${item.status === 'executed'
                        ? html`<span class="governance-chip rounded-full ok">집행 완료</span>`
                        : null}
                    </div>
                  </div>
                  <div class="flex flex-col items-end gap-2">
                    <span class="council-state rounded-full ${governanceToneClass(item.status)}">${caseStatusLabel(item.status)}</span>
                    <span class="governance-vote-meter">${item.brief_count ?? 0}건</span>
                  </div>
                </button>
              `
            })}
      </div>
    <//>
  `
}

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
  }, [])

  return html`
    <div class="section-grid">
      <${GovernanceSummaryStrip} />
      <${GovernanceToolbar} />
      <div class="governance-layout">
        <${DecisionInbox} />
        <${DecisionDetail} />
        <${GuardrailPane}
          submitBrief=${submitBrief}
          respondToExecutionOrder=${respondToExecutionOrder}
        />
      </div>
    </div>
  `
}
