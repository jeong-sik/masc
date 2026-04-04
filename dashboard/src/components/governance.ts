import { html } from 'htm/preact'
import { AlertTriangle } from 'lucide-preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { KpiCard } from './common/stat-row'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/empty-state'
import { FilterChips } from './common/filter-chips'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { governanceToneClass } from '../lib/tone'
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
  loadParamAudit,
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
export { refreshGovernance, loadRuntimeParams, loadParamAudit } from './governance-store'

function governanceCaseTrackingRetired(): boolean {
  return governanceData.value?.case_tracking_available === false
}

function governanceRetiredMessage(): string {
  const note = governanceData.value?.note?.trim()
  if (note) return note
  return '거버넌스 케이스 추적은 중단되었고, 이 화면은 live judge 상태와 최근 판단만 표시합니다.'
}

function GovernanceSummaryStrip() {
  const data = governanceData.value
  const summary = data?.summary
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const caseTrackingRetired = governanceCaseTrackingRetired()
  const isStale = (oldestAge != null && oldestAge > 86400) || (lastActivityAge != null && lastActivityAge > 86400)
  const itemCount = data?.items?.length ?? 0
  const activityCount = data?.activity?.length ?? 0
  const judgmentCount = data?.judgments?.length ?? 0
  const retiredValue = '-'
  const retiredHint = 'retired'

  return html`
    ${caseTrackingRetired ? html`
      <div class="mb-3.5 flex items-center gap-3 rounded-xl border border-accent/25 bg-accent/10 p-3.5 text-[13px] font-medium text-text-strong shadow-sm" data-testid="governance-retired-banner">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>${governanceRetiredMessage()}</div>
      </div>
    ` : null}
    ${isStale ? html`
      <div class="mb-3.5 flex items-center gap-3 rounded-xl border border-warn/30 bg-warn/10 p-3.5 text-[13px] font-medium text-warn shadow-sm">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>
          모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
          ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
          <span class="opacity-80 ml-1">테스트 잔재일 가능성이 높습니다.</span>
        </div>
      </div>
    ` : null}
    <div class="mb-2.5 flex items-center justify-between px-0.5">
      <div class="flex items-center gap-3">
        <h2 class="text-lg font-bold text-text-strong tracking-wide">거버넌스</h2>
        <span class="rounded-md border border-white/5 bg-white/5 px-2 py-0.5 text-[11px] font-medium text-text-muted">
          ${caseTrackingRetired ? `judge-only / 최근 판단 ${judgmentCount}건` : `진행 중 ${itemCount}건 / 활동 ${activityCount}건`}
        </span>
      </div>
      ${data?.generated_at ? html`<span class="text-[11px] text-text-dim font-mono">${data.generated_at}</span>` : null}
    </div>
    <div class="mb-5 grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-3">
      <${KpiCard} label="열린 케이스" value=${caseTrackingRetired ? retiredValue : (summary?.cases_open ?? itemCount)} hint=${caseTrackingRetired ? retiredHint : undefined} />
      <${KpiCard} label="판정 대기" value=${caseTrackingRetired ? retiredValue : (summary?.pending_ruling ?? 0)} hint=${caseTrackingRetired ? retiredHint : undefined} />
      <${KpiCard} label="자동집행 준비" value=${caseTrackingRetired ? retiredValue : (summary?.ready_auto_execute ?? 0)} hint=${caseTrackingRetired ? retiredHint : undefined} />
      <${KpiCard} label="관리자 승인 대기" value=${caseTrackingRetired ? retiredValue : (summary?.needs_human_gate ?? 0)} hint=${caseTrackingRetired ? retiredHint : undefined} />
      <${KpiCard} label="집행 완료" value=${caseTrackingRetired ? retiredValue : (summary?.executed ?? 0)} hint=${caseTrackingRetired ? retiredHint : undefined} />
    </div>
    <${JudgeStatusBar} />
  `
}

