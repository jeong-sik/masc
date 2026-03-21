import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { route } from '../router'
import { proofError, proofLoading, proofSnapshot, refreshProofSnapshot } from '../proof-store'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofSelection,
  DashboardProofTimelineItem,
  DashboardProofToolEvidence,
  DashboardProofVerdict,
} from '../types'
import { prettyJson, relativeTime } from './command/helpers'

type DedupedTimelineItem = DashboardProofTimelineItem & {
  sources: string[]
}

function verdictTone(verdict?: DashboardProofVerdict | null): string {
  if (verdict === 'proven') return 'ok'
  if (verdict === 'partial') return 'warn'
  return 'bad'
}

function safeArray<T>(value: T[] | null | undefined): T[] {
  return Array.isArray(value) ? value : []
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function compactPath(path: string): string {
  const parts = path.split('/')
  return parts.length <= 3 ? path : `…/${parts.slice(-3).join('/')}`
}

function verdictChipLabel(verdict: DashboardProofVerdict): string {
  if (verdict === 'proven') return '충분'
  if (verdict === 'partial') return '부분'
  return '부족'
}

function verdictLabel(verdict: DashboardProofVerdict): string {
  if (verdict === 'proven') return '협업 증거가 충분합니다'
  if (verdict === 'partial') return '흔적은 있으나 협업 증거가 덜 모였습니다'
  return '증거가 부족합니다'
}

function verdictReasonLines(
  verdict: DashboardProofVerdict,
  liveVerdict: DashboardProofVerdict,
  historicalVerdict: DashboardProofVerdict | null,
  actorCount: number,
  plannedActorCount: number,
  unansweredActorCount: number,
  interactionCount: number,
  evidenceCount: number,
  cpTraceCount: number,
): string[] {
  const lines = [
    `${actorCount}명이 실제 흔적을 남겼고, 계획된 참여자는 ${plannedActorCount}명입니다.`,
    interactionCount > 0
      ? `서로를 참조한 상호작용 증거가 ${interactionCount}건 있습니다.`
      : '서로를 참조한 명시적 상호작용 증거가 아직 없습니다.',
    evidenceCount > 0
      ? `도구·산출물·체크포인트 증거가 ${evidenceCount}건 있습니다.`
      : '도구·산출물·체크포인트 증거가 거의 없습니다.',
    cpTraceCount > 0
      ? `CPv2 backing trace가 ${cpTraceCount}건 있어 실행 흔적은 남아 있습니다.`
      : '관리형 backing trace는 아직 없습니다.',
  ]
  if (historicalVerdict === 'proven' && liveVerdict === 'insufficient') {
    return [
      lines[0] ?? '',
      '왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.',
      '다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다.',
    ]
  }
  if (historicalVerdict === 'proven' && liveVerdict === 'partial') {
    return [
      lines[0] ?? '',
      '왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.',
      '다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다.',
    ]
  }
  if (verdict === 'partial') {
    return [
      lines[0] ?? '',
      unansweredActorCount > 0
        ? `partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${unansweredActorCount}명 있습니다.`
        : interactionCount === 0
          ? 'partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.'
          : 'partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.',
      cpTraceCount > 0
        ? '다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.'
        : '다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다.',
    ]
  }
  if (verdict === 'proven') {
    return [
      lines[0] ?? '',
      '결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.',
      '다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다.',
    ]
  }
  return [
    lines[0] ?? '',
    unansweredActorCount > 0
      ? `결론: 협업 시도는 있었지만 무응답 참여자가 ${unansweredActorCount}명 있어 협업 증거로 인정하기 어렵습니다.`
      : '결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.',
    evidenceCount > 0
      ? '다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.'
      : '다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다.',
  ]
}

function verdictBasisLabel(basis?: string | null): string {
  if (basis === 'historical_only') return '과거 기록만'
  if (basis === 'live_and_historical') return '실시간 + 과거'
  return '실시간'
}

function selectionTone(selection?: DashboardProofSelection | null): string {
  if (selection?.mode === 'requested_not_found') return 'bad'
  if (selection?.mode === 'latest_auto_selected') return 'warn'
  return 'ok'
}

function selectionLabel(selection?: DashboardProofSelection | null): string {
  if (selection?.mode === 'requested_not_found') return '선택 실패'
  if (selection?.mode === 'latest_auto_selected') return '자동 선택'
  if (selection?.mode === 'explicit') return '명시 선택'
  return '선택 없음'
}

function actorActivityTone(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') {
    return (item.interaction_count ?? 0) > 0 || (item.tool_evidence_count ?? 0) > 0 ? 'ok' : 'warn'
  }
  if (item.activity_state === 'mentioned_only') return 'warn'
  return 'muted'
}

