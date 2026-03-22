import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { route } from '../router'
import { proofError, proofLoading, proofSnapshot, refreshProofSnapshot } from '../proof-store'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofTimelineItem,
  DashboardProofToolEvidence,
} from '../types'
import { prettyJson, relativeTime } from './command/helpers'
import {
  asRecord,
  dedupeTimeline,
  extractBackingSummary,
  keyValueRows,
  safeArray,
  verdictBasisLabel,
  verdictChipLabel,
  verdictLabel,
  verdictReasonLines,
  verdictTone,
} from './proof-helpers'
import {
  ActorContributionRow,
  ArtifactRow,
  KeyValueGrid,
  SelectionCard,
  TimelineRow,
  ToolEvidenceRow,
} from './proof-sections'

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
    <section class="dashboard-panel flex flex-col gap-4">
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="flex gap-2 flex-wrap items-center">
          <span class="command-chip ${verdictTone(verdict)}">${verdictChipLabel(verdict)}</span>
          ${snapshot?.session_id ? html`<span class="command-chip">${snapshot.session_id}</span>` : null}
          ${snapshot?.generated_at ? html`<span class="command-chip">${relativeTime(snapshot.generated_at)}</span>` : null}
        </div>
      </div>

      ${proofError.value
        ? html`<div class="error-card">${proofError.value}</div>`
        : null}

      <${SelectionCard} selection=${selection} summary=${summary ?? null} />

      <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
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
      <details class="mb-3">
        <summary style="cursor: pointer; color: rgba(255,255,255,0.5); font-size: 13px; padding: 6px 0;">상세 지표 (${7}개)</summary>
        <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3" class="mt-2">
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

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="3줄 근거 요약" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="grid gap-2.5">
            ${reasonLines.map((line, idx) => html`
              <article class="proof-summary-block ${idx === 1 && verdict !== 'proven' ? verdictTone(verdict) : ''}">
                <strong>${idx === 0 ? '지금 결론' : idx === 1 ? '왜 이렇게 판정됐나' : '다음 보강 포인트'}</strong>
                <span>${line}</span>
              </article>
            `)}
          </div>
        <//>

        <${Card} title="증명 대상" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${KeyValueGrid} rows=${goalBindingRows} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${prettyJson(snapshot?.goal_binding ?? {})}</pre>
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="협업 타임라인" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${dedupedTimeline.length > 0
              ? dedupedTimeline.slice(0, 18).map(item => html`<${TimelineRow} key=${item.id} item=${item} />`)
              : html`<div class="empty-state">타임라인 근거가 없습니다. 에이전트 협업이 진행되면 세션과 지휘 이벤트가 여기에 나타납니다.</div>`}
          </div>
        <//>

        <${Card} title="참여 흔적" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${contributions.length > 0
              ? contributions.map(item => html`<${ActorContributionRow} key=${item.actor} item=${item} />`)
              : html`<div class="empty-state">참여 흔적이 없습니다. 에이전트가 작업에 참여하면 턴, 도구 호출, 산출물이 기록됩니다.</div>`}
          </div>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="도구 근거" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${toolEvidence.length > 0
              ? toolEvidence.map((item, idx) => html`<${ToolEvidenceRow} key=${`${item.actor ?? 'system'}-${idx}`} item=${item} />`)
              : html`<div class="empty-state">도구 근거가 없습니다. 에이전트가 MCP 도구를 사용하면 호출 내역이 여기에 기록됩니다.</div>`}
          </div>
        <//>

        <${Card} title="실행 근거" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${KeyValueGrid} rows=${backingSummaryRows} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${prettyJson(cpEvidence ?? {})}</pre>
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="산출물" class="mission-list-card">
          <div class="grid gap-1 mb-3">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${artifacts.length > 0
              ? artifacts.map(item => html`<${ArtifactRow} key=${item.path} item=${item} />`)
              : html`<div class="empty-state">산출물이 없습니다. proof/report/session 파일이 생성되면 존재 여부가 표시됩니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `
}