function JudgeStatusBar() {
  const judge = governanceData.value?.judge
  if (!judge) return null
  const online = judge.judge_online === true
  const dotClass = online ? 'bg-ok' : 'bg-text-dim'
  const label = online
    ? (judge.refreshing ? '갱신 중' : '온라인')
    : (judge.last_error ? '오류' : '오프라인')
  return html`
    <div class="mb-4 flex items-center gap-3 rounded-lg border border-white/5 bg-white/3 px-3.5 py-2 text-[12px]" data-testid="judge-status">
      <span class="flex items-center gap-1.5">
        <span class="inline-block w-2 h-2 rounded-full ${dotClass}"></span>
        <span class="font-medium text-text-muted">평가 모델 ${label}</span>
      </span>
      ${judge.model_used ? html`<span class="text-text-dim">${judge.model_used}</span>` : null}
      ${judge.generated_at || judge.last_error
        ? html`
            <span class="ml-auto flex items-center gap-3 min-w-0">
              ${judge.generated_at
                ? html`<span class="text-text-dim"><${TimeAgo} timestamp=${judge.generated_at} /></span>`
                : null}
              ${judge.last_error
                ? html`<span class="text-bad/80 truncate max-w-[300px]">${judge.last_error}</span>`
                : null}
            </span>
          `
        : null}
    </div>
  `
}

function GovernanceToolbar() {
  return html`
    <div class="mb-5">
      <${Card} title="청원 콘솔" variant="compact">
        <div class="mt-1.5 flex flex-col gap-3.5">
          <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-3 items-center">
            <${TextInput}
              class="rounded-xl bg-card/48 px-3.5 py-2 text-[13px] font-sans text-text-strong placeholder:text-text-dim shadow-inner"
              name="petition_topic"
              ariaLabel="청원 제목"
              autoComplete="off"
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
            <${ActionButton}
              variant="primary"
              size="lg"
              class="rounded-xl border-transparent bg-accent/12 text-accent hover:bg-accent/20 disabled:bg-card/40 disabled:border-card-border disabled:text-text-muted"
              onClick=${submitPetition}
              disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
            >
              ${governanceStarting.value ? '접수 중...' : '청원 접수'}
            <//>
            <${ActionButton}
              variant="ghost"
              size="lg"
              class="rounded-xl border-transparent bg-white/5 px-3.5 py-2 text-[13px] font-semibold text-text-muted hover:bg-white/10 hover:text-text-strong"
              onClick=${refreshGovernance}
              disabled=${governanceLoading.value}
            >
              ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
            <//>
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
        ${governanceError.value ? html`<div class="mt-2 rounded-lg border border-[var(--bad-30)] bg-[var(--bad-8)] p-2.5 text-[12px] text-[#f7b6b6]">${governanceError.value}</div>` : null}
      </div>
      <//>
    </div>
  `
}

function governanceEmptyMessage(): string {
  const data = governanceData.value
  const allItems = data?.items ?? []
  const judgments = data?.judgments ?? []
  const lastActivityAge = data?.summary?.last_activity_age_s

  if (governanceCaseTrackingRetired()) {
    if (judgments.length > 0) {
      return '거버넌스 케이스 추적은 중단되었고, 아래 AI Judge 판단만 유지됩니다.'
    }
    return governanceRetiredMessage()
  }

  // All items and judgments empty — show guidance
  if (allItems.length === 0 && judgments.length === 0) {
    const ageText = formatAgeSummary(lastActivityAge)
    if (ageText != null) {
      return `거버넌스 사건이 없습니다. 마지막 활동: ${ageText} 전. keeper가 활동 중일 때 자동 생성됩니다.`
    }
    return '거버넌스 사건은 keeper가 활동 중일 때 자동 생성됩니다.'
  }

  // Items exist but filtered results are empty
  return '이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요.'
}

