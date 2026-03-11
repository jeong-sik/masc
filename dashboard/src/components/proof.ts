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

function verdictTone(verdict?: DashboardProofVerdict | null): string {
  if (verdict === 'proven') return 'ok'
  if (verdict === 'partial') return 'warn'
  return 'bad'
}

function safeArray<T>(value: T[] | null | undefined): T[] {
  return Array.isArray(value) ? value : []
}

function TimelineRow({ item }: { item: DashboardProofTimelineItem }) {
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? 'event'}</strong>
          <div class="command-meta-line">
            <span>${item.source ?? 'source'}</span>
            <span>${item.event_type ?? 'event'}</span>
            <span>${item.actor ?? 'system'}</span>
          </div>
        </div>
        <span class="command-chip">${relativeTime(item.timestamp)}</span>
      </div>
    </article>
  `
}

function ActorContributionRow({ item }: { item: DashboardProofActorContribution }) {
  return html`
    <article class="mission-activity-row">
      <div class="mission-activity-head">
        <div>
          <strong>${item.actor}</strong>
          <div class="mission-activity-meta">
            <span>${item.role ?? 'participant'}</span>
            <span>${item.last_active_at ? relativeTime(item.last_active_at) : 'n/a'}</span>
          </div>
        </div>
        <span class="command-chip ${item.interaction_count && item.interaction_count > 0 ? 'warn' : 'ok'}">
          ${item.interaction_count ?? 0} interactions
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>turns ${item.turn_count ?? 0}</span>
        <span>spawn ${item.spawn_count ?? 0}</span>
        <span>tool evidence ${item.tool_evidence_count ?? 0}</span>
      </div>
      ${item.recent_input_preview
        ? html`<div class="mission-activity-preview"><strong>Input</strong><span>${item.recent_input_preview}</span></div>`
        : null}
      ${item.recent_output_preview
        ? html`<div class="mission-activity-preview"><strong>Output</strong><span>${item.recent_output_preview}</span></div>`
        : null}
      ${safeArray(item.recent_tool_names).length > 0
        ? html`<div class="semantic-tag-row">
            ${safeArray(item.recent_tool_names).map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
      ${item.recent_event_summary
        ? html`<div class="mission-activity-copy"><span>${item.recent_event_summary}</span></div>`
        : null}
    </article>
  `
}

function ArtifactRow({ item }: { item: DashboardProofArtifactRef }) {
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${item.kind}</strong>
          <div class="command-meta-line">
            <span>${item.path}</span>
          </div>
        </div>
        <span class="command-chip ${item.exists ? 'ok' : 'warn'}">${item.exists ? 'present' : 'missing'}</span>
      </div>
    </article>
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
  const timeline = safeArray(snapshot?.timeline)
  const contributions = safeArray(snapshot?.actor_contributions)
  const artifacts = safeArray(snapshot?.artifacts)
  const verdict = snapshot?.proof_verdict ?? 'insufficient'
  const cpEvidence = snapshot?.cp_backing_evidence ?? null
  const traceCount = Array.isArray((cpEvidence as { traces?: { events?: unknown[] } } | null)?.traces?.events)
    ? ((cpEvidence as { traces?: { events?: unknown[] } }).traces?.events?.length ?? 0)
    : 0

  return html`
    <section class="dashboard-panel mission-view">
      <${SurfaceSemanticIntro} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>협업, 대화, 도구 사용, backing evidence를 한 화면에서 증명하는 표면입니다.</p>
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
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${summary?.actors_count ?? contributions.length}</strong>
          <small>proof lane participants</small>
        </div>
        <div class="summary-stat-card">
          <span>Interactions</span>
          <strong>${summary?.interaction_count ?? 0}</strong>
          <small>cross-actor evidence</small>
        </div>
        <div class="summary-stat-card">
          <span>Evidence</span>
          <strong>${summary?.evidence_count ?? 0}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card">
          <span>CP Traces</span>
          <strong>${summary?.cp_trace_count ?? traceCount}</strong>
          <small>managed backing events</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${Card} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
          </div>
          <div class="mission-list-stack">
            <div class="command-card">
              <div class="command-card-head">
                <div>
                  <strong>${summary?.headline ?? 'No collaboration proof selected.'}</strong>
                  <div class="command-meta-line">
                    <span>${summary?.detail ?? 'Provide session_id or open the latest team session.'}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <//>

        <${Card} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>목표 연결</h3>
          </div>
          <pre class="command-json-block">${prettyJson(snapshot?.goal_binding ?? {})}</pre>
        <//>
      </div>

      <div class="mission-human-grid">
        <${Card} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>session events와 command-plane traces를 한 흐름으로 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${timeline.length > 0
              ? timeline.slice(0, 24).map(item => html`<${TimelineRow} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${Card} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>actor 기여</h3>
            <p>누가 무엇을 했고 어떤 input/output을 남겼는지 봅니다.</p>
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
            <h3>CPv2 backing evidence</h3>
          </div>
          <pre class="command-json-block">${prettyJson(cpEvidence ?? {})}</pre>
        <//>

        <${Card} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>생성 산출물</h3>
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
