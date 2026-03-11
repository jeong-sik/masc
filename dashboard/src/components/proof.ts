import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { route } from '../router'
import { proofError, proofLoading, proofSnapshot, refreshProofSnapshot } from '../proof-store'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofTimelineItem,
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

function verdictLabel(verdict: DashboardProofVerdict): string {
  if (verdict === 'proven') return '협업 증거가 충분합니다'
  if (verdict === 'partial') return '흔적은 있으나 협업 증거가 덜 모였습니다'
  return '증거가 부족합니다'
}

function verdictReasonLines(
  verdict: DashboardProofVerdict,
  actorCount: number,
  interactionCount: number,
  evidenceCount: number,
  cpTraceCount: number,
): string[] {
  const lines = [
    `${actorCount}명의 actor 흔적이 기록돼 있습니다.`,
    interactionCount > 0
      ? `서로를 참조한 상호작용 증거가 ${interactionCount}건 있습니다.`
      : '서로를 참조한 명시적 상호작용 증거가 아직 없습니다.',
    evidenceCount > 0
      ? `도구·산출물·체크포인트 증거가 ${evidenceCount}건 있습니다.`
      : '도구·산출물·체크포인트 증거가 거의 없습니다.',
    cpTraceCount > 0
      ? `CPv2 backing trace가 ${cpTraceCount}건 있어 실행 흔적은 남아 있습니다.`
      : 'managed backing trace는 아직 없습니다.',
  ]
  if (verdict === 'partial') {
    return [
      lines[0] ?? '',
      interactionCount === 0
        ? 'partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.'
        : 'partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.',
      cpTraceCount > 0
        ? '다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.'
        : '다음 보강 포인트: managed trace 또는 산출물 linkage를 더 남기면 proof가 강해집니다.',
    ]
  }
  if (verdict === 'proven') {
    return [
      lines[0] ?? '',
      '결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.',
      '다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다.',
    ]
  }
  return [
    lines[0] ?? '',
    '결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.',
    '다음 보강 포인트: participant 간 turn, tool evidence, deliverable linkage를 더 남겨야 합니다.',
  ]
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
  if (item.sources.length === 2) return 'team + command'
  if (item.sources.length === 1) return item.sources[0] ?? 'source'
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
    { label: 'operation', value: asString(root.operation_id) ?? '없음' },
    { label: 'detachment', value: asString(root.detachment_id) ?? '없음' },
    { label: 'trace events', value: `${traceEvents.length}` },
    { label: 'detachment status', value: asString(detachmentRecord.status) ?? '없음' },
    { label: 'operation stage', value: asString(operationRecord.stage) ?? '없음' },
    { label: 'active ops', value: `${asNumber(operationsSummary.active) ?? 0}` },
  ]
}

