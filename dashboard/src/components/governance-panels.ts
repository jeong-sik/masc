import { html } from 'htm/preact'
import { Markdown } from "./common/markdown"
import { AlertTriangle } from 'lucide-preact'
import { ActionButton } from './common/button'
import { TextArea } from './common/input'
import { EmptyState } from './common/empty-state'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import type { GovernanceExecutionOrder } from '../types'
import {
  governanceActing,
  governanceBriefInput,
  governanceBriefStance,
  governanceBriefSubmitting,
  governanceData,
  selectedCaseDetail,
  selectedDecisionKey,
} from './governance-store'
import {
  caseStatusLabel,
  confidenceText,
  getSelectedDecision,
  orderStatusLabel,
  serializePreview,
  stanceLabel,
} from './governance-utils'

// Re-export from split files for backward compatibility.
// ActivityRail is now rendered inside DecisionDetail only (not in main view).
// GovernanceFreshnessStrip was inlined into GovernanceSummaryStrip.
// RuntimeParamsPanel was removed (use masc_set_param CLI instead).
export { ActivityRail } from './governance-strips'
export { DecisionDetail } from './governance-detail'

export function GuardrailPane({
  submitBrief,
  respondToExecutionOrder,
}: {
  submitBrief: () => void
  respondToExecutionOrder: (decision: 'confirm' | 'deny') => void
}) {
  const items = governanceData.value?.items ?? []
  const item = getSelectedDecision(selectedDecisionKey.value, items)
  const detail = selectedCaseDetail.value
  const ruling = detail?.ruling
  const order = detail?.execution_order
  return html`
    <div class="flex flex-col gap-4">
      <${Card} title="판정 / 집행" class="section" variant="compact">
        ${!item || !detail
          ? html`<${EmptyState} message="사건을 고르면 판정과 집행 경로가 보입니다." compact />`
          : html`
              <div class="flex flex-col gap-3">
                <h4 class="text-[11px] font-bold uppercase tracking-widest text-accent mb-1 flex items-center gap-2">
                  <span class="w-1.5 h-1.5 rounded-full bg-accent/50 shadow-[0_0_8px_rgba(71,184,255,0.6)]"></span>
                  판정 요약
                </h4>
                <div class="flex flex-wrap gap-2.5 text-text-muted text-[11px] font-medium">
                  <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${caseStatusLabel(ruling?.status || 'pending')}</span>
                  <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${confidenceText(ruling?.confidence)}</span>
                  ${ruling?.generated_at ? html`<span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10"><${TimeAgo} timestamp=${ruling.generated_at} /></span>` : null}
                </div>
                ${ruling?.summary
                  ? html`<div class="mb-3.5 mt-1.5 rounded-xl border border-accent/20 bg-[var(--accent-10)] p-3.5 text-[13px] leading-relaxed text-text-strong shadow-sm">${ruling.summary}</div>`
                  : html`<div class="mt-1.5 rounded-xl border border-card-border/50 bg-card/34 p-3.5 text-center text-[13px] italic text-text-muted">아직 판정이 생성되지 않았습니다.</div>`}
                <div class="mb-1.5 flex flex-wrap gap-1.5">
                  ${item.provenance ? html`<span class="inline-flex items-center rounded-lg border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-muted">${item.provenance}</span>` : null}
                  ${item.risk_class ? html`<span class="inline-flex items-center rounded-lg border border-bad/20 bg-bad/10 px-2 py-0.5 text-[10px] font-medium text-bad">${item.risk_class}</span>` : null}
                  ${item.subject_type ? html`<span class="inline-flex items-center rounded-lg border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-dim">${item.subject_type}</span>` : null}
                </div>
              </div>
              
              <div class="mt-3.5 border-t border-card-border/50 pt-3.5">
                <${ActionRequestCard} order=${order} />
              </div>
              
              ${order?.status === 'needs_human_gate'
                ? html`
                    <div class="mt-4 flex flex-col gap-3 rounded-xl border border-warn/30 bg-warn/10 p-4 shadow-inner">
                      <h4 class="text-[12px] font-bold text-warn uppercase tracking-wider flex items-center gap-1.5"><${AlertTriangle} size=${14} /> 관리자 승인 대기</h4>
                      <div class="text-text-strong text-[13px] leading-relaxed">이 집행 명령은 고위험 작업으로 분류되어 승인이 필요합니다.</div>
                      <div class="mt-1.5 flex gap-2.5">
                        <button type="button" class="rounded-xl border border-ok/30 bg-ok/20 px-4 py-2 text-[13px] font-semibold text-ok transition-all duration-200 hover:bg-ok/30 disabled:opacity-50 shadow-sm shadow-black/15" onClick=${() => respondToExecutionOrder('confirm')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '명령 승인'}
                        </button>
                        <button type="button" class="rounded-xl border border-bad/30 bg-bad/20 px-4 py-2 text-[13px] font-semibold text-bad transition-all duration-200 hover:bg-bad/30 disabled:opacity-50 shadow-sm shadow-black/15" onClick=${() => respondToExecutionOrder('deny')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '집행 거부'}
                        </button>
                      </div>
                    </div>
                  `
                : null}
            `}
      <//>
      
      <${Card} title="심의 의견 제출" class="section" variant="compact">
        ${!item
          ? html`<${EmptyState} message="사건을 선택한 뒤 의견을 추가하세요." compact />`
          : html`
              <div class="flex flex-col gap-4">
                <div class="flex w-fit flex-wrap gap-1.5 rounded-xl border border-card-border/50 bg-card/32 p-1">
                  ${(['support', 'oppose', 'neutral'] as const).map(stance => html`
                    <button type="button"
                      class="rounded-lg border px-3 py-1.5 text-[12px] font-bold cursor-pointer transition-all duration-200
                        ${governanceBriefStance.value === stance
                          ? 'bg-accent/20 text-accent border-accent/30 shadow-sm'
                          : 'bg-transparent text-text-muted border-transparent hover:bg-white/5 hover:text-text-body'
                        }"
                      onClick=${() => {
                        governanceBriefStance.value = stance
                      }}
                    >
                      ${stanceLabel(stance)}
                    </button>
                  `)}
                </div>
                <${TextArea}
                  rows=${5}
                  placeholder="이 사건에 대한 심의 의견을 입력하세요..."
                  value=${governanceBriefInput.value}
                  onInput=${(event: Event) => {
                    governanceBriefInput.value = (event.target as HTMLTextAreaElement).value
                  }}
                />
                <div class="flex gap-2">
                  <${ActionButton}
                    onClick=${submitBrief}
                    disabled=${governanceBriefSubmitting.value || governanceBriefInput.value.trim() === ''}
                  >
                    ${governanceBriefSubmitting.value ? '기록 중...' : '의견 추가'}
                  <//>
                </div>
              </div>
            `}
      <//>
    </div>
  `
}