function DecisionInbox() {
  const items = filteredItemsByFilter(governanceFilter.value, governanceData.value?.items ?? [])
  const caseTrackingRetired = governanceCaseTrackingRetired()
  return html`
    <${Card} title=${caseTrackingRetired ? '사건 수신함 (retired)' : '사건 수신함'} class="section mb-5" variant="compact">
      <div class="flex flex-col gap-3 governance-inbox">
        ${items.length === 0
          ? html`<${EmptyState} message=${governanceEmptyMessage()} />`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button type="button"
                  class="group flex w-full gap-3 rounded-xl border p-4 text-left cursor-pointer transition-[transform,background-color,border-color,box-shadow] duration-200 shadow-sm shadow-black/8 hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]
                    ${selected
                      ? 'border-accent/40 bg-accent/10 shadow-[0_0_12px_rgba(71,184,255,0.12)]'
                      : 'border-card-border bg-card/34 hover:border-accent/30 hover:bg-card/52'
                    }"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="min-w-0 flex-1">
                    <div class="mb-1.5 flex min-w-0 items-center gap-2.5">
                      <span class="inline-flex items-center rounded-lg border border-accent/20 bg-accent/10 px-2 py-0.5 text-[10px] font-bold text-accent">${kindLabel(item.kind)}</span>
                      <span class="text-[15px] font-bold text-text-strong break-words group-hover:text-accent transition-colors leading-tight tracking-wide">${item.topic}</span>
                    </div>
                    <div class="mt-1.5 flex flex-wrap gap-2.5 text-[12px] text-text-muted/90 font-medium">
                      <span class="leading-relaxed opacity-90">${item.truth_summary || '사실 요약이 아직 없습니다'}</span>
                      ${item.last_activity_at
                        ? html`<span class="text-text-dim flex items-center gap-1.5"><span class="w-1 h-1 rounded-full bg-text-dim/50"></span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="mt-3 flex flex-wrap gap-1.5">
                      ${item.origin ? html`<span class="inline-flex items-center rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-muted">${item.origin}</span>` : null}
                      ${item.risk_class ? html`<span class="inline-flex items-center rounded-md border border-bad/20 bg-bad/10 px-2 py-0.5 text-[10px] font-medium text-bad">${item.risk_class}</span>` : null}
                      ${item.provenance ? html`<span class="inline-flex items-center rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-muted">${item.provenance}</span>` : null}
                      ${item.status === 'needs_human_gate'
                        ? html`<span class="inline-flex items-center rounded-md border border-warn/30 bg-warn/20 px-2 py-0.5 text-[10px] font-bold text-warn animate-pulse">승인 대기</span>`
                        : null}
                      ${item.status === 'executed'
                        ? html`<span class="inline-flex items-center rounded-md border border-ok/30 bg-ok/10 px-2 py-0.5 text-[10px] font-bold text-ok">집행 완료</span>`
                        : null}
                    </div>
                  </div>
                  <div class="flex flex-col items-end justify-between flex-shrink-0 pt-0.5">
                    <span class="inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-bold ${governanceToneClass(item.status)}">${caseStatusLabel(item.status)}</span>
                    <span class="mt-auto rounded-md border border-white/5 bg-white/5 px-2 py-0.5 text-[11px] font-medium text-text-dim">의견 ${item.brief_count ?? 0}</span>
                  </div>
                </button>
              `
            })}
      </div>
    <//>
  `
}

function JudgmentsSection() {
  const judgments = governanceData.value?.judgments ?? []
  if (judgments.length === 0) return null
  return html`
    <${Card} title=${governanceCaseTrackingRetired() ? 'AI Judge 판단 (live)' : 'AI Judge 판단'} class="section mb-5" variant="compact">
      <div class="flex flex-col gap-2.5">
        ${judgments.map(j => html`
          <div class="rounded-lg border border-card-border bg-card/34 p-3.5 text-[13px]" data-testid="judgment-item">
            <div class="flex items-center gap-2 mb-1.5">
              <span class="inline-flex items-center rounded-md border border-accent/20 bg-accent/10 px-1.5 py-0.5 text-[10px] font-bold text-accent">${j.target_kind ?? 'unknown'}</span>
              <span class="font-medium text-text-strong">${j.target_id ?? ''}</span>
              ${j.confidence != null ? html`<span class="ml-auto text-[11px] text-text-muted">신뢰도 ${Math.round(j.confidence * 100)}%</span>` : null}
            </div>
            <div class="text-text-muted/90 leading-relaxed">${j.summary ?? ''}</div>
            ${j.recommended_action ? html`
              <div class="mt-2 flex items-center gap-1.5 text-[11px]">
                <span class="rounded-md border border-accent/20 bg-accent/8 px-1.5 py-0.5 font-medium text-accent">${j.recommended_action.action_kind ?? 'action'}</span>
                ${j.recommended_action.resolved_tool ? html`<span class="text-text-dim font-mono">${j.recommended_action.resolved_tool}</span>` : null}
                ${j.recommended_action.reason ? html`<span class="text-text-muted/80 truncate max-w-[250px]">${j.recommended_action.reason}</span>` : null}
              </div>
            ` : null}
            ${j.guardrail_state?.requires_human_gate ? html`
              <div class="mt-1.5 inline-flex items-center rounded-md border border-warn/30 bg-warn/10 px-2 py-0.5 text-[10px] font-bold text-warn">승인 필요</div>
            ` : null}
            ${j.generated_at ? html`<div class="mt-1.5 text-[11px] text-text-dim"><${TimeAgo} timestamp=${j.generated_at} /></div>` : null}
          </div>
        `)}
      </div>
    <//>
  `
}

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
    void loadParamAudit()
  }, [])

  return html`
    <div class="flex flex-col gap-0.5">
      <${GovernanceSummaryStrip} />
      <${GovernanceToolbar} />
      <${JudgmentsSection} />
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
