import { html } from 'htm/preact'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { governanceToneClass } from '../lib/tone'
import type {
  GovernanceCaseBrief,
  GovernanceCaseBundle,
  GovernanceExecutionOrder,
  GovernanceTimelineEvent,
} from '../types'
import type { RuntimeParamsSurface } from '../api'
import {
  detailLoading,
  governanceActing,
  governanceBriefInput,
  governanceBriefStance,
  governanceBriefSubmitting,
  governanceData,
  runtimeLoading,
  runtimeParams,
  runtimeSurfaces,
  selectedCaseDetail,
  selectedDecisionKey,
} from './governance-store'
import {
  activityKindLabel,
  caseStatusLabel,
  confidenceText,
  formatParamValue,
  getSelectedDecision,
  orderStatusLabel,
  serializePreview,
  stanceLabel,
} from './governance-utils'

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
    <div class="governance-side-column">
      <${Card} title="판정 / 집행" class="section" semanticId="governance.guardrail">
        ${!item || !detail
          ? html`<div class="empty-state">사건을 고르면 판정과 집행 경로가 보입니다.</div>`
          : html`
              <div class="governance-side-block">
                <h4>판정</h4>
                <div class="council-sub">
                  <span>${caseStatusLabel(ruling?.status || 'pending')}</span>
                  <span>${confidenceText(ruling?.confidence)}</span>
                  ${ruling?.generated_at ? html`<span><${TimeAgo} timestamp=${ruling.generated_at} /></span>` : null}
                </div>
                ${ruling?.summary
                  ? html`<div class="governance-summary-callout">${ruling.summary}</div>`
                  : html`<div class="governance-side-line">아직 판정이 생성되지 않았습니다.</div>`}
                <div class="governance-chip-row">
                  ${item.provenance ? html`<span class="governance-chip">${item.provenance}</span>` : null}
                  ${item.risk_class ? html`<span class="governance-chip">${item.risk_class}</span>` : null}
                  ${item.subject_type ? html`<span class="governance-chip dim">${item.subject_type}</span>` : null}
                </div>
              </div>
              <${ActionRequestCard} order=${order} />
              ${order?.status === 'needs_human_gate'
                ? html`
                    <div class="governance-side-block">
                      <h4>관리자 승인</h4>
                      <div class="governance-side-line">이 집행은 고위험으로 분류되어 수동 결재가 필요합니다.</div>
                      <div class="governance-action-row">
                        <button class="control-btn secondary" onClick=${() => respondToExecutionOrder('confirm')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '승인'}
                        </button>
                        <button class="control-btn ghost" onClick=${() => respondToExecutionOrder('deny')} disabled=${governanceActing.value}>
                          ${governanceActing.value ? '처리 중...' : '거부'}
                        </button>
                      </div>
                    </div>
                  `
                : null}
            `}
    <//>
      <${Card} title="심의 입력" class="section" semanticId="governance.context">
        ${!item
          ? html`<div class="empty-state">사건을 선택한 뒤 의견을 추가하세요.</div>`
          : html`
              <div class="governance-side-block">
                <div class="governance-filter-row">
                  ${(['support', 'oppose', 'neutral'] as const).map(stance => html`
                    <button
                      class="control-btn ${governanceBriefStance.value === stance ? 'is-active' : 'ghost'}"
                      onClick=${() => {
                        governanceBriefStance.value = stance
                      }}
                    >
                      ${stanceLabel(stance)}
                    </button>
                  `)}
                </div>
                <textarea
                  class="control-input"
                  rows=${5}
                  placeholder="이 사건에 대한 심의 의견을 입력하세요..."
                  value=${governanceBriefInput.value}
                  onInput=${(event: Event) => {
                    governanceBriefInput.value = (event.target as HTMLTextAreaElement).value
                  }}
                ></textarea>
                <div class="governance-action-row">
                  <button
                    class="control-btn secondary"
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

/** Lifecycle step order for visual progress indicator */
const LIFECYCLE_ORDER: Record<string, number> = {
  petition_submitted: 0,
  brief_submitted: 1,
  ruling_issued: 2,
  execution_order: 3,
}
const LIFECYCLE_STEPS = ['청원', '의견', '판정', '집행']

function LifecycleProgress({ events }: { events: GovernanceTimelineEvent[] }) {
  const reached = new Set(events.map(e => LIFECYCLE_ORDER[e.kind] ?? -1))
  const maxStep = Math.max(...Array.from(reached), -1)
  return html`
    <div class="governance-lifecycle">
      ${LIFECYCLE_STEPS.map((label, i) => {
        const done = reached.has(i)
        const current = i === maxStep
        const cls = done ? (current ? 'lifecycle-current' : 'lifecycle-done') : 'lifecycle-pending'
        return html`
          ${i > 0 ? html`<span class="lifecycle-arrow ${done ? 'done' : ''}">-></span>` : null}
          <span class="lifecycle-step ${cls}">${label}</span>
        `
      })}
    </div>
  `
}

export function ActivityRail() {
  const events = (governanceData.value?.activity ?? []).slice(0, 20)

  // Group by case (item_id or topic)
  const grouped = new Map<string, { topic: string; events: GovernanceTimelineEvent[] }>()
  for (const event of events) {
    const key = event.item_id || event.topic || 'unknown'
    const existing = grouped.get(key)
    if (existing) {
      existing.events.push(event)
    } else {
      grouped.set(key, { topic: event.topic || key, events: [event] })
    }
  }

  return html`
    <${Card} title="활동 타임라인" class="section" semanticId="governance.activity">
      <div class="governance-activity-list">
        ${grouped.size === 0
          ? html`<div class="empty-state">거버넌스 활동이 아직 없습니다.</div>`
          : Array.from(grouped.entries()).map(([, group]) => html`
              <div class="governance-case-group">
                <div class="governance-case-header">
                  <span class="governance-case-topic">${group.topic}</span>
                  <${LifecycleProgress} events=${group.events} />
                </div>
                <div class="governance-case-events">
                  ${group.events.map((event: GovernanceTimelineEvent) => html`
                    <div class="governance-activity-row">
                      <span class="governance-badge ${governanceToneClass(event.kind)}">${activityKindLabel(event.kind)}</span>
                      <span class="governance-event-summary">${event.summary || ''}</span>
                      ${event.created_at ? html`<span class="governance-event-time"><${TimeAgo} timestamp=${event.created_at} /></span>` : null}
                    </div>
                  `)}
                </div>
              </div>
            `)}
      </div>
    <//>
  `
}

export function GovernanceFreshnessStrip() {
  const data = governanceData.value
  if (!data) return null
  const itemCount = data.items?.length ?? 0
  const activityCount = data.activity?.length ?? 0
  return html`
    <div class="monitor-meta" style="margin-top:4px;margin-bottom:8px">
      <span>데이터 범위: 진행 중 ${itemCount}건</span>
      <span>최근 활동: ${activityCount}건</span>
      ${data.generated_at ? html`<span>생성 시각: ${data.generated_at}</span>` : null}
    </div>
  `
}

export function RuntimeParamsPanel() {
  const params = runtimeParams.value
  const surfaces = runtimeSurfaces.value
  if (params.length === 0 && !runtimeLoading.value) return null

  return html`
    <${Card} title="Runtime Parameters" class="section" semanticId="governance.params">
      ${runtimeLoading.value
        ? html`<div class="loading-indicator">파라미터 로딩 중...</div>`
        : html`
            <div class="governance-params-surfaces">
              ${surfaces.map((surface: RuntimeParamsSurface) => {
                const surfaceParams = params.filter(p => surface.param_keys.includes(p.key))
                return html`
                  <div class="governance-surface-group">
                    <div class="governance-surface-head">
                      <strong>${surface.id}</strong>
                      <span class="governance-chip ${surface.risk === 'high' ? 'warn' : ''}">${surface.risk}</span>
                      <span class="council-sub">${surface.description}</span>
                    </div>
                    <div class="governance-params-table">
                      ${surfaceParams.map(param => html`
                        <div class="governance-param-row ${param.has_override ? 'overridden' : ''}">
                          <span class="governance-param-key">${param.key}</span>
                          <span class="governance-param-value">
                            ${formatParamValue(param.current)}
                            ${param.has_override
                              ? html`<span class="governance-chip warn" style="margin-left:4px">override</span>`
                              : null}
                          </span>
                          <span class="governance-param-default council-sub">
                            기본: ${formatParamValue(param.default)}
                          </span>
                        </div>
                      `)}
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}

export function ActionRequestCard({ order }: { order: GovernanceExecutionOrder | null | undefined }) {
  if (!order?.action_request) return null
  const request = order.action_request
  return html`
    <div class="governance-side-block">
      <h4>집행 명령</h4>
      <div class="council-sub">
        <span>${request.resolved_tool || request.action_kind || request.target_type || 'action'}</span>
        <span>${orderStatusLabel(order.status)}</span>
      </div>
      ${request.target_type ? html`<div class="governance-side-line">대상 ${request.target_type}${request.target_id ? `:${request.target_id}` : ''}</div>` : null}
      ${request.reason ? html`<div class="governance-side-line">${request.reason}</div>` : null}
      ${request.payload_preview ? html`<pre class="council-detail governance-preview">${serializePreview(request.payload_preview)}</pre>` : null}
      ${order.execution_ref ? html`<div class="governance-side-line">결과 참조 ${order.execution_ref}</div>` : null}
      ${order.result_summary ? html`<div class="governance-side-line">${order.result_summary}</div>` : null}
    </div>
  `
}

export function PetitionEntry({ petition }: { petition: GovernanceCaseBundle['petitions'][number] }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge neutral">청원</span>
        <strong>${petition.created_by || petition.origin || 'system'}</strong>
        ${petition.created_at ? html`<span><${TimeAgo} timestamp=${petition.created_at} /></span>` : null}
      </div>
      <div class="governance-ledger-body">${petition.title}</div>
      <div class="governance-chip-row">
        ${petition.source_refs.map(ref => html`<span class="governance-chip">${ref}</span>`)}
      </div>
    </div>
  `
}

export function BriefEntry({ brief }: { brief: GovernanceCaseBrief }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${governanceToneClass(brief.stance)}">${stanceLabel(brief.stance)}</span>
        <strong>${brief.author}</strong>
        ${brief.created_at ? html`<span><${TimeAgo} timestamp=${brief.created_at} /></span>` : null}
      </div>
      <div class="governance-ledger-body">${brief.summary}</div>
      <div class="governance-chip-row">
        ${brief.evidence_refs.map(ref => html`<span class="governance-chip">${ref}</span>`)}
      </div>
    </div>
  `
}

export function DecisionDetail() {
  const items = governanceData.value?.items ?? []
  const item = getSelectedDecision(selectedDecisionKey.value, items)
  const detail = selectedCaseDetail.value
  const petitions = detail?.petitions ?? []
  const briefs = detail?.case.briefs ?? []
  return html`
    <${Card}
      title=${item ? '사건 상세' : '거버넌스 상세'}
      class="section"
      semanticId="governance.detail"
    >
      ${detailLoading.value
        ? html`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`
        : !item || !detail
          ? html`<div class="empty-state">왼쪽 수신함에서 사건을 선택하면 청원, 심의, 판정, 집행 기록이 여기에 표시됩니다.</div>`
          : html`
              <div class="governance-detail-head">
                <div>
                  <h3>${detail.case.title}</h3>
                  <div class="council-sub">
                    <span>${detail.case.id}</span>
                    <span>${caseStatusLabel(detail.case.status)}</span>
                    ${detail.case.updated_at
                      ? html`<span><${TimeAgo} timestamp=${detail.case.updated_at} /></span>`
                      : null}
                  </div>
                </div>
                <div class="governance-balance-grid">
                  <span class="governance-balance"><strong>${petitions.length}</strong>건 청원</span>
                  <span class="governance-balance"><strong>${briefs.length}</strong>건 의견</span>
                  <span class="governance-balance"><strong>${item.confidence != null ? Math.round(item.confidence * 100) : 0}</strong>% 확신도</span>
                  <span class="governance-balance"><strong>${orderStatusLabel(detail.execution_order?.status)}</strong></span>
                </div>
              </div>
              <div class="governance-ledger">
                ${petitions.length === 0
                  ? html`<div class="empty-state">기록된 청원이 없습니다.</div>`
                  : petitions.map(petition => html`<${PetitionEntry} key=${petition.id} petition=${petition} />`)}
              </div>
              <div class="governance-ledger">
                ${briefs.length === 0
                  ? html`<div class="empty-state">심의 의견이 아직 없습니다.</div>`
                  : briefs.map(brief => html`<${BriefEntry} key=${brief.id} brief=${brief} />`)}
              </div>
            `}
    <//>
  `
}
