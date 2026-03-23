import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/empty-state'
import { FilterChips } from './common/filter-chips'
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
      <div class="mb-3 p-3 rounded-lg border border-[var(--warn-30)] bg-[var(--warn-12)] text-[13px] text-[#ffe09b]">
        모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
        ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
        테스트 잔재일 가능성이 높습니다.
      </div>
    ` : null}
    <div class="flex flex-wrap gap-x-3 gap-y-1 mb-2 text-[var(--text-muted)] text-[11px]">
      <span>진행 중 ${itemCount}건 / 활동 ${activityCount}건</span>
      ${data?.generated_at ? html`<span>${data.generated_at}</span>` : null}
    </div>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(155px,1fr))] gap-3 mb-4">
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">열린 케이스</span>
        <strong class="text-lg font-semibold text-[var(--text-strong)] tabular-nums">${summary?.cases_open ?? itemCount}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">판정 대기</span>
        <strong class="text-lg font-semibold text-[var(--text-strong)] tabular-nums">${summary?.pending_ruling ?? 0}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">자동집행 준비</span>
        <strong class="text-lg font-semibold text-[var(--text-strong)] tabular-nums">${summary?.ready_auto_execute ?? 0}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">관리자 승인 대기</span>
        <strong class="text-lg font-semibold text-[var(--text-strong)] tabular-nums">${summary?.needs_human_gate ?? 0}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">집행 완료</span>
        <strong class="text-lg font-semibold text-[var(--text-strong)] tabular-nums">${summary?.executed ?? 0}</strong>
      </div>
    </div>
  `
}

function GovernanceToolbar() {
  return html`
    <${Card} title="청원 콘솔" class="section mb-4">
      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-2 items-center">
          <input
            class="py-2 px-3 rounded-lg bg-[var(--white-5)] border border-[var(--border-slate-18)] text-[var(--text-body)] text-[13px] font-[inherit] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[rgba(71,184,255,0.55)] transition-colors"
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
            class="px-3 py-2 rounded-lg text-[12px] font-medium border transition-all cursor-pointer
              ${governanceStarting.value || governanceTopicInput.value.trim() === ''
                ? 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-12)] opacity-50 cursor-not-allowed'
                : 'bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)] hover:bg-[var(--accent-20)]'
              }"
            onClick=${submitPetition}
            disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
          >
            ${governanceStarting.value ? '접수 중...' : '청원 접수'}
          </button>
          <button
            class="px-3 py-2 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${refreshGovernance}
            disabled=${governanceLoading.value}
          >
            ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
        <${FilterChips}
          chips=${[
            { key: 'open', label: '진행 중' },
            { key: 'pending_ruling', label: '판정 대기' },
            { key: 'needs_human_gate', label: '승인 대기' },
            { key: 'executed', label: '집행 완료' },
            { key: 'blocked', label: '보류/종결' },
          ]}
          active=${governanceFilter}
          onChange=${() => { void refreshGovernance() }}
        />
        ${governanceError.value ? html`<div class="mt-2 p-2.5 rounded-lg border border-[rgba(239,68,68,0.35)] bg-[var(--bad-8)] text-[#f7b6b6] text-[12px]">${governanceError.value}</div>` : null}
      </div>
    <//>
  `
}

function DecisionInbox() {
  const items = filteredItemsByFilter(governanceFilter.value, governanceData.value?.items ?? [])
  return html`
    <${Card} title="사건 수신함" class="section mb-4">
      <div class="flex flex-col gap-2 governance-inbox">
        ${items.length === 0
          ? html`<${EmptyState} message="이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요." />`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button
                  class="council-row w-full text-left flex gap-3 p-4 rounded-xl border cursor-pointer transition-all duration-150
                    ${selected
                      ? 'border-[rgba(71,184,255,0.5)] bg-[var(--accent-14)]'
                      : 'border-[var(--card-border)] bg-[var(--card)] hover:bg-[var(--white-8)]'
                    }"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-18)]">${kindLabel(item.kind)}</span>
                      <span class="text-[14px] font-semibold text-[var(--text-strong)] break-words">${item.topic}</span>
                    </div>
                    <div class="mt-1.5 flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)]">
                      <span>${item.truth_summary || '사실 요약이 아직 없습니다'}</span>
                      ${item.last_activity_at
                        ? html`<span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="flex gap-1.5 flex-wrap mt-2">
                      ${item.origin ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] border border-[var(--border-slate-16)] bg-[var(--white-5)] text-[var(--text-muted)]">${item.origin}</span>` : null}
                      ${item.risk_class ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] border border-[var(--border-slate-16)] bg-[var(--white-5)] text-[var(--text-muted)]">${item.risk_class}</span>` : null}
                      ${item.provenance ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] border border-[var(--border-slate-16)] bg-[var(--white-5)] text-[var(--text-muted)]">${item.provenance}</span>` : null}
                      ${item.status === 'needs_human_gate'
                        ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border border-[var(--warn-30)] bg-[var(--warn-12)] text-[#ffe09b]">관리자 승인 필요</span>`
                        : null}
                      ${item.status === 'executed'
                        ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border border-[var(--ok-30)] bg-[var(--ok-12)] text-[#b4f5ca]">집행 완료</span>`
                        : null}
                    </div>
                  </div>
                  <div class="flex flex-col items-end gap-2 flex-shrink-0">
                    <span class="council-state inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-medium border ${governanceToneClass(item.status)}">${caseStatusLabel(item.status)}</span>
                    <span class="text-[11px] tabular-nums text-[var(--text-muted)]">${item.brief_count ?? 0}건</span>
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
    <div class="flex flex-col gap-1">
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