export function ActionRequestCard({ order }: { order: GovernanceExecutionOrder | null | undefined }) {
  if (!order?.action_request) return null
  const request = order.action_request
  return html`
    <div class="flex flex-col gap-2">
      <h4>집행 명령</h4>
      <div class="mt-1 flex flex-wrap gap-2 text-[var(--text-muted)] text-[11px]">
        <span>${request.resolved_tool || request.action_kind || request.target_type || 'action'}</span>
        <span>${orderStatusLabel(order.status)}</span>
      </div>
      ${request.target_type ? html`<div class="text-[var(--text-body)] text-[13px] leading-[1.45]">대상 ${request.target_type}${request.target_id ? `:${request.target_id}` : ''}</div>` : null}
      ${request.reason ? html`<div class="text-[var(--text-body)] text-[13px] leading-[1.45]">${request.reason}</div>` : null}
      ${request.payload_preview ? html`<div class="mt-0 max-h-[180px] overflow-auto rounded-[9px] border border-[var(--card-border)] bg-[var(--bg-0)] custom-scrollbar"><${Markdown} text=${'```json\n' + serializePreview(request.payload_preview) + '\n```'} /></div>` : null}
      ${order.execution_ref ? html`<div class="text-[var(--text-body)] text-[13px] leading-[1.45]">결과 참조 ${order.execution_ref}</div>` : null}
      ${order.result_summary ? html`<div class="text-[var(--text-body)] text-[13px] leading-[1.45]">${order.result_summary}</div>` : null}
    </div>
  `
}
