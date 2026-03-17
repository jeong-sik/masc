import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import {
  decideGovernanceExecutionOrder,
  fetchDashboardGovernance,
  fetchGovernanceCaseStatus,
  fetchRuntimeParams,
  submitGovernanceCaseBrief,
  submitGovernancePetition,
} from '../api'
import type { RuntimeParam, RuntimeParamsSurface } from '../api'
import { registerGovernanceRefresh } from '../sse-store'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBrief,
  GovernanceCaseBundle,
  GovernanceDecisionItem,
  GovernanceExecutionOrder,
  GovernanceTimelineEvent,
} from '../types'

type GovernanceFilter = 'open' | 'pending_ruling' | 'needs_human_gate' | 'executed' | 'blocked'

const governanceLoading = signal(false)
const governanceStarting = signal(false)
const governanceActing = signal(false)
const governanceBriefSubmitting = signal(false)
const governanceError = signal('')
const governanceTopicInput = signal('')
const governanceBriefInput = signal('')
const governanceBriefStance = signal<'support' | 'oppose' | 'neutral'>('support')
const governanceFilter = signal<GovernanceFilter>('open')
const governanceData = signal<DashboardGovernanceResponse | null>(null)
const selectedDecisionKey = signal<string | null>(null)
const selectedCaseDetail = signal<GovernanceCaseBundle | null>(null)
const detailLoading = signal(false)

function itemKey(item: GovernanceDecisionItem): string {
  return `${item.kind}:${item.id}`
}

function getSelectedDecision(): GovernanceDecisionItem | null {
  const key = selectedDecisionKey.value
  const items = governanceData.value?.items ?? []
  if (!key) return null
  return items.find(item => itemKey(item) === key) ?? null
}

function isOpenStatus(status: string): boolean {
  const normalized = status.trim().toLowerCase()
  return normalized !== 'executed' && normalized !== 'blocked' && normalized !== 'closed'
}

function filteredItems(items: GovernanceDecisionItem[]): GovernanceDecisionItem[] {
  switch (governanceFilter.value) {
    case 'pending_ruling':
      return items.filter(item => item.status === 'pending_ruling')
    case 'needs_human_gate':
      return items.filter(item => item.status === 'needs_human_gate')
    case 'executed':
      return items.filter(item => item.status === 'executed')
    case 'blocked':
      return items.filter(item => item.status === 'blocked' || item.status === 'closed')
    case 'open':
    default:
      return items.filter(item => isOpenStatus(item.status))
  }
}

function serializePreview(value: unknown): string {
  if (value == null) return '없음'
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function toneClass(raw: string | null | undefined): string {
  const value = (raw || '').toLowerCase()
  if (value.includes('block') || value.includes('deny') || value.includes('closed')) return 'negative'
  if (
    value.includes('support') ||
    value.includes('approve') ||
    value.includes('ready') ||
    value.includes('executed') ||
    value.includes('done')
  ) {
    return 'positive'
  }
  return 'neutral'
}

function caseStatusLabel(value: string | null | undefined): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'pending':
    case 'pending_ruling':
      return '판정 대기'
    case 'ready_auto_execute':
      return '자동집행 준비'
    case 'needs_human_gate':
      return '승인 대기'
    case 'executed':
      return '집행 완료'
    case 'blocked':
      return '보류'
    case 'closed':
      return '종결'
    default:
      return value?.trim() || '확인 필요'
  }
}

function orderStatusLabel(value: string | null | undefined): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'queued_auto':
      return '자동 대기'
    case 'needs_human_gate':
      return '승인 대기'
    case 'auto_executed':
      return '자동 집행됨'
    case 'done':
      return '완료'
    case 'denied':
      return '거부됨'
    case 'blocked':
      return '보류'
    case 'none':
      return '없음'
    default:
      return value?.trim() || '없음'
  }
}

function stanceLabel(value: string): string {
  switch (value) {
    case 'support':
      return '찬성'
    case 'oppose':
      return '반대'
    case 'neutral':
      return '중립'
    default:
      return value
  }
}

function kindLabel(value: string): string {
  switch (value) {
    case 'case':
      return '사건'
    case 'petition':
      return '청원'
    default:
      return value
  }
}

function activityKindLabel(value: string): string {
  switch (value) {
    case 'petition_submitted':
      return '청원 접수'
    case 'brief_submitted':
      return '의견 제출'
    case 'ruling_issued':
      return '판정 발행'
    case 'execution_order':
      return '집행 명령'
    default:
      return value
  }
}

function confidenceText(confidence: number | null | undefined): string {
  if (typeof confidence !== 'number' || Number.isNaN(confidence)) return '판정 대기'
  return `${Math.round(confidence * 100)}%`
}

async function loadDecisionDetail(item: GovernanceDecisionItem | null) {
  selectedCaseDetail.value = null
  if (!item) return
  detailLoading.value = true
  governanceError.value = ''
  try {
    selectedCaseDetail.value = await fetchGovernanceCaseStatus(item.id)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : '거버넌스 상세를 불러오지 못했습니다'
  } finally {
    detailLoading.value = false
  }
}

async function selectDecision(item: GovernanceDecisionItem) {
  selectedDecisionKey.value = itemKey(item)
  await loadDecisionDetail(item)
}

