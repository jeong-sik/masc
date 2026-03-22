import { html } from 'htm/preact'
import {
  commandPlaneChainSummary,
  commandPlaneSurface,
} from '../../command-store'
import { route } from '../../router'
import {
  workflowActionLabel,
  workflowCommandSurfaceLabel,
  workflowContextForRoute,
  workflowTargetLabel,
} from '../../workflow-context'
import {
  clampPercent,
  COMMAND_SURFACE_GUIDE,
  currentCommandPlaneSummary,
  currentSurfaceRecommendation,
  formatPercent,
  gaugeStyle,
  ratioPercent,
  relativeTime,
  summaryHighlightKey,
  toneClass,
} from './helpers'

export function CommandWorkflowBanner() {
  const context = workflowContextForRoute(route.value)
  if (!context) return null
  return html`
    <section class="rounded-[14px] border border-[rgba(34,211,238,0.26)] bg-[linear-gradient(180deg,rgba(34,211,238,0.1),var(--white-3))] py-3.5 px-4 grid gap-2">
      <div class="flex gap-2 flex-wrap items-center">
        <strong>${context.source_label}</strong>
        <span class="rounded-full">${workflowActionLabel(context.action_type)}</span>
        <span class="rounded-full">${workflowTargetLabel(context)}</span>
        <span class="rounded-full">${workflowCommandSurfaceLabel(route.value.params.surface ?? 'warroom')}</span>
      </div>
      <div class="text-[var(--text-strong)] leading-normal">${context.summary}</div>
      ${context.payload_preview
        ? html`<div class="py-2.5 px-3 border border-[var(--white-8)] bg-[var(--white-5)] text-[var(--text-strong)] leading-[1.45] rounded-xl">${context.payload_preview}</div>`
        : null}
    </section>
  `
}

export function CommandEntryStrip() {
  const surface = commandPlaneSurface.value
  const guide = COMMAND_SURFACE_GUIDE[surface]
  const recommendation = currentSurfaceRecommendation(surface)

  return html`
    <section class="grid grid-cols-2 gap-3">
      <article class="py-3.5 px-4 rounded-[14px] border border-[var(--border-slate-16)] bg-[var(--white-3h)] grid gap-1.5">
        <span class="text-[rgba(148,163,184,0.92)] text-[11px] uppercase tracking-[0.08em]">현재 표면</span>
        <strong class="text-[var(--text-near-white)] text-lg leading-[1.2] break-words">${guide.title}</strong>
        <p class="m-0 text-[var(--frost-72)] leading-normal">${guide.description}</p>
      </article>
      <article class="py-3.5 px-4 rounded-[14px] border border-[var(--border-slate-16)] bg-[var(--white-3h)] grid gap-1.5">
        <span class="text-[rgba(148,163,184,0.92)] text-[11px] uppercase tracking-[0.08em]">다음 추천</span>
        <strong class="text-[var(--text-near-white)] text-lg leading-[1.2] break-words">${recommendation.tool}</strong>
        <p class="m-0 text-[var(--frost-72)] leading-normal">${recommendation.reason}</p>
      </article>
    </section>
  `
}

function GraphicGauge({
  label,
  value,
  subtext,
  percent,
  color,
}: {
  label: string
  value: string
  subtext: string
  percent: number
  color: string
}) {
  return html`
    <article class="grid grid-cols-[88px_minmax(0,1fr)] gap-3 items-center p-3 rounded-2xl bg-[rgba(255,255,255,0.045)] border border-solid border-[var(--white-8)] min-w-0">
      <div class="cmd-gauge-ring" style=${gaugeStyle(percent, color)}>
        <div class="w-full h-full rounded-full bg-[rgba(8,14,28,0.92)] border border-solid border-[var(--white-6)] grid place-items-center content-center text-center">
          <strong>${value}</strong>
          <span>${Math.round(clampPercent(percent))}%</span>
        </div>
      </div>
      <div class="grid gap-1 min-w-0">
        <span>${label}</span>
        <small>${subtext}</small>
      </div>
    </article>
  `
}

function SignalRail({
  label,
  value,
  detail,
  percent,
  tone,
}: {
  label: string
  value: string
  detail: string
  percent: number
  tone: string
}) {
  return html`
    <article class="p-3.5 rounded-[14px] bg-[var(--white-3h)] border border-[var(--white-8)] grid gap-2.5 cmd-signal-rail ${toneClass(tone)}">
      <div class="flex items-baseline justify-between gap-2.5">
        <span>${label}</span>
        <strong>${value}</strong>
      </div>
      <div class="relative h-2 overflow-hidden bg-[var(--white-6)] rounded-full cmd-signal-bar">
        <span class="${toneClass(tone)}" style=${`width: ${Math.max(8, Math.round(clampPercent(percent)))}%`}></span>
      </div>
      <small>${detail}</small>
    </article>
  `
}