function actorActivityLabel(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') return '실제 흔적'
  if (item.activity_state === 'mentioned_only') return '호출만 됨'
  return '계획만 됨'
}

function actorActivityMeta(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') {
    return `턴 ${item.turn_count ?? 0} · spawn ${item.spawn_count ?? 0} · 도구 근거 ${item.tool_evidence_count ?? 0}`
  }
  if (item.activity_state === 'mentioned_only') {
    const caller = item.requested_by ? `호출자 ${item.requested_by}` : '호출자 미상'
    return `호출 ${item.mention_count ?? 0}회 · ${caller}`
  }
  return '계획된 참여자이지만 아직 이벤트가 없습니다.'
}

function toolEvidenceTags(item: DashboardProofToolEvidence): string[] {
  return Array.isArray(item.tool_names) ? item.tool_names : []
}

function SelectionCard({
  selection,
  summary,
}: {
  selection?: DashboardProofSelection | null
  summary?: {
    historical_verdict?: DashboardProofVerdict | null
    live_verdict?: DashboardProofVerdict | null
  } | null
}) {
  if (!selection || selection.mode === 'explicit') return null
  const historicalStronger =
    selection.mode === 'latest_auto_selected'
    && summary?.historical_verdict === 'proven'
    && summary?.live_verdict !== 'proven'
  return html`
    <div class="command-guide-card ${selectionTone(selection)}">
      <div class="command-guide-head">
        <strong>${selectionLabel(selection)}</strong>
        <span class="command-chip ${selectionTone(selection)}">${selection.mode ?? 'none'}</span>
      </div>
      <p>${selection.reason ?? '근거 컨텍스트 선택 정보가 없습니다.'}</p>
      ${historicalStronger
        ? html`<p>선택된 최신 세션은 과거 proof가 더 강하고 현재 live evidence는 더 약합니다.</p>`
        : null}
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${selection.selected_session_id ?? '없음'}</span>
        <span>작성자</span><span>${selection.selected_created_by ?? '없음'}</span>
        <span>선택된 목표</span><span>${selection.selected_goal ?? '없음'}</span>
        <span>선택 가능한 세션</span><span>${selection.available_session_count ?? 0}</span>
      </div>
    </div>
  `
}

