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
  loadRuntimeParams,
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
  ActivityRail,
  DecisionDetail,
  GovernanceFreshnessStrip,
  GuardrailPane,
  RuntimeParamsPanel,
} from './governance-panels'

// Re-export for consumers that import from './governance'
export { refreshGovernance, loadRuntimeParams } from './governance-store'

function GovernanceSummaryStrip() {
  const summary = governanceData.value?.summary
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const isStale = (oldestAge != null && oldestAge > 86400) || (lastActivityAge != null && lastActivityAge > 86400)

  return html`
    ${isStale ? html`
      <div class="governance-stale-warning">
        모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
        ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
        테스트 잔재일 가능성이 높습니다.
      </div>
    ` : null}
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 케이스</span>
        <strong>${summary?.cases_open ?? governanceData.value?.items?.length ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">판정 대기</span>
        <strong>${summary?.pending_ruling ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">자동집행 준비</span>
        <strong>${summary?.ready_auto_execute ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">관리자 승인 대기</span>
        <strong>${summary?.needs_human_gate ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">집행 완료</span>
        <strong>${summary?.executed ?? 0}</strong>
      </div>
    </div>
  `
}

function GovernanceToolbar() {
  return html`
    <${Card} title="청원 콘솔" class="section mb-3.5">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
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
            class="control-btn secondary"
            onClick=${submitPetition}
            disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
          >
            ${governanceStarting.value ? '접수 중...' : '청원 접수'}
          </button>
          <button class="control-btn ghost" onClick=${refreshGovernance} disabled=${governanceLoading.value}>
            ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
        <div class="governance-filter-row">
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
              class="control-btn ${governanceFilter.value === key ? 'is-active' : 'ghost'}"
              onClick=${async () => {
                governanceFilter.value = key
                await refreshGovernance()
              }}
            >
              ${label}
            </button>
          `)}
        </div>
        ${governanceError.value ? html`<div class="council-error">${governanceError.value}</div>` : null}
      </div>
    <//>
  `
}

function DecisionInbox() {
  const items = filteredItemsByFilter(governanceFilter.value, governanceData.value?.items ?? [])
  return html`
    <${Card} title="사건 수신함" class="section mb-3.5">
      <div class="council-list governance-inbox">
        ${items.length === 0
          ? html`<div class="empty-state">이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요.</div>`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button
                  class="council-row gap-3 cursor-pointer ${selected ? 'selected' : ''}"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="min-w-0">
                    <div class="governance-row-head">
                      <span class="governance-kind">${kindLabel(item.kind)}</span>
                      <span class="council-topic">${item.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${item.truth_summary || '사실 요약이 아직 없습니다'}</span>
                      ${item.last_activity_at
                        ? html`<span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="governance-chip-row">
                      ${item.origin ? html`<span class="governance-chip text-[#95a9cd]">${item.origin}</span>` : null}
                      ${item.risk_class ? html`<span class="governance-chip">${item.risk_class}</span>` : null}
                      ${item.provenance ? html`<span class="governance-chip">${item.provenance}</span>` : null}
                      ${item.status === 'needs_human_gate'
                        ? html`<span class="governance-chip warn">관리자 승인 필요</span>`
                        : null}
                      ${item.status === 'executed'
                        ? html`<span class="governance-chip ok">집행 완료</span>`
                        : null}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${governanceToneClass(item.status)}">${caseStatusLabel(item.status)}</span>
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
    void loadRuntimeParams()
  }, [])

  return html`
    <div class="section-grid">
      <${GovernanceFreshnessStrip} />
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
      <${ActivityRail} />
      <${RuntimeParamsPanel} />
    </div>
  `
}