export function SummaryHero() {
  const summary = currentCommandPlaneSummary()
  const topology = summary?.topology.summary
  const ops = summary?.operations.summary
  const detachments = summary?.detachments.summary
  const decisions = summary?.decisions.summary
  const alerts = summary?.alerts.summary
  const swarmOverview = summary?.swarm_status?.overview
  const proof = summary?.swarm_proof
  const microarch = summary?.operations.microarch
  const managedUnits = topology?.managed_unit_count ?? 0
  const totalUnits = topology?.total_units ?? 0
  const activeOps = ops?.active ?? 0
  const activeDetachments = detachments?.active ?? 0
  const movingLanes = swarmOverview?.moving_lanes ?? 0
  const activeLanes = swarmOverview?.active_lanes ?? 0
  const proofDone = proof?.workers.done ?? 0
  const proofExpected = proof?.workers.expected ?? 0
  const badAlerts = alerts?.bad ?? 0
  const warnAlerts = alerts?.warn ?? 0
  const pendingApprovals = decisions?.pending ?? 0
  const totalApprovals = decisions?.total ?? 0
  const readyFootprint = activeOps + activeDetachments
  const cacheHit = microarch?.cache?.l1_hit_rate ?? microarch?.signals?.cache_contention?.l1_hit_rate ?? 0
  const headline =
    activeOps > 0 || activeDetachments > 0
      ? '지휘면이 실제로 움직이고 있습니다'
      : '계층은 준비됐지만 실행은 아직 잠복 상태입니다'
  const subcopy =
    activeOps > 0 || movingLanes > 0
      ? '무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.'
      : '이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.'

  return html`
    <section class="relative overflow-hidden border border-[rgba(103,232,249,0.16)] rounded-[18px] p-[18px] mb-4 shadow-[inset_0_1px_0_var(--white-4)] cmd-hero grid grid-cols-[minmax(0,1.1fr)_minmax(300px,0.9fr)] gap-[18px] items-center">
      <div class="relative z-[1] grid gap-2.5">
        <span class="inline-flex w-fit items-center gap-2 py-[5px] px-[10px] rounded-full text-[#7dd3fc] bg-[rgba(14,116,144,0.22)] border border-solid border-[rgba(125,211,252,0.18)] text-[11px] tracking-[0.08em] uppercase">현재 지휘 상태</span>
        <h3>${headline}</h3>
        <p>${subcopy}</p>
        <div class="flex flex-wrap gap-2">
        <span class="rounded-full ${toneClass(activeOps > 0 ? 'ok' : 'warn')}">활성 작전 ${activeOps}</span>
          <span class="rounded-full ${toneClass(movingLanes > 0 ? 'ok' : activeLanes > 0 ? 'warn' : 'warn')}">이동 레인 ${movingLanes}/${Math.max(activeLanes, movingLanes)}</span>
          <span class="rounded-full ${toneClass(badAlerts > 0 ? 'bad' : warnAlerts > 0 ? 'warn' : 'ok')}">치명 알림 ${badAlerts}</span>
          <span class="rounded-full ${toneClass(pendingApprovals > 0 ? 'warn' : 'ok')}">승인 대기 ${pendingApprovals}</span>
        </div>
      </div>

      <div class="relative z-[1] grid grid-cols-2 gap-3">
        <${GraphicGauge}
          label="관리 단위 범위"
          value=${`${managedUnits}/${Math.max(totalUnits, managedUnits)}`}
          subtext=${totalUnits > 0 ? `${totalUnits - managedUnits}개 단위는 아직 명시 정책 바깥에 있습니다` : '토폴로지 요약이 아직 없습니다'}
          percent=${ratioPercent(managedUnits, Math.max(totalUnits, managedUnits))}
          color="#67e8f9"
        />
        <${GraphicGauge}
          label="실행 열도"
          value=${String(readyFootprint)}
          subtext=${`${activeOps}개 작전 + ${activeDetachments}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ratioPercent(readyFootprint, Math.max(managedUnits, readyFootprint || 1))}
          color="#4ade80"
        />
        <${GraphicGauge}
          label="스웜 이동감"
          value=${`${movingLanes}/${Math.max(activeLanes, movingLanes)}`}
          subtext=${swarmOverview?.last_movement_at ? `마지막 이동 ${relativeTime(swarmOverview.last_movement_at)}` : '최근 스웜 이동이 아직 없습니다'}
          percent=${ratioPercent(movingLanes, Math.max(activeLanes, movingLanes || 1))}
          color="#fbbf24"
        />
        <${GraphicGauge}
          label="증거 수집률"
          value=${`${proofDone}/${Math.max(proofExpected, proofDone)}`}
          subtext=${proof?.status ? `증거 소스 ${proof.source} · ${proof.status}` : '스웜 증거 아티팩트가 아직 없습니다'}
          percent=${ratioPercent(proofDone, Math.max(proofExpected, proofDone || 1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(210px,1fr))] gap-3 mb-4">
      <${SignalRail}
        label="승인 대기열"
        value=${`${pendingApprovals}건 대기`}
        detail=${`현재 정책 창에서 ${totalApprovals}개 결정을 추적 중입니다`}
        percent=${ratioPercent(pendingApprovals, Math.max(totalApprovals, pendingApprovals || 1))}
        tone=${pendingApprovals > 0 ? 'warn' : 'ok'}
      />
      <${SignalRail}
        label="알림 압력"
        value=${`치명 ${badAlerts} / 주의 ${warnAlerts}`}
        detail=${badAlerts > 0 ? '치명 신호가 이미 요약면에서 보입니다' : '보드를 지배하는 hard-stop 알림은 아직 없습니다'}
        percent=${ratioPercent(badAlerts * 2 + warnAlerts, Math.max((badAlerts + warnAlerts) * 2, 1))}
        tone=${badAlerts > 0 ? 'bad' : warnAlerts > 0 ? 'warn' : 'ok'}
      />
      <${SignalRail}
        label="디스패치 점유"
          value=${`${activeDetachments}개 가동`}
        detail=${managedUnits > 0 ? `${managedUnits}개 관리 단위가 작업을 받을 수 있습니다` : '관리 단위 토폴로지가 아직 없습니다'}
        percent=${ratioPercent(activeDetachments, Math.max(managedUnits, activeDetachments || 1))}
        tone=${activeDetachments > 0 ? 'ok' : 'warn'}
      />
      <${SignalRail}
        label="캐시 신뢰도"
        value=${cacheHit ? formatPercent(cacheHit) : '정보 없음'}
        detail=${cacheHit ? 'microarch 캐시 텔레메트리에서 집계한 L1 적중률' : '캐시 텔레메트리가 아직 집계되지 않았습니다'}
        percent=${clampPercent((cacheHit ?? 0) * 100)}
        tone=${cacheHit >= 0.75 ? 'ok' : cacheHit >= 0.4 ? 'warn' : 'bad'}
      />
    </div>
  `
}

export function SummaryCards() {
  const summary = currentCommandPlaneSummary()
  const chainSummary = commandPlaneChainSummary.value
  const workflowContext = workflowContextForRoute(route.value)
  const highlightKey = summaryHighlightKey(workflowContext)
  const topology = summary?.topology.summary
  const ops = summary?.operations.summary
  const swarm = summary?.swarm_status?.overview
  const microarch = summary?.operations.microarch
  const decisions = summary?.decisions.summary
  const alerts = summary?.alerts.summary
  const issuePressure = microarch?.signals?.issue_pressure
  const cache = microarch?.cache
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5"><span>유닛</span><strong>${topology?.total_units ?? 0}</strong><small>${topology?.managed_unit_count ?? 0}개 관리 중</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5"><span>작전</span><strong>${ops?.active ?? 0}</strong><small>${summary?.detachments.summary?.active ?? 0}개 실행체</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5"><span>승인</span><strong>${decisions?.pending ?? 0}</strong><small>${decisions?.total ?? 0}개 추적 중</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5 ${highlightKey === 'alerts' ? 'highlight' : ''}"><span>알림</span><strong>${alerts?.bad ?? 0}</strong><small>${alerts?.warn ?? 0}건 주의</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5"><span>체인</span><strong>${chainSummary?.summary?.active_chains ?? 0}</strong><small>${chainSummary?.summary?.linked_operations ?? 0}개 연결</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5 ${highlightKey === 'swarm' ? 'highlight' : ''}"><span>스웜</span><strong>${swarm?.active_lanes ?? 0}</strong><small>${swarm ? `${swarm.stalled_lanes ?? 0}개 정체 · ${relativeTime(swarm.last_movement_at)}` : 'lane snapshot 없음'}</small></div>
      <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-[14px] py-3.5 px-4 flex flex-col gap-1.5 ${highlightKey === 'microarch' ? 'highlight' : ''}"><span>마이크로아크</span><strong>${issuePressure?.pending_ops ?? 0}</strong><small>${cache?.l1_hit_rate != null ? `${formatPercent(cache.l1_hit_rate)} L1 적중` : '캐시 데이터 없음'} · ${issuePressure?.tone ?? '정보 없음'}</small></div>
    </div>
  `
}