function ToolEvidenceRow({ item }: { item: DashboardProofToolEvidence }) {
  return html`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '도구 근거'}</strong>
          <div class="command-meta-line">
            <span>${item.actor ?? '시스템'}</span>
            <span>${item.event_type ?? 'event'}</span>
          </div>
        </div>
        <span class="command-chip">${relativeTime(item.timestamp ?? null)}</span>
      </div>
      ${toolEvidenceTags(item).length > 0
        ? html`<div class="semantic-tag-row">
            ${toolEvidenceTags(item).map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
    </article>
  `
}

function dedupeTimeline(items: DashboardProofTimelineItem[]): DedupedTimelineItem[] {
  const map = new Map<string, DedupedTimelineItem>()
  for (const item of items) {
    const key = [
      item.timestamp ?? '',
      item.event_type ?? '',
      item.actor ?? '',
      item.summary ?? '',
    ].join('|')
    const source = item.source ?? 'unknown'
    const existing = map.get(key)
    if (existing) {
      if (!existing.sources.includes(source)) existing.sources.push(source)
      if (!existing.operation_id && item.operation_id) existing.operation_id = item.operation_id
      continue
    }
    map.set(key, {
      ...item,
      sources: [source],
    })
  }
  return [...map.values()]
}

function timelineMetaLabel(item: DedupedTimelineItem): string {
  if (item.sources.length === 2) return '세션 + 지휘'
  if (item.sources.length === 1) return item.sources[0] === 'unknown' ? '출처 미상' : item.sources[0] ?? '출처'
  return item.sources.join(' + ')
}

function keyValueRows(data: Record<string, unknown>): Array<{ label: string; value: string }> {
  const rows: Array<{ label: string; value: string }> = []
  for (const [key, raw] of Object.entries(data)) {
    if (raw == null) continue
    if (typeof raw === 'string') {
      if (raw.trim() === '') continue
      rows.push({ label: key, value: raw })
      continue
    }
    if (typeof raw === 'number' || typeof raw === 'boolean') {
      rows.push({ label: key, value: String(raw) })
      continue
    }
  }
  return rows
}

function extractBackingSummary(cpEvidence: unknown): Array<{ label: string; value: string }> {
  const root = asRecord(cpEvidence)
  const traces = asRecord(root.traces)
  const traceEvents = Array.isArray(traces.events) ? traces.events : []
  const detachments = asRecord(root.detachments)
  const detachmentsList = Array.isArray(detachments.detachments) ? detachments.detachments : []
  const firstDetachment = asRecord(detachmentsList[0])
  const detachmentRecord = asRecord(firstDetachment.detachment)
  const operationRecord = asRecord(firstDetachment.operation)
  const summary = asRecord(root.summary)
  const summaryOperations = asRecord(summary.operations)
  const operationsSummary = asRecord(summaryOperations.summary)

  return [
    { label: '작전', value: asString(root.operation_id) ?? '없음' },
    { label: '분견대', value: asString(root.detachment_id) ?? '없음' },
    { label: '트레이스 이벤트', value: `${traceEvents.length}` },
    { label: '분견대 상태', value: asString(detachmentRecord.status) ?? '없음' },
    { label: '작전 단계', value: asString(operationRecord.stage) ?? '없음' },
    { label: '활성 작전', value: `${asNumber(operationsSummary.active) ?? 0}` },
  ]
}

function TimelineRow({ item }: { item: DedupedTimelineItem }) {
  return html`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '이벤트'}</strong>
          <div class="command-meta-line">
            <span>${timelineMetaLabel(item)}</span>
            <span>${item.event_type ?? '이벤트'}</span>
            <span>${item.actor ?? '시스템'}</span>
          </div>
        </div>
        <span class="command-chip">${relativeTime(item.timestamp)}</span>
      </div>
      ${item.sources.length > 1
        ? html`<div class="semantic-tag-row">
            ${item.sources.map(source => html`<span class="semantic-tag">${source}</span>`)}
          </div>`
        : null}
    </article>
  `
}

function ActorContributionRow({ item }: { item: DashboardProofActorContribution }) {
  const output = item.recent_output_preview ?? null
  const input = item.recent_input_preview ?? null
  const eventSummary = item.recent_event_summary ?? null
  const requestPreview = item.recent_request_preview ?? null
  const lastSeen = item.last_active_at ?? item.recent_request_at ?? null
  const isPlanned = item.activity_state === 'planned_only'
  return html`
    <article class="mission-activity-row proof-actor-row" style="${isPlanned ? 'opacity: 0.45;' : ''}">
      <div class="mission-activity-head">
        <div>
          <strong>${item.actor}</strong>
          <div class="mission-activity-meta">
            <span>${item.role ?? '참여자'}</span>
            <span>${lastSeen ? relativeTime(lastSeen) : '기록 없음'}</span>
          </div>
        </div>
        <span class="command-chip ${actorActivityTone(item)}">
          ${actorActivityLabel(item)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${actorActivityMeta(item)}</span>
      </div>
      ${item.activity_detail
        ? html`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${item.activity_detail}</span>
          </div>`
        : null}
      ${eventSummary
        ? html`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${eventSummary}</span>
          </div>`
        : null}
      ${requestPreview && item.activity_state !== 'acted'
        ? html`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${requestPreview}</span>
          </div>`
        : null}
      ${(input || output)
        ? html`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${input ?? '표시 가능한 입력 없음'}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${output ?? '표시 가능한 응답 없음'}</span>
            </div>
          </div>`
        : null}
      ${safeArray(item.recent_tool_names).length > 0
        ? html`<div class="semantic-tag-row">
            ${safeArray(item.recent_tool_names).map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
    </article>
  `
}

function ArtifactRow({ item }: { item: DashboardProofArtifactRef }) {
  return html`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${item.kind}</strong>
          <div class="command-meta-line">
            <span>${compactPath(item.path)}</span>
          </div>
        </div>
        <span class="command-chip ${item.exists ? 'ok' : 'warn'}">${item.exists ? '존재함' : '없음'}</span>
      </div>
    </article>
  `
}

function KeyValueGrid({
  title,
  rows,
}: {
  title?: string
  rows: Array<{ label: string; value: string }>
}) {
  if (rows.length === 0) return null
  return html`
    <div class="proof-kv-block">
      ${title ? html`<strong>${title}</strong>` : null}
      <div class="proof-kv-grid">
        ${rows.map(row => html`
          <span>${row.label}</span>
          <strong>${row.value}</strong>
        `)}
      </div>
    </div>
  `
}

export function Proof() {
  const params = route.value.params
  const sessionId = params.session_id ?? null
  const operationId = params.operation_id ?? null

  useEffect(() => {
    let active = true
    refreshProofSnapshot(sessionId, operationId).catch(() => {
      /* stored in proofError signal */
    })
    return () => { active = false; void active }
  }, [sessionId, operationId])

  const snapshot = proofSnapshot.value

  if (proofLoading.value && !snapshot) {
    return html`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`
  }

  if (proofError.value && !snapshot) {
    return html`<section class="dashboard-panel"><div class="error-card">${proofError.value}</div></section>`
  }

  const summary = snapshot?.summary
  const selection = snapshot?.selection ?? null
  const rawContributions = safeArray<DashboardProofActorContribution>(snapshot?.actor_contributions)
  const activityOrder: Record<string, number> = { acted: 0, mentioned_only: 1, planned_only: 2 }
  const contributions = [...rawContributions].sort(
    (a, b) => (activityOrder[a.activity_state ?? ''] ?? 2) - (activityOrder[b.activity_state ?? ''] ?? 2)
  )
  const artifacts = safeArray<DashboardProofArtifactRef>(snapshot?.artifacts)
  const toolEvidence = safeArray<DashboardProofToolEvidence>(snapshot?.tool_evidence)
  const verdict = snapshot?.proof_verdict ?? 'insufficient'
  const liveVerdict = summary?.live_verdict ?? verdict
  const historicalVerdict = summary?.historical_verdict ?? null
  const verdictBasis = summary?.verdict_basis ?? 'live'
  const cpEvidence = snapshot?.cp_backing_evidence ?? null
  const traceCount = Array.isArray((cpEvidence as { traces?: { events?: unknown[] } } | null)?.traces?.events)
    ? ((cpEvidence as { traces?: { events?: unknown[] } }).traces?.events?.length ?? 0)
    : 0
  const actorCount = summary?.actors_count ?? contributions.length
  const plannedActorCount = summary?.planned_actor_count ?? contributions.length
  const unansweredActorCount =
    summary?.unanswered_actor_count
    ?? contributions.filter(item => item.activity_state !== 'acted' && (item.mention_count ?? 0) > 0).length
  const mentionedActorCount =
    summary?.mentioned_actor_count
    ?? contributions.filter(item => (item.mention_count ?? 0) > 0).length
  const interactionCount = summary?.interaction_count ?? 0
  const evidenceCount = summary?.evidence_count ?? 0
  const dedupedTimeline = dedupeTimeline(safeArray<DashboardProofTimelineItem>(snapshot?.timeline))
  const goalBindingRows = keyValueRows(asRecord(snapshot?.goal_binding))
  const backingSummaryRows = extractBackingSummary(cpEvidence)
  const presentArtifacts = artifacts.filter(item => item.exists).length
  const missingArtifacts = artifacts.length - presentArtifacts
  const reasonLines = verdictReasonLines(
    verdict,
    liveVerdict,
    historicalVerdict,
    actorCount,
    plannedActorCount,
    unansweredActorCount,
    interactionCount,
    evidenceCount,
    traceCount,
  )

  return html`
    <section class="dashboard-panel mission-view">
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${verdictTone(verdict)}">${verdictChipLabel(verdict)}</span>
          ${snapshot?.session_id ? html`<span class="command-chip">${snapshot.session_id}</span>` : null}
          ${snapshot?.generated_at ? html`<span class="command-chip">${relativeTime(snapshot.generated_at)}</span>` : null}
        </div>
      </div>

      ${proofError.value
        ? html`<div class="error-card">${proofError.value}</div>`
        : null}

      <${SelectionCard} selection=${selection} summary=${summary ?? null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${verdictTone(verdict)}">
          <span>판정</span>
          <strong>${verdictLabel(verdict)}</strong>
          <small>${summary?.detail ?? '협업 증거를 verdict로 요약합니다.'}</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${actorCount}</strong>
          <small>이벤트를 남긴 actor 수${plannedActorCount > 0 ? ` (계획 ${plannedActorCount})` : ''}</small>
        </div>
        <div class="summary-stat-card ${evidenceCount > 0 ? 'ok' : 'warn'}">
          <span>근거</span>
          <strong>${evidenceCount}</strong>
          <small>도구 ${(toolEvidence?.length ?? 0)} / 산출물 ${presentArtifacts}/${artifacts.length} / CP ${traceCount}</small>
        </div>
      </div>
      <details style="margin-bottom: 12px;">
        <summary style="cursor: pointer; color: rgba(255,255,255,0.5); font-size: 13px; padding: 6px 0;">상세 지표 (${7}개)</summary>
        <div class="mission-stat-grid" style="margin-top: 8px;">
          <div class="summary-stat-card ${verdictTone(liveVerdict)}">
            <span>Live 판정</span>
            <strong>${liveVerdict}</strong>
            <small>${verdictBasisLabel(verdictBasis)} 기준</small>
          </div>
          <div class="summary-stat-card ${verdictTone(historicalVerdict ?? 'insufficient')}">
            <span>Historical</span>
            <strong>${historicalVerdict ?? 'none'}</strong>
            <small>persisted proof 문서 기준</small>
          </div>
          <div class="summary-stat-card ${unansweredActorCount > 0 ? 'warn' : 'ok'}">
            <span>무응답</span>
            <strong>${unansweredActorCount}</strong>
            <small>${unansweredActorCount > 0 ? '호출됐지만 응답 없음' : '없음'}</small>
          </div>
          <div class="summary-stat-card ${interactionCount > 0 ? 'ok' : 'warn'}">
            <span>직접 상호작용</span>
            <strong>${interactionCount}</strong>
            <small>참여자 간 직접 연결</small>
          </div>
          <div class="summary-stat-card ${traceCount > 0 ? 'ok' : 'warn'}">
            <span>CP 트레이스</span>
            <strong>${traceCount}</strong>
            <small>관리형 backing</small>
          </div>
          <div class="summary-stat-card ${(missingArtifacts === 0 && artifacts.length > 0) ? 'ok' : 'warn'}">
            <span>산출물</span>
            <strong>${presentArtifacts}/${artifacts.length}</strong>
            <small>${missingArtifacts > 0 ? `${missingArtifacts}개 누락` : '전부 존재함'}</small>
          </div>
          <div class="summary-stat-card ${plannedActorCount > actorCount ? 'warn' : 'ok'}">
            <span>계획된 참여자</span>
            <strong>${plannedActorCount}</strong>
            <small>${mentionedActorCount > 0 ? `${mentionedActorCount}명 호출됨` : '호출 기록 없음'}</small>
          </div>
        </div>
      </details>

      <div class="mission-human-grid">
        <${Card} title="3줄 근거 요약" class="mission-list-card">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${reasonLines.map((line, idx) => html`
              <article class="proof-summary-block ${idx === 1 && verdict !== 'proven' ? verdictTone(verdict) : ''}">
                <strong>${idx === 0 ? '지금 결론' : idx === 1 ? '왜 이렇게 판정됐나' : '다음 보강 포인트'}</strong>
                <span>${line}</span>
              </article>
            `)}
          </div>
        <//>

        <${Card} title="증명 대상" class="mission-list-card">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${KeyValueGrid} rows=${goalBindingRows} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${prettyJson(snapshot?.goal_binding ?? {})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="협업 타임라인" class="mission-list-card">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${dedupedTimeline.length > 0
              ? dedupedTimeline.slice(0, 18).map(item => html`<${TimelineRow} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">타임라인 근거가 없습니다. 에이전트 협업이 진행되면 세션과 지휘 이벤트가 여기에 나타납니다.</div>`}
          </div>
        <//>

        <${Card} title="참여 흔적" class="mission-list-card">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${contributions.length > 0
              ? contributions.map(item => html`<${ActorContributionRow} key=${item.actor} item=${item} />`)
              : html`<div class="empty-state">참여 흔적이 없습니다. 에이전트가 작업에 참여하면 턴, 도구 호출, 산출물이 기록됩니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="도구 근거" class="mission-list-card">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${toolEvidence.length > 0
              ? toolEvidence.map((item, idx) => html`<${ToolEvidenceRow} key=${`${item.actor ?? 'system'}-${idx}`} item=${item} />`)
              : html`<div class="empty-state">도구 근거가 없습니다. 에이전트가 MCP 도구를 사용하면 호출 내역이 여기에 기록됩니다.</div>`}
          </div>
        <//>

        <${Card} title="실행 근거" class="mission-list-card">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${KeyValueGrid} rows=${backingSummaryRows} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${prettyJson(cpEvidence ?? {})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="산출물" class="mission-list-card">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${artifacts.length > 0
              ? artifacts.map(item => html`<${ArtifactRow} key=${item.path} item=${item} />`)
              : html`<div class="empty-state">산출물이 없습니다. proof/report/session 파일이 생성되면 존재 여부가 표시됩니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `
}
