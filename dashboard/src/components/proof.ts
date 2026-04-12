import { html } from 'htm/preact'
import { JsonViewerCard } from './common/json-viewer'
import { useEffect } from 'preact/hooks'
import { Card, CARD_STANDARD } from './common/card'
import { EmptyState, ErrorState, LoadingState } from './common/feedback-state'
import { route } from '../router'
import { proofError, proofLoading, proofSnapshot, refreshProofSnapshot } from '../proof-store'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofTimelineItem,
  DashboardProofToolEvidence,
  DashboardProofWorkerRunEvidence,
} from '../types'
import { relativeTime } from './command/helpers'
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
  WorkerRunEvidenceRow,
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
    return html`<section class="flex flex-col gap-[18px]"><${LoadingState}>근거 화면 불러오는 중…<//></section>`
  }

  if (proofError.value && !snapshot) {
    return html`<section class="flex flex-col gap-[18px]"><div class="error-card rounded-xl">${proofError.value}</div></section>`
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
  const workerRunEvidence = safeArray<DashboardProofWorkerRunEvidence>(snapshot?.worker_run_evidence)
  const verdict = snapshot?.proof_verdict ?? 'insufficient'
  const liveVerdict = summary?.live_verdict ?? verdict
  const historicalVerdict = summary?.historical_verdict ?? null
  const verdictBasis = summary?.verdict_basis ?? 'live'
  const rawTraceRunCount =
    summary?.raw_trace_run_count
    ?? workerRunEvidence.filter(item => item.trace_capability === 'raw').length
  const validatedWorkerRunCount =
    summary?.validated_worker_run_count
    ?? workerRunEvidence.filter(item => item.trace_validated === true).length
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
    <section class="flex flex-col gap-6">
      <div class="flex items-center justify-end gap-2 flex-wrap px-1">
        <span class="px-3 py-1.5 rounded-full text-[11px] font-bold border shadow-sm ${verdictTone(verdict)}">${verdictChipLabel(verdict)}</span>
        ${snapshot?.session_id ? html`<span class="px-2.5 py-1 rounded-md bg-white/5 border border-white/10 text-text-muted text-[11px] font-mono shadow-sm">${snapshot.session_id}</span>` : null}
        ${snapshot?.operation_id ? html`<span class="px-2.5 py-1 rounded-md bg-white/5 border border-white/10 text-text-muted text-[11px] font-mono shadow-sm">${snapshot.operation_id}</span>` : null}
        ${snapshot?.generated_at ? html`<span class="px-2.5 py-1 rounded-md bg-white/5 border border-white/10 text-text-muted text-[11px] font-mono shadow-sm">${relativeTime(snapshot.generated_at)}</span>` : null}
      </div>

      ${proofError.value
        ? html`<${ErrorState} message=${proofError.value} />`
        : null}

      <${SelectionCard} selection=${selection} summary=${summary ?? null} />

      <!-- Primary stat cards -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-4">
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm ${verdictTone(verdict).replace('border', 'ring-1 ring')}">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">판정</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${verdictLabel(verdict)}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">${summary?.detail ?? '협업 증거를 verdict로 요약합니다.'}</small>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">실제 흔적</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${actorCount}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">이벤트를 남긴 actor 수${plannedActorCount > 0 ? ` (계획 ${plannedActorCount})` : ''}</small>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] ${evidenceCount > 0 ? 'text-ok' : 'text-warn'} tracking-widest uppercase font-semibold">근거</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${evidenceCount}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">도구 ${(toolEvidence?.length ?? 0)} / 산출물 ${presentArtifacts}/${artifacts.length} / CP ${traceCount}</small>
        </div>
      </div>

      <!-- Expanded detail metrics -->
      <details class="mb-1">
        <summary class="cursor-pointer text-[13px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">상세 지표 (${8}개)</summary>
        <div class="grid grid-cols-[repeat(auto-fit,minmax(155px,1fr))] gap-3 mt-3">
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${verdictTone(liveVerdict)}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">Live 판정</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${liveVerdict}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${verdictBasisLabel(verdictBasis)} 기준</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${verdictTone(historicalVerdict ?? 'insufficient')}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">Historical</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${historicalVerdict ?? 'none'}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">persisted proof 문서 기준</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${unansweredActorCount > 0 ? 'warn' : 'ok'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">무응답</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${unansweredActorCount}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${unansweredActorCount > 0 ? '호출됐지만 응답 없음' : '없음'}</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${interactionCount > 0 ? 'ok' : 'warn'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">직접 상호작용</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${interactionCount}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">참여자 간 직접 연결</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${traceCount > 0 ? 'ok' : 'warn'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">CP 트레이스</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${traceCount}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">관리형 backing</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${validatedWorkerRunCount > 0 ? 'ok' : 'warn'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">OAS 워커 근거</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${validatedWorkerRunCount}/${Math.max(rawTraceRunCount, workerRunEvidence.length)}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">검증됨 / 수집됨</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${(missingArtifacts === 0 && artifacts.length > 0) ? 'ok' : 'warn'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">산출물</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${presentArtifacts}/${artifacts.length}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${missingArtifacts > 0 ? `${missingArtifacts}개 누락` : '전부 존재함'}</small>
          </div>
          <div class="flex flex-col gap-1.5 ${CARD_STANDARD} ${plannedActorCount > actorCount ? 'warn' : 'ok'}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">계획된 참여자</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${plannedActorCount}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${mentionedActorCount > 0 ? `${mentionedActorCount}명 호출됨` : '호출 기록 없음'}</small>
          </div>
        </div>
      </details>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="3줄 근거 요약">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">핵심 증명</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="grid gap-3">
            ${reasonLines.map((line, idx) => html`
              <article class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] ${idx === 1 && verdict !== 'proven' ? verdictTone(verdict) : ''}">
                <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${idx === 0 ? '지금 결론' : idx === 1 ? '왜 이렇게 판정됐나' : '다음 보강 포인트'}</strong>
                <span class="text-[12px] text-[var(--text-body)] leading-relaxed">${line}</span>
              </article>
            `)}
          </div>
        <//>

        <${Card} title="증명 대상">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">무엇을 증명하려는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${KeyValueGrid} rows=${goalBindingRows} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">원본 목표 연결 JSON</summary>
            <${JsonViewerCard} data=${snapshot?.goal_binding ?? {}} title="Goal Binding" />
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="협업 타임라인">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">협업 타임라인</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">세션 런타임과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${dedupedTimeline.length > 0
              ? dedupedTimeline.slice(0, 18).map(item => html`<${TimelineRow} key=${item.id} item=${item} />`)
              : html`<${EmptyState} message="타임라인 근거가 없습니다. 에이전트 협업이 진행되면 세션과 관제 이벤트가 여기에 나타납니다." compact />`}
          </div>
        <//>

        <${Card} title="참여 흔적">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">누가 무엇을 남겼는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${contributions.length > 0
              ? contributions.map(item => html`<${ActorContributionRow} key=${item.actor} item=${item} />`)
              : html`<${EmptyState} message="참여 흔적이 없습니다. 에이전트가 작업에 참여하면 턴, 도구 호출, 산출물이 기록됩니다." compact />`}
          </div>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="도구 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">어떤 도구를 언제 썼는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${toolEvidence.length > 0
              ? toolEvidence.map((item, idx) => html`<${ToolEvidenceRow} key=${`${item.actor ?? 'system'}-${idx}`} item=${item} />`)
              : html`<${EmptyState} message="도구 근거가 없습니다. 에이전트가 MCP 도구를 사용하면 호출 내역이 여기에 기록됩니다." compact />`}
          </div>
        <//>

        <${Card} title="OAS 워커 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">worker run trace는 얼마나 남아 있나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">OAS worker가 남긴 raw trace, 검증 결과, 최종 출력 요약을 바로 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${workerRunEvidence.length > 0
              ? workerRunEvidence.map(item => html`<${WorkerRunEvidenceRow} key=${item.worker_run_id} item=${item} />`)
              : html`<${EmptyState} message="표시할 OAS worker evidence가 없습니다. raw trace 또는 summary-only evidence가 생기면 여기에 나타납니다." compact />`}
          </div>
        <//>
      </div>

      <div class="grid gap-4">
        <${Card} title="실행 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">실행 backing은 얼마나 남아 있나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${KeyValueGrid} rows=${backingSummaryRows} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">원본 CPv2 backing JSON</summary>
            <${JsonViewerCard} data=${cpEvidence ?? {}} title="Evidence" />
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${Card} title="산출물">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">어떤 파일 산출물이 남았나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${artifacts.length > 0
              ? artifacts.map(item => html`<${ArtifactRow} key=${item.path} item=${item} />`)
              : html`<${EmptyState} message="산출물이 없습니다. proof/report/session 파일이 생성되면 존재 여부가 표시됩니다." compact />`}
          </div>
        <//>
      </div>
    </section>
  `
}
