import { html } from 'htm/preact'
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

export function PetitionEntry({ petition }: { petition: GovernanceCaseBundle['petitions'][number] }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge text-[#b7cbee]">청원</span>
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
      class="section mb-3.5"
     
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