function TimelineRow({ item }: { item: DedupedTimelineItem }) {
  return html`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? 'event'}</strong>
          <div class="command-meta-line">
            <span>${timelineMetaLabel(item)}</span>
            <span>${item.event_type ?? 'event'}</span>
            <span>${item.actor ?? 'system'}</span>
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
  const interactionTone = (item.interaction_count ?? 0) > 0 ? 'ok' : 'warn'
  return html`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${item.actor}</strong>
          <div class="mission-activity-meta">
            <span>${item.role ?? 'participant'}</span>
            <span>${item.last_active_at ? relativeTime(item.last_active_at) : 'n/a'}</span>
          </div>
        </div>
        <span class="command-chip ${interactionTone}">
          ${(item.interaction_count ?? 0) > 0 ? `${item.interaction_count} interaction` : 'interaction 없음'}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>turn ${item.turn_count ?? 0}</span>
        <span>spawn ${item.spawn_count ?? 0}</span>
        <span>tool evidence ${item.tool_evidence_count ?? 0}</span>
      </div>
      ${eventSummary
        ? html`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${eventSummary}</span>
          </div>`
        : null}
      ${(input || output)
        ? html`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 input</strong>
              <span>${input ?? '표시 가능한 input 없음'}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 output</strong>
              <span>${output ?? '표시 가능한 output 없음'}</span>
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
        <span class="command-chip ${item.exists ? 'ok' : 'warn'}">${item.exists ? 'present' : 'missing'}</span>
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
    void refreshProofSnapshot(sessionId, operationId)
  }, [sessionId, operationId])

  const snapshot = proofSnapshot.value

  if (proofLoading.value && !snapshot) {
    return html`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`
  }

  if (proofError.value && !snapshot) {
    return html`<section class="dashboard-panel"><div class="error-card">${proofError.value}</div></section>`
  }

  const summary = snapshot?.summary
  const contributions = safeArray(snapshot?.actor_contributions)
  const artifacts = safeArray(snapshot?.artifacts)
  const verdict = snapshot?.proof_verdict ?? 'insufficient'
  const cpEvidence = snapshot?.cp_backing_evidence ?? null
  const traceCount = Array.isArray((cpEvidence as { traces?: { events?: unknown[] } } | null)?.traces?.events)
    ? ((cpEvidence as { traces?: { events?: unknown[] } }).traces?.events?.length ?? 0)
    : 0
  const actorCount = summary?.actors_count ?? contributions.length
  const interactionCount = summary?.interaction_count ?? 0
  const evidenceCount = summary?.evidence_count ?? 0
  const dedupedTimeline = dedupeTimeline(safeArray(snapshot?.timeline))
  const goalBindingRows = keyValueRows(asRecord(snapshot?.goal_binding))
  const backingSummaryRows = extractBackingSummary(cpEvidence)
  const presentArtifacts = artifacts.filter(item => item.exists).length
  const missingArtifacts = artifacts.length - presentArtifacts
  const reasonLines = verdictReasonLines(verdict, actorCount, interactionCount, evidenceCount, traceCount)

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>이 세션이 실제로 여러 actor의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${verdictTone(verdict)}">${verdict}</span>
          ${snapshot?.session_id ? html`<span class="command-chip">${snapshot.session_id}</span>` : null}
          ${snapshot?.generated_at ? html`<span class="command-chip">${relativeTime(snapshot.generated_at)}</span>` : null}
        </div>
      </div>

      ${proofError.value
        ? html`<div class="error-card">${proofError.value}</div>`
        : null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${verdictTone(verdict)}">
          <span>Verdict</span>
          <strong>${verdictLabel(verdict)}</strong>
          <small>${summary?.detail ?? '협업 증거를 verdict로 요약합니다.'}</small>
        </div>
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${actorCount}</strong>
          <small>기록된 참여 actor 수</small>
        </div>
        <div class="summary-stat-card ${interactionCount > 0 ? 'ok' : 'warn'}">
          <span>Interactions</span>
          <strong>${interactionCount}</strong>
          <small>actor 간 직접 상호작용 증거</small>
        </div>
        <div class="summary-stat-card ${evidenceCount > 0 ? 'ok' : 'warn'}">
          <span>Evidence</span>
          <strong>${evidenceCount}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card ${traceCount > 0 ? 'ok' : 'warn'}">
          <span>CP Traces</span>
          <strong>${traceCount}</strong>
          <small>managed backing events</small>
        </div>
        <div class="summary-stat-card ${(missingArtifacts === 0 && artifacts.length > 0) ? 'ok' : 'warn'}">
          <span>Artifacts</span>
          <strong>${presentArtifacts}/${artifacts.length}</strong>
          <small>${missingArtifacts > 0 ? `${missingArtifacts} missing` : 'all present'}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${Card} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
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

        <${Card} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 proof가 어느 세션, 목표, operation에 묶였는지 읽습니다.</p>
          </div>
          <${KeyValueGrid} rows=${goalBindingRows} />
          <details class="mission-card-disclosure compact">
            <summary>raw goal binding JSON</summary>
            <pre class="command-json-block">${prettyJson(snapshot?.goal_binding ?? {})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${dedupedTimeline.length > 0
              ? dedupedTimeline.slice(0, 18).map(item => html`<${TimelineRow} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>turn 수보다 최근 흔적, 입출력, 도구, interaction 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${contributions.length > 0
              ? contributions.map(item => html`<${ActorContributionRow} key=${item.actor} item=${item} />`)
              : html`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>operation, detachment, trace 수만 먼저 보고, raw CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${KeyValueGrid} rows=${backingSummaryRows} />
          <details class="mission-card-disclosure compact">
            <summary>raw CPv2 backing JSON</summary>
            <pre class="command-json-block">${prettyJson(cpEvidence ?? {})}</pre>
          </details>
        <//>

        <${Card} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${artifacts.length > 0
              ? artifacts.map(item => html`<${ArtifactRow} key=${item.path} item=${item} />`)
              : html`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `
}
