import { html } from 'htm/preact'
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
export { ActivityRail, GovernanceFreshnessStrip, RuntimeParamsPanel } from './governance-strips'
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
    <div class="flex flex-col gap-3.5">
      <${Card} title="판정 / 집행" class="section mb-3.5">
        ${!item || !detail
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">사건을 고르면 판정과 집행 경로가 보입니다.</div>`
          : html`
              <div class="flex flex-col gap-2">
                <h4>판정</h4>
                <div class="council-sub">
                  <span>${caseStatusLabel(ruling?.status || 'pending')}</span>
                  <span>${confidenceText(ruling?.confidence)}</span>
                  ${ruling?.generated_at ? html`<span><${TimeAgo} timestamp=${ruling.generated_at} /></span>` : null}
                </div>
                ${ruling?.summary
                  ? html`<div class="governance-summary-callout">${ruling.summary}</div>`
                  : html`<div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">아직 판정이 생성되지 않았습니다.</div>`}
                <div class="governance-chip rounded-full-row">
                  ${item.provenance ? html`<span class="governance-chip rounded-full">${item.provenance}</span>` : null}
                  ${item.risk_class ? html`<span class="governance-chip rounded-full">${item.risk_class}</span>` : null}
                  ${item.subject_type ? html`<span class="governance-chip rounded-full text-[#95a9cd]">${item.subject_type}</span>` : null}
                </div>
              </div>
              <${ActionRequestCard} order=${order} />
              ${order?.status === 'needs_human_gate'
                ? html`
                    <div class="flex flex-col gap-2">
                      <h4>관리자 승인</h4>
                      <div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">이 집행은 고위험으로 분류되어 수동 결재가 필요합니다.</div>
                      <div class="flex gap-2">
                        <button class="control-btn rounded-lg secondary" onClick=${() => respondToExecutionOrder('confirm')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '승인'}
                        </button>
                        <button class="control-btn rounded-lg ghost" onClick=${() => respondToExecutionOrder('deny')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '거부'}
                        </button>
                      </div>
                    </div>
                  `
                : null}
            `}
    <//>
      <${Card} title="심의 입력" class="section mb-3.5">
        ${!item
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">사건을 선택한 뒤 의견을 추가하세요.</div>`
          : html`
              <div class="flex flex-col gap-2">
                <div class="flex flex-wrap gap-2">
                  ${(['support', 'oppose', 'neutral'] as const).map(stance => html`
                    <button
                      class="control-btn rounded-lg ${governanceBriefStance.value === stance ? 'is-active' : 'ghost'}"
                      onClick=${() => {
                        governanceBriefStance.value = stance
                      }}
                    >
                      ${stanceLabel(stance)}
                    </button>
                  `)}
                </div>
                <textarea
                  class="control-input rounded-lg"
                  rows=${5}
                  placeholder="이 사건에 대한 심의 의견을 입력하세요..."
                  value=${governanceBriefInput.value}
                  onInput=${(event: Event) => {
                    governanceBriefInput.value = (event.target as HTMLTextAreaElement).value
                  }}
                ></textarea>
                <div class="flex gap-2">
                  <button
                    class="control-btn rounded-lg secondary"
                    onClick=${submitBrief}
                    disabled=${governanceBriefSubmitting.value || governanceBriefInput.value.trim() === ''}
                  >
                    ${governanceBriefSubmitting.value ? '기록 중...' : '의견 추가'}
                  </button>
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
      <div class="council-sub">
        <span>${request.resolved_tool || request.action_kind || request.target_type || 'action'}</span>
        <span>${orderStatusLabel(order.status)}</span>
      </div>
      ${request.target_type ? html`<div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">대상 ${request.target_type}${request.target_id ? `:${request.target_id}` : ''}</div>` : null}
      ${request.reason ? html`<div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">${request.reason}</div>` : null}
      ${request.payload_preview ? html`<pre class="council-detail governance-preview">${serializePreview(request.payload_preview)}</pre>` : null}
      ${order.execution_ref ? html`<div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">결과 참조 ${order.execution_ref}</div>` : null}
      ${order.result_summary ? html`<div class="text-[#c8daf7] text-[length:var(--fs-sm)] leading-[1.45]">${order.result_summary}</div>` : null}
    </div>
  `
}