export async function refreshGovernance() {
  governanceLoading.value = true
  governanceError.value = ''
  try {
    const data = await fetchDashboardGovernance()
    governanceData.value = data
    const items = filteredItems(data.items ?? [])
    const current = selectedDecisionKey.value
    const next = items.find(item => itemKey(item) === current) ?? items[0] ?? null
    selectedDecisionKey.value = next ? itemKey(next) : null
    await loadDecisionDetail(next)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : '거버넌스 상태를 불러오지 못했습니다'
  } finally {
    governanceLoading.value = false
  }
}

registerGovernanceRefresh(refreshGovernance)

async function submitPetition() {
  const title = governanceTopicInput.value.trim()
  if (!title) return
  governanceStarting.value = true
  try {
    const created = await submitGovernancePetition(title)
    governanceTopicInput.value = ''
    showToast(created?.case.id ? `청원을 접수했습니다: ${created.case.id}` : '청원을 접수했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '청원 접수에 실패했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceStarting.value = false
  }
}

async function submitBrief() {
  const item = getSelectedDecision()
  const summary = governanceBriefInput.value.trim()
  if (!item || !summary) return
  governanceBriefSubmitting.value = true
  try {
    const bundle = await submitGovernanceCaseBrief(item.id, governanceBriefStance.value, summary)
    governanceBriefInput.value = ''
    selectedCaseDetail.value = bundle
    showToast('심의 의견을 기록했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '심의 기록에 실패했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceBriefSubmitting.value = false
  }
}

async function respondToExecutionOrder(decision: 'confirm' | 'deny') {
  const item = getSelectedDecision()
  if (!item) return
  governanceActing.value = true
  try {
    await decideGovernanceExecutionOrder(item.id, decision)
    showToast(decision === 'confirm' ? '집행을 승인했습니다' : '집행을 거부했습니다', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : '집행 결정을 처리하지 못했습니다'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceActing.value = false
  }
}

function GovernanceSummaryStrip() {
  const summary = governanceData.value?.summary
  return html`
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
    <${Card} title="청원 콘솔" class="section" semanticId="governance.supervisor">
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
  const items = filteredItems(governanceData.value?.items ?? [])
  return html`
    <${Card} title="사건 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${items.length === 0
          ? html`<div class="empty-state">지금 필터에 맞는 사건이 없습니다.</div>`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button
                  class="council-row governance-decision-row ${selected ? 'selected' : ''}"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="council-row-main">
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
                      ${item.origin ? html`<span class="governance-chip dim">${item.origin}</span>` : null}
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
                    <span class="council-state ${toneClass(item.status)}">${caseStatusLabel(item.status)}</span>
                    <span class="governance-vote-meter">${item.brief_count ?? 0}건</span>
                  </div>
                </button>
              `
            })}
      </div>
    <//>
  `
}

function PetitionEntry({ petition }: { petition: GovernanceCaseBundle['petitions'][number] }) {
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

function BriefEntry({ brief }: { brief: GovernanceCaseBrief }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${toneClass(brief.stance)}">${stanceLabel(brief.stance)}</span>
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

function DecisionDetail() {
  const item = getSelectedDecision()
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
          ? html`<div class="empty-state">사건을 고르면 청원, 심의, 판정, 집행 기록을 볼 수 있습니다.</div>`
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

function ActionRequestCard({ order }: { order: GovernanceExecutionOrder | null | undefined }) {
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

function GuardrailPane() {
  const item = getSelectedDecision()
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

function ActivityRail() {
  const events = (governanceData.value?.activity ?? []).slice(0, 8)
  return html`
    <${Card} title="최근 활동" class="section" semanticId="governance.activity">
      <div class="governance-activity-list">
        ${events.length === 0
          ? html`<div class="empty-state">기록된 활동이 아직 없습니다.</div>`
          : events.map((event: GovernanceTimelineEvent) => html`
              <div class="governance-activity-row">
                <div class="governance-ledger-head">
                  <span class="governance-badge ${toneClass(event.kind)}">${activityKindLabel(event.kind)}</span>
                  ${event.created_at ? html`<span><${TimeAgo} timestamp=${event.created_at} /></span>` : null}
                </div>
                <div class="governance-ledger-body">${event.summary || event.topic || '활동이 기록되었습니다.'}</div>
              </div>
            `)}
      </div>
    <//>
  `
}

function GovernanceFreshnessStrip() {
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

// ── Runtime Params Panel ────────────────────────

const runtimeParams = signal<RuntimeParam[]>([])
const runtimeSurfaces = signal<RuntimeParamsSurface[]>([])
const runtimeLoading = signal(false)

async function loadRuntimeParams() {
  runtimeLoading.value = true
  try {
    const data = await fetchRuntimeParams()
    runtimeParams.value = data.parameters ?? []
    runtimeSurfaces.value = data.surfaces ?? []
  } catch {
    // silent — params panel is optional
  } finally {
    runtimeLoading.value = false
  }
}

function formatParamValue(value: unknown): string {
  if (value === null || value === undefined) return '-'
  if (typeof value === 'string') return value
  if (typeof value === 'number') return String(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return JSON.stringify(value)
}

function RuntimeParamsPanel() {
  const params = runtimeParams.value
  const surfaces = runtimeSurfaces.value
  if (params.length === 0 && !runtimeLoading.value) return null

  return html`
    <${Card} title="Runtime Parameters" class="section" semanticId="governance.params">
      ${runtimeLoading.value
        ? html`<div class="loading-indicator">파라미터 로딩 중...</div>`
        : html`
            <div class="governance-params-surfaces">
              ${surfaces.map(surface => {
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
        <${GuardrailPane} />
      </div>
      <${ActivityRail} />
      <${RuntimeParamsPanel} />
    </div>
  `
}
