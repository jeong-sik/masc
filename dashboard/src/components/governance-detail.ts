import { html } from 'htm/preact'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { governanceToneClass } from '../lib/tone'
import type {
  GovernanceCaseBrief,
  GovernanceCaseBundle,
} from '../types'
import {
  detailLoading,
  governanceData,
  selectedCaseDetail,
  selectedDecisionKey,
} from './governance-store'
import {
  caseStatusLabel,
  getSelectedDecision,
  orderStatusLabel,
  stanceLabel,
} from './governance-utils'
import { ActivityRail, ParamAuditTrail } from './governance-strips'

export function PetitionEntry({ petition }: { petition: GovernanceCaseBundle['petitions'][number] }) {
  return html`
    <div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-card-border bg-card/40">
      <div class="flex flex-wrap items-center gap-2 text-[var(--text-muted)] text-[11px]">
        <span class="governance-badge rounded-full text-[var(--text-body)]">청원</span>
        <strong>${petition.created_by || petition.origin || 'system'}</strong>
        ${petition.created_at ? html`<span><${TimeAgo} timestamp=${petition.created_at} /></span>` : html``}
      </div>
      <div class="mt-2 text-[var(--text-strong)] leading-[1.5] break-words">${petition.title}</div>
      <div class="flex flex-wrap gap-1.5 mt-2">
        ${petition.source_refs.map(ref => html`<span class="governance-chip rounded-full">${ref}</span>`)}
      </div>
    </div>
  `
}

export function BriefEntry({ brief }: { brief: GovernanceCaseBrief }) {
  return html`
    <div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-card-border bg-card/40">
      <div class="flex flex-wrap items-center gap-2 text-[var(--text-muted)] text-[11px]">
        <span class="governance-badge rounded-full ${governanceToneClass(brief.stance)}">${stanceLabel(brief.stance)}</span>
        <strong>${brief.author}</strong>
        ${brief.created_at ? html`<span><${TimeAgo} timestamp=${brief.created_at} /></span>` : html``}
      </div>
      <div class="mt-2 text-[var(--text-strong)] leading-[1.5] break-words">${brief.summary}</div>
      <div class="flex flex-wrap gap-1.5 mt-2">
        ${brief.evidence_refs.map(ref => html`<span class="governance-chip rounded-full">${ref}</span>`)}
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
      class="section mb-4"
    >
      ${detailLoading.value
        ? html`<${LoadingState}>거버넌스 상세 불러오는 중...<//>`
        : !item || !detail
          ? html`<${EmptyState} message="왼쪽 수신함에서 사건을 선택하면 청원, 심의, 판정, 집행 기록이 여기에 표시됩니다." compact />`
          : html`
              <div class="flex justify-between items-start gap-4 mb-4">
                <div>
                  <h3>${detail.case.title}</h3>
                  <div class="mt-1 flex flex-wrap gap-2 text-[var(--text-muted)] text-[11px]">
                    <span>${detail.case.id}</span>
                    <span>${caseStatusLabel(detail.case.status)}</span>
                    ${detail.case.updated_at
                      ? html`<span><${TimeAgo} timestamp=${detail.case.updated_at} /></span>`
                      : null}
                  </div>
                </div>
                <div class="grid grid-cols-[repeat(2,minmax(90px,1fr))] gap-2">
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[var(--text-body)] text-[13px]"><strong>${petitions.length}</strong>건 청원</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[var(--text-body)] text-[13px]"><strong>${briefs.length}</strong>건 의견</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[var(--text-body)] text-[13px]"><strong>${item.confidence != null ? Math.round(item.confidence * 100) : 0}</strong>% 확신도</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[var(--text-body)] text-[13px]"><strong>${orderStatusLabel(detail.execution_order?.status)}</strong></span>
                </div>
              </div>
              <div class="flex flex-col gap-3">
                ${petitions.length === 0
                  ? html`<${EmptyState} message="기록된 청원이 없습니다." compact />`
                  : petitions.map(petition => html`<${PetitionEntry} key=${petition.id} petition=${petition} />`)}
              </div>
              <div class="flex flex-col gap-3">
                ${briefs.length === 0
                  ? html`<${EmptyState} message="심의 의견이 아직 없습니다." compact />`
                  : briefs.map(brief => html`<${BriefEntry} key=${brief.id} brief=${brief} />`)}
              </div>
              <${ActivityRail} />
              <${ParamAuditTrail} />
            `}
    <//>
  `
}
