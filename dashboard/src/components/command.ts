import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  ChainHistoryEventSummary,
  CommandPlaneAlert,
  CommandPlaneChainOverlay,
  CommandPlaneChainRunNode,
  CommandPlaneCapacityRow,
  CommandPlaneDecisionRecord,
  CommandPlaneDetachmentCard,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpStep,
  CommandPlaneOperationCard,
  CommandPlaneSurface,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmProof,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmWorker,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
  OperatorRecommendedAction,
  OperatorSessionSnapshot,
  OperatorWorkerCard,
  PendingConfirmation,
  Task,
} from '../types'
import {
  approveCommandPlaneDecision,
  commandPlaneActionBusy,
  commandPlaneActionError,
  clearCommandPlaneChainRun,
  commandPlaneChainError,
  commandPlaneChainFocusOperationId,
  commandPlaneChainLoading,
  commandPlaneChainRun,
  commandPlaneChainRunError,
  commandPlaneChainRunLoading,
  commandPlaneChainSummary,
  commandPlaneError,
  commandPlaneDetailError,
  commandPlaneDetailLoading,
  commandPlaneHelp,
  commandPlaneHelpError,
  commandPlaneHelpLoading,
  commandPlaneLoading,
  commandPlaneSummary,
  commandPlaneSnapshot,
  commandPlaneSwarm,
  commandPlaneSwarmError,
  commandPlaneSwarmLoading,
  commandPlaneSurface,
  denyCommandPlaneDecision,
  focusCommandPlaneChainOperation,
  loadCommandPlaneChainRun,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneHelp,
  refreshCommandPlaneSwarm,
  runCommandPlaneDispatchTick,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
  toggleCommandPlaneFreeze,
  toggleCommandPlaneKillSwitch,
} from '../command-store'
import {
  operatorLoading,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../operator-store'
import { agents, serverStatus, tasks } from '../store'
import { navigate, route } from '../router'
import { PanelSemanticDetails, SurfaceSemanticIntro } from './common/semantic-layer'
import {
  commandSurfaceForContext,
  workflowActionLabel,
  workflowCommandSurfaceLabel,
  workflowContextForRoute,
  workflowTargetLabel,
  type DashboardWorkflowContext,
} from '../workflow-context'

function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function relativeTime(iso?: string | null): string {
  if (!iso) return 'n/a'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}s ago`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}m ago`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}h ago`
  return `${Math.round(deltaSec / 86400)}d ago`
}

function expiryTone(iso?: string | null): string {
  if (!iso) return 'warn'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return 'warn'
  return ts <= Date.now() ? 'bad' : 'ok'
}

function deadlineLabel(iso?: string | null): string {
  if (!iso) return 'n/a'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.round((ts - Date.now()) / 1000)
  if (deltaSec <= 0) return 'expired'
  if (deltaSec < 60) return `in ${deltaSec}s`
  if (deltaSec < 3600) return `in ${Math.round(deltaSec / 60)}m`
  if (deltaSec < 86400) return `in ${Math.round(deltaSec / 3600)}h`
  return `in ${Math.round(deltaSec / 86400)}d`
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad') return 'bad'
  if (tone === 'warn' || tone === 'pending') return 'warn'
  return 'ok'
}

type MermaidApi = typeof import('mermaid')['default']

let mermaidConfigured = false
let mermaidRenderCount = 0
let mermaidPromise: Promise<MermaidApi> | null = null

async function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(module => module.default)
  }
  const mermaid = await mermaidPromise
  if (mermaidConfigured) return mermaid
  mermaid.initialize({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'loose',
  })
  mermaidConfigured = true
  return mermaid
}

function chainStatusTone(status?: string | null): string {
  if (!status) return 'warn'
  const lowered = status.toLowerCase()
  if (
    lowered.includes('failed')
    || lowered.includes('error')
    || lowered.includes('disconnected')
    || lowered.includes('stopped')
  ) {
    return 'bad'
  }
  if (
    lowered.includes('running')
    || lowered.includes('active')
    || lowered.includes('degraded')
    || lowered.includes('pending')
  ) {
    return 'warn'
  }
  return 'ok'
}

function formatPercent(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 'n/a'
  return `${Math.round(value * 100)}%`
}

function formatElapsed(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 'n/a'
  if (value < 60) return `${Math.round(value)}s`
  if (value < 3600) return `${Math.round(value / 60)}m`
  return `${Math.round(value / 3600)}h`
}

function clampPercent(value?: number | null): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

function ratioPercent(part?: number | null, whole?: number | null): number {
  if (
    typeof part !== 'number'
    || !Number.isFinite(part)
    || typeof whole !== 'number'
    || !Number.isFinite(whole)
    || whole <= 0
  ) {
    return 0
  }
  return clampPercent((part / whole) * 100)
}

function gaugeStyle(percent: number, color: string): string {
  const safePercent = clampPercent(percent)
  const angle = Math.max(10, Math.round((safePercent / 100) * 360))
  return `--gauge-angle:${angle}deg;--gauge-color:${color};`
}

function historySummary(history?: ChainHistoryEventSummary | null): string {
  if (!history) return 'No recent chain history'
  const pieces = [history.event]
  if (typeof history.duration_ms === 'number') pieces.push(`${history.duration_ms}ms`)
  if (typeof history.tokens === 'number') pieces.push(`${history.tokens} tokens`)
  if (history.message) pieces.push(history.message)
  return pieces.join(' · ')
}

type CommandSurfaceGroup = 'status' | 'history' | 'control'

const COMMAND_SURFACE_GROUPS: Array<{ id: CommandSurfaceGroup; label: string }> = [
  { id: 'status', label: '현황' },
  { id: 'history', label: '이력' },
  { id: 'control', label: '통제' },
]

const COMMAND_SURFACE_META: Array<{ id: CommandPlaneSurface; label: string; group: CommandSurfaceGroup }> = [
  { id: 'warroom', label: '워룸', group: 'status' },
  { id: 'summary', label: '요약', group: 'status' },
  { id: 'topology', label: '토폴로지', group: 'status' },
  { id: 'swarm', label: '스웜', group: 'status' },
  { id: 'operations', label: '작전', group: 'history' },
  { id: 'trace', label: '트레이스', group: 'history' },
  { id: 'chains', label: '체인', group: 'history' },
  { id: 'control', label: '제어', group: 'control' },
  { id: 'alerts', label: '알림', group: 'control' },
]
const COMMAND_SURFACES: CommandPlaneSurface[] = COMMAND_SURFACE_META.map(item => item.id)
const CHAIN_SSE_EVENT_TYPES = ['chain_start', 'node_start', 'node_complete', 'chain_complete', 'chain_error']

const COMMAND_SURFACE_GUIDE: Record<CommandPlaneSurface, { title: string; description: string }> = {
  warroom: {
    title: '라이브 워룸',
    description: '실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다.',
  },
  operations: {
    title: '현재 작전 상세',
    description: '활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다.',
  },
  swarm: {
    title: '스웜 실행 흐름',
    description: 'lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다.',
  },
  chains: {
    title: '체인 런타임',
    description: '체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다.',
  },
  topology: {
    title: '지휘 계층',
    description: 'company에서 agent까지 지휘 계층과 live roster를 확인합니다.',
  },
  alerts: {
    title: '경보 모음',
    description: '지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다.',
  },
  trace: {
    title: '최근 트레이스',
    description: 'operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다.',
  },
  control: {
    title: '승인과 제어',
    description: 'decision 승인과 unit 제어를 실제로 수행하는 표면입니다.',
  },
  summary: {
    title: '지휘 요약',
    description: '전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다.',
  },
}

function isCommandSurface(value: string | undefined): value is CommandPlaneSurface {
  return !!value && COMMAND_SURFACES.includes(value as CommandPlaneSurface)
}

function inheritedMissionRouteParams(): Record<string, string> {
  const params = route.value.params
  if (params.source !== 'mission') return {}
  return {
    source: 'mission',
    ...(params.action_type ? { action_type: params.action_type } : {}),
    ...(params.target_type ? { target_type: params.target_type } : {}),
    ...(params.target_id ? { target_id: params.target_id } : {}),
    ...(params.focus_kind ? { focus_kind: params.focus_kind } : {}),
  }
}

function surfaceRouteParams(surface: CommandPlaneSurface): Record<string, string> {
  const inherited = inheritedMissionRouteParams()
  if (surface === 'operations') return inherited
  if (surface === 'chains') {
    const operationId = commandPlaneChainFocusOperationId.value
    return operationId ? { ...inherited, surface, operation: operationId } : { ...inherited, surface }
  }
  return { ...inherited, surface }
}

function chainEventsUrl(): string {
  const query = new URLSearchParams(window.location.search)
  const params = new URLSearchParams()
  const agent = query.get('agent') ?? query.get('agent_name')
  const token = query.get('token')
  if (agent) params.set('agent', agent)
  if (token) params.set('token', token)
  return params.toString() ? `/api/v1/chains/events?${params.toString()}` : '/api/v1/chains/events'
}

function unitKindLabel(kind: string): string {
  switch (kind) {
    case 'company':
      return '중대 / Company'
    case 'platoon':
      return '소대 / Platoon'
    case 'squad':
      return '분대 / Squad'
    case 'agent':
      return '에이전트 / Agent'
    default:
      return kind
  }
}

function actionDisabled(key: string): boolean {
  return commandPlaneActionBusy.value === key
}

function currentCommandPlaneSummary() {
  return commandPlaneSummary.value
}

function currentSurfaceRecommendation(surface: CommandPlaneSurface): {
  tool: string
  reason: string
} {
  const summary = commandPlaneSummary.value
  const swarm = commandPlaneSwarm.value
  const chainSummary = commandPlaneChainSummary.value

  switch (surface) {
    case 'warroom':
      return {
        tool: 'masc_observe_operations',
        reason: 'live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다.',
      }
    case 'operations':
      return {
        tool: 'masc_operation_status',
        reason: `활성 작전 ${summary?.operations.summary?.active ?? 0}개와 dependency를 먼저 확인합니다.`,
      }
    case 'swarm':
      return {
        tool: swarm?.recommended_next_tool ?? summary?.swarm_status?.recommended_next_action?.tool ?? 'masc_observe_traces',
        reason: summary?.swarm_status?.recommended_next_action?.reason ?? 'lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다.',
      }
    case 'chains':
      return {
        tool: chainSummary?.operations[0]?.preview_run?.chain_id ? 'masc_chain_run_get' : 'masc_chain_snapshot',
        reason: '체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다.',
      }
    case 'topology':
      return {
        tool: 'masc_observe_topology',
        reason: '지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다.',
      }
    case 'alerts':
      return {
        tool: 'masc_observe_alerts',
        reason: '경보에서 먼저 문제가 된 unit과 operation을 고릅니다.',
      }
    case 'trace':
      return {
        tool: 'masc_observe_traces',
        reason: 'trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다.',
      }
    case 'control':
      return {
        tool: 'masc_operator_action',
        reason: '승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다.',
      }
    case 'summary':
    default:
      return {
        tool: 'masc_observe_operations',
        reason: '요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다.',
      }
  }
}

function summaryHighlightKey(context: DashboardWorkflowContext | null): string | null {
  const focus = context?.focus_kind?.toLowerCase() ?? ''
  if (!focus) return null
  if (focus.includes('artifact_scope') || focus.includes('routing_confidence') || focus.includes('cache_contention')) {
    return 'microarch'
  }
  if (focus.includes('leader_offline') || focus.includes('roster_offline')) {
    return 'alerts'
  }
  if (focus.includes('stale_data')) {
    return 'swarm'
  }
  return null
}

function swarmFocusKey(context: DashboardWorkflowContext | null): string | null {
  const focus = context?.focus_kind?.toLowerCase() ?? ''
  if (!focus) return null
  if (focus.includes('stale_data') || focus.includes('leader_offline') || focus.includes('roster_offline') || focus.includes('managed')) {
    return 'recommendation'
  }
  if (focus.includes('gap')) return 'gaps'
  return null
}

function CommandWorkflowBanner() {
  const context = workflowContextForRoute(route.value)
  if (!context) return null
  return html`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${context.source_label}</strong>
        <span class="command-chip">${workflowActionLabel(context.action_type)}</span>
        <span class="command-chip">${workflowTargetLabel(context)}</span>
        <span class="command-chip">${workflowCommandSurfaceLabel(route.value.params.surface ?? 'warroom')}</span>
      </div>
      <div class="command-focus-body">${context.summary}</div>
      ${context.payload_preview
        ? html`<div class="command-focus-preview">${context.payload_preview}</div>`
        : null}
    </section>
  `
}

function CommandEntryStrip() {
  const surface = commandPlaneSurface.value
  const guide = COMMAND_SURFACE_GUIDE[surface]
  const recommendation = currentSurfaceRecommendation(surface)

  return html`
    <section class="command-entry-strip">
      <article class="command-entry-card">
        <span class="command-entry-label">현재 표면</span>
        <strong>${guide.title}</strong>
        <p>${guide.description}</p>
      </article>
      <article class="command-entry-card">
        <span class="command-entry-label">다음 추천</span>
        <strong>${recommendation.tool}</strong>
        <p>${recommendation.reason}</p>
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
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${gaugeStyle(percent, color)}>
        <div class="command-gauge-core">
          <strong>${value}</strong>
          <span>${Math.round(clampPercent(percent))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
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
    <article class="command-signal-rail ${toneClass(tone)}">
      <div class="command-signal-copy">
        <span>${label}</span>
        <strong>${value}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${toneClass(tone)}" style=${`width: ${Math.max(8, Math.round(clampPercent(percent)))}%`}></span>
      </div>
      <small>${detail}</small>
    </article>
  `
}

function SummaryHero() {
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
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${headline}</h3>
        <p>${subcopy}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${toneClass(activeOps > 0 ? 'ok' : 'warn')}">활성 작전 ${activeOps}</span>
          <span class="command-chip ${toneClass(movingLanes > 0 ? 'ok' : activeLanes > 0 ? 'warn' : 'warn')}">이동 레인 ${movingLanes}/${Math.max(activeLanes, movingLanes)}</span>
          <span class="command-chip ${toneClass(badAlerts > 0 ? 'bad' : warnAlerts > 0 ? 'warn' : 'ok')}">치명 알림 ${badAlerts}</span>
          <span class="command-chip ${toneClass(pendingApprovals > 0 ? 'warn' : 'ok')}">승인 대기 ${pendingApprovals}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
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
    <div class="command-signal-grid">
      <${SignalRail}
        label="승인 대기열"
        value=${`${pendingApprovals}건 대기`}
        detail=${`현재 정책 창에서 ${totalApprovals}개 결정을 추적 중입니다`}
        percent=${ratioPercent(pendingApprovals, Math.max(totalApprovals, pendingApprovals || 1))}
        tone=${pendingApprovals > 0 ? 'warn' : 'ok'}
      />
      <${SignalRail}
        label="알림 압력"
        value=${`${badAlerts} bad / ${warnAlerts} warn`}
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
        value=${cacheHit ? formatPercent(cacheHit) : 'n/a'}
        detail=${cacheHit ? 'microarch 캐시 텔레메트리에서 집계한 L1 hit rate' : '캐시 텔레메트리가 아직 집계되지 않았습니다'}
        percent=${clampPercent((cacheHit ?? 0) * 100)}
        tone=${cacheHit >= 0.75 ? 'ok' : cacheHit >= 0.4 ? 'warn' : 'bad'}
      />
    </div>
  `
}

function dashboardActorName(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  const value = params.get('agent') ?? params.get('agent_name')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function dashboardLocationParams(): URLSearchParams {
  if (typeof window === 'undefined') return new URLSearchParams()
  const search = new URLSearchParams(window.location.search)
  const hash = window.location.hash.replace(/^#/, '')
  const queryIdx = hash.indexOf('?')
  if (queryIdx >= 0) {
    const hashSearch = new URLSearchParams(hash.slice(queryIdx + 1))
    hashSearch.forEach((value, key) => {
      if (!search.has(key)) search.set(key, value)
    })
  }
  return search
}

function dashboardSwarmRunId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('run_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function dashboardSwarmOperationId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('operation_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function lastSeenAgeSeconds(iso?: string | null): number | null {
  if (!iso) return null
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return null
  return Math.max(0, Math.round((Date.now() - ts) / 1000))
}

function isActiveTask(task: Task): boolean {
  return task.status === 'claimed' || task.status === 'in_progress'
}

function findHelpStep(toolName: string): CommandPlaneHelpStep | null {
  const help = commandPlaneHelp.value
  if (!help) return null
  for (const path of help.golden_paths) {
    const matched = path.steps.find(step => step.tool === toolName)
    if (matched) return matched
  }
  return null
}

function findHelpPath(pathId: string): CommandPlaneHelpPath | null {
  return commandPlaneHelp.value?.golden_paths.find(path => path.id === pathId) ?? null
}

function relevantPitfalls(ids: string[]): CommandPlaneHelpPitfall[] {
  const help = commandPlaneHelp.value
  if (!help) return []
  const wanted = new Set(ids)
  return help.pitfalls.filter(pitfall => wanted.has(pitfall.id))
}

async function fire(action: () => Promise<void>) {
  try {
    await action()
  } catch {
    // Error state is already captured in the store.
  }
}

function normalizedStatus(value?: string | null): string {
  return value?.trim().toLowerCase() ?? ''
}

function sessionStatusTone(status?: string | null): string {
  const normalized = normalizedStatus(status)
  if (
    normalized.includes('failed')
    || normalized.includes('error')
    || normalized.includes('stopped')
    || normalized === 'paused'
  ) {
    return 'bad'
  }
  if (
    normalized.includes('active')
    || normalized.includes('running')
    || normalized.includes('healthy')
    || normalized.includes('ok')
  ) {
    return 'ok'
  }
  return 'warn'
}

function displayStatus(status?: string | null): string {
  const normalized = normalizedStatus(status)
  if (!normalized) return '확인 필요'
  if (normalized === 'active' || normalized === 'running') return '진행 중'
  if (normalized === 'paused') return '일시정지'
  if (normalized === 'done' || normalized === 'ended' || normalized === 'completed') return '완료'
  if (normalized === 'failed' || normalized === 'error' || normalized === 'stopped') return '문제'
  return status?.trim() || '확인 필요'
}

function hasSwarmActivity(): boolean {
  const swarm = commandPlaneSwarm.value
  if (!swarm) return false
  return Boolean(
    swarm.run_id
    || swarm.operation?.operation_id
    || swarm.detachment?.detachment_id
    || (swarm.summary?.expected_workers ?? 0) > 0
    || swarm.workers.length > 0
    || swarm.recent_messages.length > 0
    || swarm.recent_trace_events.length > 0,
  )
}

function isSessionLive(session: OperatorSessionSnapshot): boolean {
  const normalized = normalizedStatus(session.status)
  return normalized === 'active' || normalized === 'running'
}

function pickWarRoomSession(): OperatorSessionSnapshot | null {
  const sessions = operatorSnapshot.value?.sessions ?? []
  const swarm = commandPlaneSwarm.value
  const linkedSessionId = swarm?.detachment?.session_id ?? null
  if (linkedSessionId) {
    const linked = sessions.find(session => session.session_id === linkedSessionId)
    if (linked) return linked
  }
  const operationId = swarm?.operation?.operation_id ?? dashboardSwarmOperationId()
  if (operationId) {
    const operationLinked = sessions.find(session => session.command_plane_operation_id === operationId)
    if (operationLinked) return operationLinked
  }
  const detachmentId = swarm?.detachment?.detachment_id ?? null
  if (detachmentId) {
    const detachmentLinked = sessions.find(session => session.command_plane_detachment_id === detachmentId)
    if (detachmentLinked) return detachmentLinked
  }
  return sessions.find(isSessionLive) ?? sessions[0] ?? null
}

type WarRoomWorkerView = {
  key: string
  name: string
  role: string
  lane: string
  status: string
  source: 'swarm' | 'session'
  task: string
  heartbeat: string
  detail: string
  markers: string[]
  note?: string | null
}

function swarmWorkerView(worker: CommandPlaneSwarmWorker): WarRoomWorkerView {
  const markers = [
    worker.current_task_matches_run ? 'current' : 'drift',
    worker.claim_marker_seen ? 'claim' : 'no-claim',
    worker.done_marker_seen ? 'done' : 'no-done',
    worker.final_marker_seen ? 'final' : 'no-final',
  ]
  return {
    key: `swarm:${worker.name}`,
    name: worker.name,
    role: worker.role,
    lane: worker.lane,
    status: worker.status,
    source: 'swarm',
    task: worker.current_task ?? worker.bound_task_title ?? worker.bound_task_id ?? 'none',
    heartbeat:
      worker.heartbeat_age_sec != null
        ? `${Math.round(worker.heartbeat_age_sec)}s`
        : worker.heartbeat_fresh
          ? 'clean'
          : 'n/a',
    detail: [
      worker.bound_task_status ?? null,
      worker.detachment_member ? 'detachment' : null,
      worker.squad_member ? 'squad' : null,
    ].filter(Boolean).join(' · ') || 'live swarm worker',
    markers,
    note: worker.last_message?.content ?? null,
  }
}

function operatorWorkerView(worker: OperatorWorkerCard, index: number): WarRoomWorkerView {
  const name = worker.actor ?? worker.spawn_role ?? `worker-${index + 1}`
  const role = worker.spawn_role ?? worker.worker_class ?? worker.spawn_agent ?? 'worker'
  const lane = worker.lane_id ?? worker.capsule_mode ?? worker.control_domain ?? 'session'
  const markers = [
    worker.has_turn ? 'turn' : 'silent',
    worker.empty_note_turn_count > 0 ? `empty:${worker.empty_note_turn_count}` : 'noted',
    worker.turn_count > 0 ? `turns:${worker.turn_count}` : 'turns:0',
  ]
  return {
    key: `session:${name}:${index}`,
    name,
    role,
    lane,
    status: worker.status,
    source: 'session',
    task: worker.task_profile ?? worker.runtime_pool ?? 'session lane',
    heartbeat: worker.last_turn_ts_iso ? relativeTime(worker.last_turn_ts_iso) : 'n/a',
    detail: [
      worker.spawn_agent ?? null,
      worker.spawn_model ?? null,
      worker.routing_confidence != null ? formatPercent(worker.routing_confidence) : null,
    ].filter(Boolean).join(' · ') || 'session worker',
    markers,
    note: worker.routing_reason ?? null,
  }
}

function warRoomRecommendationTone(item: OperatorRecommendedAction): string {
  return toneClass(item.severity)
}

function WarRoomWorkerCard({ worker }: { worker: WarRoomWorkerView }) {
  return html`
    <article class="command-card compact warroom-worker-card ${toneClass(sessionStatusTone(worker.status))}">
      <div class="command-card-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="command-card-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(sessionStatusTone(worker.status))}">${worker.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${worker.source}</span>
        <span>Task</span><span>${worker.task}</span>
        <span>Heartbeat</span><span>${worker.heartbeat}</span>
        <span>Detail</span><span>${worker.detail}</span>
      </div>
      <div class="command-tag-row">
        ${worker.markers.map(marker => html`<span class="command-tag">${marker}</span>`)}
      </div>
      ${worker.note
        ? html`<div class="command-card-foot">${worker.note}</div>`
        : null}
    </article>
  `
}

function WarRoomJumpButton({
  label,
  surface,
  params = {},
}: {
  label: string
  surface?: CommandPlaneSurface
  params?: Record<string, string>
}) {
  return html`
    <button
      class="control-btn ghost"
      onClick=${() => {
        if (surface) {
          setCommandPlaneSurface(surface)
          navigate('command', { ...surfaceRouteParams(surface), ...params })
          return
        }
        navigate('intervene')
      }}
    >
      ${label}
    </button>
  `
}

function SummaryCards() {
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
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${topology?.total_units ?? 0}</strong><small>${topology?.managed_unit_count ?? 0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${ops?.active ?? 0}</strong><small>${summary?.detachments.summary?.active ?? 0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${decisions?.pending ?? 0}</strong><small>${decisions?.total ?? 0}개 추적 중</small></div>
      <div class="monitor-stat-card ${highlightKey === 'alerts' ? 'highlight' : ''}"><span>알림</span><strong>${alerts?.bad ?? 0}</strong><small>${alerts?.warn ?? 0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${chainSummary?.summary?.active_chains ?? 0}</strong><small>${chainSummary?.summary?.linked_operations ?? 0}개 연결</small></div>
      <div class="monitor-stat-card ${highlightKey === 'swarm' ? 'highlight' : ''}"><span>스웜</span><strong>${swarm?.active_lanes ?? 0}</strong><small>${swarm ? `${swarm.stalled_lanes ?? 0}개 정체 · ${relativeTime(swarm.last_movement_at)}` : 'lane snapshot 없음'}</small></div>
      <div class="monitor-stat-card ${highlightKey === 'microarch' ? 'highlight' : ''}"><span>마이크로아크</span><strong>${issuePressure?.pending_ops ?? 0}</strong><small>${cache?.l1_hit_rate != null ? `${formatPercent(cache.l1_hit_rate)} L1 hit` : '캐시 데이터 없음'} · ${issuePressure?.tone ?? 'n/a'}</small></div>
    </div>
  `
}

function swarmLaneTone(lane: CommandPlaneSwarmLane): string {
  if (lane.motion_state === 'stalled') return 'bad'
  if (lane.hard_flags.some(flag => flag.severity === 'bad')) return 'bad'
  if (lane.motion_state === 'waiting') return 'warn'
  if (lane.hard_flags.some(flag => flag.severity === 'warn')) return 'warn'
  return 'ok'
}

function SwarmHealthBar({ lanes }: { lanes: CommandPlaneSwarmLane[] }) {
  const counts = { moving: 0, waiting: 0, stalled: 0, terminal: 0 }
  for (const lane of lanes) {
    const m = lane.motion_state as keyof typeof counts
    if (m in counts) counts[m]++
    else counts.waiting++
  }
  const total = lanes.length
  if (total === 0) return null

  const segments: Array<{ key: string; count: number; color: string }> = [
    { key: 'moving', count: counts.moving, color: 'var(--ok)' },
    { key: 'waiting', count: counts.waiting, color: 'var(--warn)' },
    { key: 'stalled', count: counts.stalled, color: 'var(--bad)' },
    { key: 'terminal', count: counts.terminal, color: '#556' },
  ]

  return html`
    <div>
      <div class="swarm-health-bar">
        ${segments.filter(s => s.count > 0).map(s => html`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${segments.filter(s => s.count > 0).map(s => html`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${s.color}"></span>
            ${s.count} ${s.key}
          </span>
        `)}
      </div>
    </div>
  `
}

function SwarmWorkerGrid({ total }: { total: number }) {
  const maxDots = 20
  const present = Math.min(total, maxDots)
  const overflow = total > maxDots ? total - maxDots : 0
  const dots = Array.from({ length: present })

  return html`
    <div class="swarm-worker-grid">
      ${dots.map(() => html`<span class="swarm-worker-dot present"></span>`)}
      ${overflow > 0 ? html`<span class="swarm-worker-count">+${overflow}</span>` : null}
      <span class="swarm-worker-count">(워커 ${total})</span>
    </div>
  `
}

function SwarmLaneStrip({ lane }: { lane: CommandPlaneSwarmLane }) {
  const counts = lane.counts ?? {}
  const tone = swarmLaneTone(lane)
  const totalWorkers = counts.workers ?? 0
  const ops = counts.operations ?? 0
  const dets = counts.detachments ?? 0
  const totalOps = ops + dets
  const progressPercent =
    lane.motion_state === 'moving'
      ? 84
      : lane.motion_state === 'waiting'
        ? 58
        : lane.motion_state === 'terminal'
          ? 100
          : 26

  return html`
    <article class="swarm-lane-strip ${toneClass(tone)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${lane.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${lane.kind} · ${lane.source_of_truth}</span>
            <strong>${lane.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${toneClass(tone)}">${lane.phase}</span>
          <span class="command-chip ${toneClass(tone)}">${lane.motion_state}</span>
          <span class="command-chip">${relativeTime(lane.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${lane.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${toneClass(tone)}" style=${`width:${progressPercent}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${lane.current_step}</span>
        </div>
        ${totalWorkers > 0
          ? html`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${SwarmWorkerGrid} total=${totalWorkers} />
              </div>
            `
          : null}
        ${totalOps > 0
          ? html`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${totalOps > 0 ? Math.round((ops / totalOps) * 100) : 0}%; background: var(--${tone === 'bad' ? 'bad' : tone === 'warn' ? 'warn' : 'ok'})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${ops} · 실행체 ${dets}</span>
              </div>
            `
          : null}
      </div>
      ${lane.blockers.length > 0
        ? html`<div class="swarm-lane-blockers">막힘: ${lane.blockers.join(' · ')}</div>`
        : null}
      ${lane.hard_flags.length > 0
        ? html`
            <div class="swarm-lane-flags">
              ${lane.hard_flags.map((flag: CommandPlaneSwarmFlag) => html`<span class="command-chip ${toneClass(flag.severity)}">${flag.code}</span>`)}
            </div>
          `
        : null}
    </article>
  `
}

function SwarmStoryboard({ lanes }: { lanes: CommandPlaneSwarmLane[] }) {
  const featured = lanes.slice(0, 4)
  if (featured.length === 0) return null
  return html`
    <div class="swarm-storyboard">
      ${featured.map(lane => {
        const tone = swarmLaneTone(lane)
        const workers = lane.counts.workers ?? 0
        const operations = lane.counts.operations ?? 0
        const detachments = lane.counts.detachments ?? 0
        return html`
          <article class="swarm-story-card ${toneClass(tone)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${toneClass(tone)}">${lane.motion_state}</span>
              <span class="command-chip">${lane.phase}</span>
            </div>
            <strong>${lane.label}</strong>
            <p>${lane.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${workers}</span>
              <span>작전 ${operations}</span>
              <span>실행체 ${detachments}</span>
            </div>
            <small>${lane.movement_reason}</small>
          </article>
        `
      })}
    </div>
  `
}

function SwarmEventNode({ event }: { event: CommandPlaneSwarmTimelineEvent }) {
  const ts = event.timestamp ? new Date(event.timestamp) : null
  const validTs = ts && !isNaN(ts.getTime()) ? ts : null
  const timeStr = validTs ? `${String(validTs.getHours()).padStart(2, '0')}:${String(validTs.getMinutes()).padStart(2, '0')}` : ''
  return html`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${toneClass(event.tone)}"></span>
      <span class="swarm-event-time">${timeStr}</span>
      <div class="swarm-event-body">
        <strong>${event.title}</strong>
        <span class="swarm-event-kind">${event.kind}</span>
        ${event.detail ? html`<div class="command-card-sub">${event.detail}</div>` : null}
      </div>
    </div>
  `
}

function SwarmGapDot({ gap }: { gap: CommandPlaneSwarmGap }) {
  return html`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${toneClass(gap.severity)}">${gap.code} (${gap.count})</span>
      <span class="command-card-sub">${gap.summary}</span>
    </div>
  `
}

function SwarmProofPanel({ proof }: { proof?: CommandPlaneSwarmProof }) {
  const tone =
    proof?.status === 'missing'
      ? 'warn'
      : proof?.pass === false
        ? 'bad'
        : proof?.pass === true
          ? 'ok'
          : 'warn'
  return html`
    <div class="command-guide-card ${toneClass(tone)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${toneClass(tone)}">${proof?.status ?? 'missing'}</span>
        </div>
      ${proof
        ? html`
            <div class="command-card-grid">
              <span>소스</span><span>${proof.source}</span>
              <span>런</span><span>${proof.run_id ?? 'n/a'}</span>
              <span>수집 시각</span><span>${relativeTime(proof.captured_at)}</span>
              <span>통과</span><span>${proof.pass == null ? 'n/a' : proof.pass ? '예' : '아니오'}</span>
              <span>최대 Hot Slots</span><span>${proof.peak_hot_slots ?? 'n/a'}</span>
              <span>Ctx / Slot</span><span>${proof.ctx_per_slot ?? 'n/a'}</span>
              <span>워커 증거</span><span>${proof.workers.expected ?? 'n/a'} 예상 · ${proof.workers.done ?? 'n/a'} 완료 · ${proof.workers.final ?? 'n/a'} 최종</span>
            </div>
            ${proof.artifact_ref
              ? html`<div class="command-card-foot">${proof.artifact_ref}</div>`
              : null}
            ${proof.missing_reason
              ? html`<p>${proof.missing_reason}</p>`
              : null}
          `
        : html`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `
}

function SwarmPanel() {
  const summary = currentCommandPlaneSummary()
  const workflowContext = workflowContextForRoute(route.value)
  const focusKey = swarmFocusKey(workflowContext)
  const swarm = summary?.swarm_status
  const proof = summary?.swarm_proof
  const lanes = swarm?.lanes.filter(lane => lane.present) ?? []
  const gaps = swarm?.gaps.items ?? []
  const timeline = swarm?.timeline.slice(0, 8) ?? []
  const overview = swarm?.overview
  const recommendation = swarm?.recommended_next_action
  const compactLayout = lanes.length <= 1

  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
      </div>
      ${swarm
        ? html`
            <${SwarmStoryboard} lanes=${lanes} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${overview?.active_lanes ?? 0}</strong><small>${overview?.moving_lanes ?? 0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${overview?.stalled_lanes ?? 0}</strong><small>${overview?.projected_lanes ?? 0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${relativeTime(overview?.last_movement_at)}</strong><small>${swarm.generated_at ? `스냅샷 ${relativeTime(swarm.generated_at)}` : '방금 스냅샷'}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${recommendation?.label ?? '운영자 상태 확인'}</strong><small>${recommendation?.tool ?? 'masc_operator_snapshot'}</small></div>
            </div>

            ${lanes.length > 0 ? html`<${SwarmHealthBar} lanes=${lanes} />` : null}

            <div class="command-swarm-layout ${compactLayout ? 'compact' : ''}">
              <div class="command-card-stack">
                ${lanes.length > 0
                  ? lanes.map(lane => html`<${SwarmLaneStrip} lane=${lane} />`)
                  : html`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${focusKey === 'recommendation' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>${recommendation?.label ?? '운영자 상태 확인'}</strong>
                    <span class="command-chip">${recommendation?.lane_id ?? '전체'}</span>
                  </div>
                  <p>${recommendation?.reason ?? '보이는 활성 스웜 레인이 아직 없습니다.'}</p>
                  <div class="command-card-foot">${recommendation?.tool ?? 'masc_operator_snapshot'}</div>
                </div>

                <${SwarmProofPanel} proof=${proof} />

                <div class="command-guide-card ${gaps.length > 0 ? 'warn' : 'ok'} ${focusKey === 'gaps' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${toneClass(gaps.some(gap => gap.severity === 'bad') ? 'bad' : gaps.length > 0 ? 'warn' : 'ok')}">${gaps.length}</span>
                  </div>
                  ${gaps.length > 0
                    ? html`<div class="swarm-event-rail">${gaps.slice(0, 4).map(gap => html`<${SwarmGapDot} gap=${gap} />`)}</div>`
                    : html`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${timeline.length}</span>
                  </div>
                  ${timeline.length > 0
                    ? html`<div class="swarm-event-rail">${timeline.map(event => html`<${SwarmEventNode} event=${event} />`)}</div>`
                    : html`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `
        : html`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `
}

function SurfaceTabs() {
  return html`
    <div class="command-surface-tabs grouped">
      ${COMMAND_SURFACE_GROUPS.map(group => html`
        <div class="command-tab-group" key=${group.id}>
          <span class="command-tab-group-label">${group.label}</span>
          <div class="command-tab-group-items">
            ${COMMAND_SURFACE_META
              .filter(surface => surface.group === group.id)
              .map(surface => html`
                <button
                  class="command-surface-tab ${commandPlaneSurface.value === surface.id ? 'active' : ''}"
                  onClick=${() => {
                    setCommandPlaneSurface(surface.id)
                    navigate('command', surfaceRouteParams(surface.id))
                  }}
                >
                  ${surface.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `
}

function GuidedPanel() {
  const summary = currentCommandPlaneSummary()
  const snapshot = commandPlaneSnapshot.value
  const status = serverStatus.value
  const actorName = dashboardActorName()
  const actor = actorName ? agents.value.find(item => item.name === actorName) ?? null : null
  const actorTasks = actorName ? tasks.value.filter(task => task.assignee === actorName && isActiveTask(task)) : []
  const activeOps = summary?.operations.summary?.active ?? 0
  const detachments = summary?.detachments.summary?.total ?? 0
  const pendingDecisions = summary?.decisions.summary?.pending ?? 0
  const stalledDetachment = snapshot?.detachments.detachments.find(card => {
    const heartbeatDeadline = card.detachment.heartbeat_deadline
    const deadlineTs = heartbeatDeadline ? Date.parse(heartbeatDeadline) : Number.NaN
    return card.detachment.status === 'stalled' || (!Number.isNaN(deadlineTs) && deadlineTs <= Date.now())
  })
  const badAlert = snapshot?.alerts.alerts.find(alert => alert.severity === 'bad')
  const roomReady = Boolean(status?.room || status?.project)
  const currentTask = actor?.current_task ?? null
  const lastSeenAge = lastSeenAgeSeconds(actor?.last_seen)
  const heartbeatFresh = lastSeenAge != null ? lastSeenAge <= 120 : null

  const readiness = [
    roomReady
      ? {
          title: 'Room 준비도',
          tone: 'ok',
          detail: `${status?.room ?? status?.project ?? 'unknown'} · base ${status?.room_base_path ?? 'n/a'}`,
          tool: 'masc_status',
        }
      : {
          title: 'Room 준비도',
          tone: 'bad',
          detail: '아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.',
          tool: 'masc_set_room',
        },
    !actorName
      ? {
          title: 'Task 준비도',
          tone: 'warn',
          detail: '?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.',
          tool: 'masc_join',
        }
      : !actor
        ? {
            title: 'Task 준비도',
            tone: 'bad',
            detail: `${actorName} 이 room roster에 보이지 않습니다.`,
            tool: 'masc_join',
          }
        : actorTasks.length === 0
          ? {
              title: 'Task 준비도',
              tone: 'warn',
              detail: `${actorName} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,
              tool: tasks.value.length > 0 ? 'masc_claim' : 'masc_add_task',
            }
          : !currentTask
            ? {
                title: 'Task 준비도',
                tone: 'bad',
                detail: `${actorName} 에 claimed task는 있지만 session current_task binding이 없습니다.`,
                tool: 'masc_plan_set_task',
              }
            : heartbeatFresh === false
              ? {
                  title: 'Task 준비도',
                  tone: 'warn',
                  detail: `${actorName} current_task=${currentTask} 이지만 heartbeat가 stale 합니다 (${lastSeenAge}s).`,
                  tool: 'masc_heartbeat',
                }
              : {
                  title: 'Task 준비도',
                  tone: 'ok',
                  detail: `${actorName} current_task=${currentTask}${lastSeenAge != null ? ` · 마지막 활동 ${lastSeenAge}s 전` : ''}`,
                  tool: 'masc_plan_get_task',
                },
    !summary || (summary.topology.summary?.managed_unit_count ?? 0) === 0
      ? {
          title: '작전 준비도',
          tone: 'warn',
          detail: '관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.',
          tool: 'masc_unit_define',
        }
      : activeOps === 0
        ? {
            title: '작전 준비도',
            tone: 'warn',
            detail: `${summary.topology.summary?.managed_unit_count ?? 0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,
            tool: 'masc_operation_start',
          }
        : {
            title: '작전 준비도',
            tone: 'ok',
            detail: `${summary.topology.summary?.managed_unit_count ?? 0}개 관리 단위 위에서 ${activeOps}개 활성 작전이 돌고 있습니다.`,
            tool: 'masc_observe_operations',
          },
    pendingDecisions > 0
      ? {
          title: '디스패치 준비도',
          tone: 'warn',
          detail: `${pendingDecisions}개의 pending approval이 strict action을 막고 있습니다.`,
          tool: 'masc_policy_approve',
        }
      : activeOps > 0 && detachments === 0
        ? {
            title: '디스패치 준비도',
            tone: 'bad',
            detail: 'active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.',
            tool: 'masc_dispatch_tick',
          }
        : stalledDetachment || badAlert
          ? {
              title: '디스패치 준비도',
              tone: 'warn',
              detail: `dispatch 재정렬이 필요합니다${stalledDetachment ? ` · detachment ${stalledDetachment.detachment.detachment_id} 가 stalled 상태입니다` : ''}${badAlert ? ` · alert ${badAlert.title ?? badAlert.alert_id}` : ''}${!snapshot && !stalledDetachment && !badAlert ? ' · 정확한 원인은 detail 탭에서 확인하세요.' : ''}.`,
              tool: pendingDecisions > 0 ? 'masc_policy_approve' : 'masc_dispatch_tick',
            }
          : {
              title: '디스패치 준비도',
              tone: 'ok',
              detail: `${detachments}개 detachment가 보이고 strict approval backlog도 없습니다${!snapshot ? ' · detail pane은 열릴 때만 로드됩니다.' : ''}.`,
              tool: 'masc_detachment_list',
            },
  ]

  const nextTool =
    !roomReady
      ? 'masc_set_room'
      : !actorName || !actor
        ? 'masc_join'
        : actorTasks.length === 0
          ? (tasks.value.length > 0 ? 'masc_claim' : 'masc_add_task')
          : !currentTask
            ? 'masc_plan_set_task'
            : heartbeatFresh === false
              ? 'masc_heartbeat'
              : !summary || (summary.topology.summary?.managed_unit_count ?? 0) === 0
                ? 'masc_unit_define'
                : activeOps === 0
                  ? 'masc_operation_start'
                  : pendingDecisions > 0
                    ? 'masc_policy_approve'
                    : activeOps > 0 && detachments === 0
                      ? 'masc_dispatch_tick'
                      : stalledDetachment || badAlert
                        ? 'masc_dispatch_tick'
                        : 'masc_observe_traces'
  const nextStep = findHelpStep(nextTool)
  const pitfallIds =
    nextTool === 'masc_set_room'
      ? ['repo-root-room']
      : nextTool === 'masc_plan_set_task'
        ? ['claimed-not-current']
        : nextTool === 'masc_heartbeat'
          ? ['heartbeat-stale']
          : nextTool === 'masc_dispatch_tick'
            ? ['no-detachments']
            : nextTool === 'masc_policy_approve'
              ? ['pending-approval']
              : ['repo-root-room', 'claimed-not-current', 'heartbeat-stale']
  const pitfalls = relevantPitfalls(pitfallIds).slice(0, 2)
  const roomPath = findHelpPath('room_task_hygiene')
  const benchmarkPath = findHelpPath('cpv2_benchmark')
  const supervisorPath = findHelpPath('supervisor_session')
  const docs = commandPlaneHelp.value?.docs ?? []
  const renderedPaths = [roomPath, benchmarkPath, supervisorPath].filter(
    (item): item is CommandPlaneHelpPath => item !== null,
  )

  return html`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${PanelSemanticDetails} panelId="command.summary" compact=${true} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${nextStep?.title ?? nextTool}</strong>
            <span class="command-chip ok">${nextTool}</span>
          </div>
          <p>${nextStep?.summary ?? '지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다.'}</p>
          ${nextStep?.success_signals?.length
            ? html`<div class="command-tag-row">
                ${nextStep.success_signals.map(signal => html`<span class="command-tag ok">${signal}</span>`)}
              </div>`
            : null}
        </div>

        <div class="command-readiness-list">
          ${readiness.map(item => html`
            <article class="command-readiness-row ${toneClass(item.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${item.title}</strong>
                  <span class="command-chip ${toneClass(item.tone)}">${item.tone}</span>
                </div>
                <p>${item.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${item.tool}</div>
            </article>
          `)}
        </div>

        ${pitfalls.length > 0
          ? html`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${pitfalls.length}</span>
                </div>
                <div class="command-guide-list">
                  ${pitfalls.map(pitfall => html`
                    <article class="command-guide-inline">
                      <strong>${pitfall.title}</strong>
                      <div>${pitfall.symptom}</div>
                      <div class="command-card-sub">${pitfall.fix_tool} 로 해결: ${pitfall.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `
          : null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${PanelSemanticDetails} panelId="command.summary" compact=${true} />
        </div>
        ${commandPlaneHelpLoading.value
          ? html`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`
          : commandPlaneHelpError.value
            ? html`<div class="empty-state error">${commandPlaneHelpError.value}</div>`
            : html`
                <div class="command-path-grid">
                  ${renderedPaths.map(path => html`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${path.title}</strong>
                        <span class="command-chip">${path.id}</span>
                      </div>
                      <p>${path.summary}</p>
                      <div class="command-card-sub">${path.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${path.steps.slice(0, 4).map(step => html`
                          <div class="command-step-row">
                            <span class="command-step-tool">${step.tool}</span>
                            <span>${step.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${docs.length > 0
                  ? html`<div class="command-doc-links">
                      ${docs.map(doc => html`<span class="command-tag">${doc.title}: ${doc.path}</span>`)}
                    </div>`
                  : null}
              `}
      </section>
    </div>
  `
}

function SummarySurface() {
  return html`
    <${SummaryHero} />
    <${SummaryCards} />
    <${GuidedPanel} />
  `
}

function DetailLoadingState() {
  if (commandPlaneDetailLoading.value) {
    return html`<div class="empty-state">command-plane detail 불러오는 중…</div>`
  }
  if (commandPlaneDetailError.value) {
    return html`<div class="empty-state error">${commandPlaneDetailError.value}</div>`
  }
  return html`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`
}

function TopologyNode({ node, depth = 0 }: { node: CommandPlaneTreeNode; depth?: number }) {
  const rosterLive = node.roster_live ?? 0
  const rosterTotal = node.roster_total ?? node.unit.roster.length
  const activeOps = node.active_operation_count ?? 0
  const policy = node.unit.policy
  return html`
    <div class="command-tree-node depth-${Math.min(depth, 3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${node.unit.label}</strong>
            <span class="command-chip">${unitKindLabel(node.unit.kind)}</span>
            <span class="command-chip ${toneClass(node.health)}">${node.health ?? 'ok'}</span>
            ${policy?.frozen ? html`<span class="command-chip warn">frozen</span>` : null}
            ${policy?.kill_switch ? html`<span class="command-chip bad">kill-switch</span>` : null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${node.unit.unit_id}</span>
            <span>Leader ${node.unit.leader_id ?? 'unassigned'} / ${node.leader_status ?? 'unknown'}</span>
            <span>Roster ${rosterLive}/${rosterTotal}</span>
            <span>Ops ${activeOps}</span>
            <span>Autonomy ${policy?.autonomy_level ?? 'n/a'}</span>
          </div>
          ${node.reasons && node.reasons.length > 0
            ? html`<div class="command-tag-row">
                ${node.reasons.map(reason => html`<span class="command-tag warn">${reason}</span>`)}
              </div>`
            : null}
        </div>
      </div>
      ${node.children.length > 0
        ? html`<div class="command-tree-children">
            ${node.children.map(child => html`<${TopologyNode} node=${child} depth=${depth + 1} />`)}
          </div>`
        : null}
    </div>
  `
}

function MermaidGraph({ source }: { source: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.innerHTML = ''
    setError(null)

    const render = async () => {
      try {
        const mermaid = await getMermaid()
        const { svg } = await mermaid.render(`command-chain-${++mermaidRenderCount}`, source)
        if (cancelled || !hostRef.current) return
        hostRef.current.innerHTML = svg
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Mermaid render failed')
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.innerHTML = ''
    }
  }, [source])

  return html`
    <div class="command-chain-graph-shell">
      ${error ? html`<div class="empty-state error">${error}</div>` : null}
      <div class="command-chain-graph" ref=${hostRef}></div>
    </div>
  `
}

function ChainOperationListItem(
  { overlay, selected, onSelect }: { overlay: CommandPlaneChainOverlay; selected: boolean; onSelect: () => void },
) {
  const chain = overlay.operation.chain
  const runtime = overlay.runtime
  return html`
    <button class="command-chain-item ${selected ? 'selected' : ''}" onClick=${onSelect}>
      <div class="command-card-head">
        <div>
          <strong>${overlay.operation.objective}</strong>
          <div class="command-card-sub">${overlay.operation.operation_id}</div>
        </div>
        <span class="command-chip ${chainStatusTone(chain?.status)}">${chain?.status ?? overlay.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${chain?.kind ?? 'chain_dsl'}</span>
        ${chain?.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
        ${runtime ? html`<span class="command-tag ${chainStatusTone(chain?.status)}">${formatPercent(runtime.progress)} progress</span>` : null}
      </div>
      <div class="command-card-sub">${historySummary(overlay.history)}</div>
    </button>
  `
}

function ChainHistoryRow({ item }: { item: ChainHistoryEventSummary }) {
  return html`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${item.chain_id ?? 'unknown-chain'}</strong>
        <span class="command-chip ${chainStatusTone(item.event)}">${item.event}</span>
      </div>
      <div class="command-card-sub">${relativeTime(item.timestamp)}</div>
      <div class="command-card-sub">${historySummary(item)}</div>
    </article>
  `
}

function ChainRunNodeRow({ node }: { node: CommandPlaneChainRunNode }) {
  return html`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${node.id}</strong>
        <span class="command-chip ${chainStatusTone(node.status)}">${node.status ?? 'unknown'}</span>
      </div>
      <div class="command-card-sub">
        ${node.type ?? 'node'}
        ${typeof node.duration_ms === 'number' ? ` · ${node.duration_ms}ms` : ''}
      </div>
      ${node.error ? html`<div class="command-card-sub error-text">${node.error}</div>` : null}
    </article>
  `
}

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
  const chain = op.chain
  const runId = chain?.run_id ?? null
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="command-card-sub">${op.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')}">${op.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${op.trace_id}</span>
        <span>Autonomy</span><span>${op.autonomy_level ?? 'n/a'}</span>
        <span>Budget</span><span>${op.budget_class ?? 'standard'}</span>
        <span>Source</span><span>${op.source ?? 'managed'}</span>
        <span>Updated</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${chain
        ? html`
            <div class="command-tag-row">
              <span class="command-tag">${chain.kind}</span>
              <span class="command-tag ${chainStatusTone(chain.status)}">${chain.status}</span>
              ${chain.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
              ${chain.run_id ? html`<span class="command-tag">run ${chain.run_id}</span>` : null}
            </div>
          `
        : null}
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">Checkpoint ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${() => {
            setCommandPlaneSurface('swarm')
            navigate('command', {
              surface: 'swarm',
              operation_id: op.operation_id,
              ...(runId ? { run_id: runId } : {}),
            })
          }}
        >
          Swarm Live
        </button>
        ${chain
          ? html`
              <button
                class="control-btn ghost"
                onClick=${() => {
                  focusCommandPlaneChainOperation(op.operation_id)
                  setCommandPlaneSurface('chains')
                  navigate('command', { surface: 'chains', operation: op.operation_id })
                }}
              >
                Open Chain
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? 'Pausing…' : 'Pause'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? 'Recalling…' : 'Recall'}
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? 'Resuming…' : 'Resume'}
              </button>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="command-card-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(detachment.status)}">${detachment.status ?? 'active'}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? detachment.assigned_unit_id}</span>
        <span>Leader</span><span>${detachment.leader_id ?? 'unassigned'}</span>
        <span>Roster</span><span>${detachment.roster.length}</span>
        <span>Session</span><span>${detachment.session_id ?? 'none'}</span>
        <span>Runtime</span><span>${detachment.runtime_kind ?? 'managed'}</span>
        <span>Runtime Ref</span><span>${detachment.runtime_ref ?? 'n/a'}</span>
        <span>Progress</span><span>${relativeTime(detachment.last_progress_at)}</span>
        <span>Heartbeat</span><span>${deadlineLabel(detachment.heartbeat_deadline)}</span>
        <span>Updated</span><span>${relativeTime(detachment.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${detachment.heartbeat_deadline
          ? html`<span class="command-tag ${expiryTone(detachment.heartbeat_deadline)}">
              deadline ${detachment.heartbeat_deadline}
            </span>`
          : null}
      </div>
    </article>
  `
}

function AlertCard({ alert }: { alert: CommandPlaneAlert }) {
  return html`
    <article class="command-alert ${toneClass(alert.severity)}">
      <div class="command-card-head">
        <strong>${alert.title ?? alert.kind ?? alert.alert_id}</strong>
        <span class="command-chip ${toneClass(alert.severity)}">${alert.severity ?? 'warn'}</span>
      </div>
      <div class="command-alert-meta">
        <span>${alert.scope_type ?? 'scope'}:${alert.scope_id ?? 'n/a'}</span>
        <span>${relativeTime(alert.timestamp)}</span>
      </div>
      ${alert.detail ? html`<p>${alert.detail}</p>` : null}
    </article>
  `
}

function TraceRow({ event }: { event: CommandPlaneTraceEvent }) {
  return html`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${event.event_type}</strong>
          <span class="command-chip">${event.source ?? 'control_plane'}</span>
          <span class="command-chip">${relativeTime(event.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${event.operation_id ?? event.trace_id}
          ${event.unit_id ? ` · ${event.unit_id}` : ''}
          ${event.actor ? ` · ${event.actor}` : ''}
        </div>
      </div>
      <pre class="command-trace-detail">${prettyJson(event.detail)}</pre>
    </article>
  `
}

function DecisionCard({ decision }: { decision: CommandPlaneDecisionRecord }) {
  const approveKey = `approve:${decision.decision_id}`
  const denyKey = `deny:${decision.decision_id}`
  const isLegacy = decision.source === 'projected_operator'
  return html`
    <article class="command-card ${toneClass(decision.status)}">
      <div class="command-card-head">
        <div>
          <strong>${decision.requested_action}</strong>
          <div class="command-card-sub">${decision.scope_type}:${decision.scope_id}</div>
        </div>
        <span class="command-chip ${toneClass(decision.status)}">${decision.status ?? 'pending'}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${decision.decision_id}</span>
        <span>By</span><span>${decision.requested_by ?? 'unknown'}</span>
        <span>Source</span><span>${decision.source ?? 'managed'}</span>
        <span>Trace</span><span class="mono">${decision.trace_id}</span>
        <span>Created</span><span>${relativeTime(decision.created_at)}</span>
        <span>Reason</span><span>${decision.reason ?? 'n/a'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? 'Approving…' : 'Approve'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? 'Denying…' : 'Deny'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>` : null}
    </article>
  `
}

function CapacityRowCard({ row }: { row: CommandPlaneCapacityRow }) {
  const unit = row.unit
  const freezeKey = `freeze:${unit.unit_id}`
  const killKey = `kill:${unit.unit_id}`
  const frozen = !!unit.policy?.frozen
  const killSwitch = !!unit.policy?.kill_switch
  const utilization = Math.round((row.utilization ?? 0) * 100)
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${unit.label}</strong>
          <div class="command-card-sub">${unit.unit_id}</div>
        </div>
        <span class="command-chip ${toneClass(utilization > 100 ? 'bad' : utilization > 70 ? 'warn' : 'ok')}">${utilization}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span>Headcount Cap</span><span>${row.headcount_cap ?? 0}</span>
        <span>Ops</span><span>${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span>Autonomy</span><span>${unit.policy?.autonomy_level ?? 'n/a'}</span>
        <span>Frozen</span><span>${frozen ? 'yes' : 'no'}</span>
        <span>Kill Switch</span><span>${killSwitch ? 'on' : 'off'}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? 'Applying…' : frozen ? 'Unfreeze' : 'Freeze'}
        </button>
        <button class="control-btn ghost" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
          ${actionDisabled(killKey) ? 'Applying…' : killSwitch ? 'Clear Kill Switch' : 'Enable Kill Switch'}
        </button>
      </div>
    </article>
  `
}

function SwarmChecklistCard({ item }: { item: CommandPlaneSwarmChecklistItem }) {
  return html`
    <article class="command-guide-card ${toneClass(item.status)}">
      <div class="command-guide-head">
        <strong>${item.title}</strong>
        <span class="command-chip ${toneClass(item.status)}">${item.status}</span>
      </div>
      <p>${item.detail}</p>
      <div class="command-card-foot">Next tool: ${item.next_tool}</div>
    </article>
  `
}

function SwarmBlockerCard({ blocker }: { blocker: CommandPlaneSwarmBlocker }) {
  return html`
    <article class="command-alert ${toneClass(blocker.severity)}">
      <div class="command-card-head">
        <strong>${blocker.title}</strong>
        <span class="command-chip ${toneClass(blocker.severity)}">${blocker.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${blocker.code}</span>
        <span>next ${blocker.next_tool}</span>
      </div>
      <p>${blocker.detail}</p>
    </article>
  `
}

function SwarmWorkerCard({ worker }: { worker: CommandPlaneSwarmWorker }) {
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="command-card-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(worker.joined ? (worker.heartbeat_fresh ? 'ok' : 'warn') : 'bad')}">
          ${worker.status}
        </span>
      </div>
      <div class="command-card-grid">
        <span>Joined</span><span>${worker.joined ? 'yes' : 'no'}</span>
        <span>Live</span><span>${worker.live_presence ? 'yes' : 'no'}</span>
        <span>Completed</span><span>${worker.completed ? 'yes' : 'no'}</span>
        <span>Task</span><span>${worker.current_task ?? worker.bound_task_id ?? 'none'}</span>
        <span>Task Title</span><span>${worker.bound_task_title ?? 'n/a'}</span>
        <span>Task Status</span><span>${worker.bound_task_status ?? 'n/a'}</span>
        <span>Heartbeat</span><span>${worker.heartbeat_age_sec != null ? `${Math.round(worker.heartbeat_age_sec)}s` : worker.heartbeat_fresh ? 'completed-cleanly' : 'n/a'}</span>
        <span>Squad</span><span>${worker.squad_member ? 'yes' : 'no'}</span>
        <span>Detachment</span><span>${worker.detachment_member ? 'yes' : 'no'}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${worker.lane}</span>
        <span class="command-tag ${worker.current_task_matches_run ? 'ok' : 'warn'}">current_task</span>
        <span class="command-tag ${worker.claim_marker_seen ? 'ok' : 'warn'}">claim</span>
        <span class="command-tag ${worker.done_marker_seen ? 'ok' : 'warn'}">done</span>
        <span class="command-tag ${worker.final_marker_seen ? 'ok' : 'warn'}">final</span>
      </div>
      ${worker.last_message
        ? html`<div class="command-card-foot">${relativeTime(worker.last_message.timestamp)} · ${worker.last_message.content}</div>`
        : null}
    </article>
  `
}

function WarRoomSurface() {
  const summary = currentCommandPlaneSummary()
  const swarm = commandPlaneSwarm.value
  const snapshot = operatorSnapshot.value
  const sessionDigest = operatorSessionDigest.value
  const selectedSession = pickWarRoomSession()
  const chainOverlay = swarm?.operation
    ? commandPlaneChainSummary.value?.operations.find(
        overlay => overlay.operation.operation_id === swarm.operation?.operation_id,
      ) ?? null
    : null
  const swarmWorkers = swarm?.workers ?? []
  const sessionWorkers = sessionDigest?.worker_cards ?? []
  const workers =
    swarmWorkers.length > 0
      ? swarmWorkers.map(swarmWorkerView)
      : sessionWorkers.map(operatorWorkerView)
  const hasLiveRun = hasSwarmActivity()
  const pendingApprovals = summary?.decisions.summary?.pending ?? 0
  const pendingConfirms = snapshot?.pending_confirms ?? []
  const blockers = swarm?.blockers ?? []
  const recommendedActions = sessionDigest?.recommended_actions ?? []
  const attentionItems = sessionDigest?.attention_items ?? []
  const latestMessage = swarm?.recent_messages[0]?.timestamp ?? null
  const latestTrace = swarm?.recent_trace_events[0]?.timestamp ?? null
  const latestSignal = latestMessage ?? latestTrace ?? null
  const sessionSummary = selectedSession?.summary as Record<string, unknown> | undefined
  const workerExpected =
    swarm?.summary?.expected_workers
    ?? (typeof sessionSummary?.planned_worker_count === 'number' ? sessionSummary.planned_worker_count : undefined)
    ?? sessionDigest?.worker_cards.length
    ?? 0
  const workerJoined =
    swarm?.summary?.joined_workers
    ?? (typeof sessionSummary?.active_agent_count === 'number' ? sessionSummary.active_agent_count : undefined)
    ?? workers.length
  const stickyTone =
    blockers.length > 0 || pendingApprovals > 0 || pendingConfirms.length > 0
      ? 'warn'
      : hasLiveRun || selectedSession
        ? 'ok'
        : 'warn'
  const liveLanes = summary?.swarm_status?.lanes.filter((lane: CommandPlaneSwarmLane) => lane.present) ?? []

  useEffect(() => {
    void refreshOperatorSnapshot()
  }, [])

  useEffect(() => {
    if (!selectedSession?.session_id) return
    void refreshOperatorSessionDigest(selectedSession.session_id)
  }, [selectedSession?.session_id, snapshot, swarm?.detachment?.session_id])

  if (!hasLiveRun && !selectedSession) {
    if (commandPlaneSwarmLoading.value || operatorLoading.value) {
      return html`<div class="empty-state">live war room 불러오는 중…</div>`
    }
    return html`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${WarRoomJumpButton} label="작전 보기" surface="operations" />
          <${WarRoomJumpButton} label="스웜 보기" surface="swarm" />
          <${WarRoomJumpButton} label="개입 열기" />
          <${WarRoomJumpButton} label="제어 보기" surface="control" />
        </div>
      </section>
    `
  }

  return html`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${toneClass(stickyTone)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${swarm?.operation?.objective ?? selectedSession?.session_id ?? 'active run'}</strong>
            <div class="command-card-sub">
              ${swarm?.operation?.operation_id ?? 'operation 없음'}
              ${selectedSession?.session_id ? ` · session ${selectedSession.session_id}` : ''}
              ${swarm?.detachment?.detachment_id ? ` · detachment ${swarm.detachment.detachment_id}` : ''}
            </div>
          </div>
          <div class="command-action-row">
            <${WarRoomJumpButton}
              label="스웜 상세"
              surface="swarm"
              params=${{
                ...(swarm?.operation?.operation_id ? { operation_id: swarm.operation.operation_id } : {}),
                ...(swarm?.run_id ? { run_id: swarm.run_id } : {}),
              }}
            />
            <${WarRoomJumpButton} label="트레이스" surface="trace" />
            ${chainOverlay
              ? html`<${WarRoomJumpButton}
                  label="체인"
                  surface="chains"
                  params=${{ operation: chainOverlay.operation.operation_id }}
                />`
              : null}
            <${WarRoomJumpButton} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${workerJoined ?? 0}/${workerExpected ?? 0}</strong>
            <small>${swarm?.summary?.completed_workers ?? 0} 완료 · ${workers.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${swarm?.provider?.runtime_blocker ? 'blocked' : swarm?.provider?.provider_reachable ? 'ready' : selectedSession ? displayStatus(selectedSession.status) : 'check'}</strong>
            <small>slots ${swarm?.provider?.active_slots_now ?? 0}/${swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0} · ctx ${swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0}</small>
          </div>
          <div class="monitor-stat-card ${toneClass(blockers.length > 0 || pendingApprovals > 0 ? 'warn' : 'ok')}">
            <span>Pressure</span>
            <strong>${blockers.length + pendingApprovals + pendingConfirms.length}</strong>
            <small>blockers ${blockers.length} · approvals ${pendingApprovals} · confirms ${pendingConfirms.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${relativeTime(latestSignal)}</strong>
            <small>${latestMessage ? 'message' : latestTrace ? 'trace' : 'waiting'}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${liveLanes.length > 0
              ? html`
                  <${SwarmStoryboard} lanes=${liveLanes} />
                  <${SwarmHealthBar} lanes=${liveLanes} />
                `
              : selectedSession
                ? html`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${selectedSession.session_id}</strong>
                        <span class="command-chip ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : 'n/a'}</span>
                        <span>Elapsed</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>Remaining</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                      </div>
                    </article>
                  `
                : html`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${workers.length > 0
              ? html`<div class="command-card-stack">
                  ${workers.map(worker => html`<${WarRoomWorkerCard} worker=${worker} />`)}
                </div>`
              : html`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            ${swarm && swarm.recent_messages.length > 0
              ? html`<div class="command-trace-stack">
                  ${swarm.recent_messages.map(message => html`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${message.from}</strong>
                          <span class="command-chip">${relativeTime(message.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${message.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${message.content}</pre>
                    </article>
                  `)}
                </div>`
              : recommendedActions.length > 0 || attentionItems.length > 0
                ? html`<div class="command-card-stack">
                    ${recommendedActions.slice(0, 4).map(item => html`
                      <article class="command-guide-card ${warRoomRecommendationTone(item)}">
                        <div class="command-guide-head">
                          <strong>${item.action_type}</strong>
                          <span class="command-chip ${warRoomRecommendationTone(item)}">${item.target_type}</span>
                        </div>
                        <p>${item.reason}</p>
                      </article>
                    `)}
                    ${attentionItems.slice(0, 3).map(item => html`
                      <article class="command-alert ${toneClass(item.severity)}">
                        <div class="command-card-head">
                          <strong>${item.kind}</strong>
                          <span class="command-chip ${toneClass(item.severity)}">${item.severity}</span>
                        </div>
                        <p>${item.summary}</p>
                      </article>
                    `)}
                  </div>`
                : selectedSession?.recent_events && selectedSession.recent_events.length > 0
                  ? html`<div class="command-trace-stack">
                      ${selectedSession.recent_events.slice(0, 6).map((event, index) => html`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${index + 1}</strong>
                              <span class="command-chip">${selectedSession.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${prettyJson(event)}</pre>
                        </article>
                      `)}
                    </div>`
                  : html`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
            </div>
            ${swarm && swarm.recent_trace_events.length > 0
              ? html`<div class="command-trace-stack">
                  ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
                </div>`
              : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${blockers.length > 0
                ? blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)
                : html`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${pendingApprovals > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${pendingApprovals}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `
                : null}
              ${pendingConfirms.length > 0
                ? html`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${pendingConfirms.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${pendingConfirms.slice(0, 3).map((item: PendingConfirmation) => html`<span class="command-tag">${item.confirm_token}</span>`)}
                      </div>
                    </article>
                  `
                : null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${PanelSemanticDetails} panelId="command.warroom" compact=${true} />
            </div>
            <div class="command-card-stack">
              ${swarm?.operation
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.operation.objective}</strong>
                          <div class="command-card-sub">${swarm.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.operation.status))}">${swarm.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${swarm.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${swarm.operation.trace_id}</span>
                        <span>Autonomy</span><span>${swarm.operation.autonomy_level ?? 'n/a'}</span>
                        <span>Updated</span><span>${relativeTime(swarm.operation.updated_at)}</span>
                      </div>
                    </article>
                  `
                : null}
              ${swarm?.detachment
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${swarm.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${swarm.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(swarm.detachment.status))}">${swarm.detachment.status ?? 'active'}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${swarm.detachment.leader_id ?? 'unassigned'}</span>
                        <span>Roster</span><span>${swarm.detachment.roster.length}</span>
                        <span>Session</span><span>${swarm.detachment.session_id ?? 'none'}</span>
                        <span>Heartbeat</span><span>${deadlineLabel(swarm.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `
                : null}
              ${selectedSession
                ? html`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${selectedSession.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : 'n/a'}</span>
                        <span>Elapsed</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>Remaining</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                        <span>Done delta</span><span>${selectedSession.done_delta_total ?? 0}</span>
                      </div>
                    </article>
                  `
                : null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `
}

function SwarmSurface() {
  const swarm = commandPlaneSwarm.value
  const runId = dashboardSwarmRunId()
  const operationId = dashboardSwarmOperationId()
  const runtimeState = swarm?.provider?.runtime_blocker
    ? 'blocked'
    : swarm?.provider?.provider_reachable
      ? 'ready'
      : 'check'
  const actualSlots = swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0
  const expectedSlots = swarm?.provider?.expected_slots ?? 'n/a'
  const actualCtx = swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0
  const expectedCtx = swarm?.provider?.expected_ctx ?? 'n/a'
  return html`
    <div class="command-section-stack">
      <${SwarmPanel} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${commandPlaneSwarmLoading.value
            ? html`<div class="empty-state">Loading swarm live state…</div>`
            : commandPlaneSwarmError.value
              ? html`<div class="empty-state error">${commandPlaneSwarmError.value}</div>`
              : swarm
                ? html`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${swarm.run_id ?? runId ?? 'swarm-live'}</strong><small>${swarm.room_id ?? 'room 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${swarm.summary?.joined_workers ?? 0}/${swarm.summary?.expected_workers ?? 0}</strong><small>${swarm.summary?.live_workers ?? 0}개 가동 · ${swarm.summary?.completed_workers ?? 0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${runtimeState}</strong><small>slots ${actualSlots}/${expectedSlots} · ctx ${actualCtx}/${expectedCtx}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${swarm.summary?.pass_hot_concurrency ? '통과' : '확인 필요'}</strong><small>${swarm.provider?.slot_url ?? 'slot 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${swarm.summary?.pass_end_to_end ? '통과' : '확인 필요'}</strong><small>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${swarm.operation?.operation_id ?? operationId ?? '없음'}</span>
                      <span>분대</span><span>${swarm.squad?.label ?? '없음'}</span>
                      <span>실행체</span><span>${swarm.detachment?.detachment_id ?? '없음'}</span>
                      <span>예상 워커</span><span>${swarm.summary?.expected_workers ?? 0}명</span>
                      <span>최종 마커</span><span>${swarm.summary?.final_markers_seen ?? 0}</span>
                      <span>런타임 막힘</span><span>${swarm.provider?.runtime_blocker ?? '없음'}</span>
                      <span>추천 도구</span><span>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</span>
                    </div>
                    ${swarm.truth_notes.length > 0
                      ? html`<div class="command-tag-row">
                          ${swarm.truth_notes.map(note => html`<span class="command-tag">${note}</span>`)}
                        </div>`
                      : null}
                  `
                : html`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.checklist.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
              </div>`
            : html`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.workers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
              </div>`
            : html`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm?.provider
            ? html`
                <div class="command-card-grid">
                  <span>Provider</span><span>${swarm.provider.provider_base_url ?? 'n/a'}</span>
                  <span>Provider Reachable</span><span>${swarm.provider.provider_reachable == null ? 'n/a' : swarm.provider.provider_reachable ? 'yes' : 'no'}</span>
                  <span>Requested Model</span><span>${swarm.provider.provider_model_id ?? 'n/a'}</span>
                  <span>Actual Model</span><span>${swarm.provider.actual_model_id ?? 'n/a'}</span>
                  <span>Slot URL</span><span>${swarm.provider.slot_url ?? 'n/a'}</span>
                  <span>Expected Slots</span><span>${swarm.provider.expected_slots ?? 'n/a'}</span>
                  <span>Actual Slots</span><span>${swarm.provider.actual_slots ?? swarm.provider.total_slots ?? 0}</span>
                  <span>Expected Ctx</span><span>${swarm.provider.expected_ctx ?? 'n/a'}</span>
                  <span>Actual Ctx</span><span>${swarm.provider.actual_ctx ?? swarm.provider.ctx_per_slot ?? 0}</span>
                  <span>Active Now</span><span>${swarm.provider.active_slots_now ?? 0}</span>
                  <span>Peak Active</span><span>${swarm.provider.peak_active_slots ?? 0}</span>
                  <span>Sample Count</span><span>${swarm.provider.sample_count ?? 0}</span>
                  <span>Last Sample</span><span>${swarm.provider.last_sample_at ? relativeTime(swarm.provider.last_sample_at) : 'n/a'}</span>
                  <span>런타임 막힘</span><span>${swarm.provider.runtime_blocker ?? 'none'}</span>
                  <span>Doctor Checked</span><span>${swarm.provider.checked_at ? relativeTime(swarm.provider.checked_at) : 'n/a'}</span>
                </div>
                ${swarm.provider.detail
                  ? html`<div class="command-card-sub">${swarm.provider.detail}</div>`
                  : null}
                ${swarm.provider.timeline.length > 0
                  ? html`<div class="command-trace-stack">
                      ${swarm.provider.timeline.slice(-12).map(sample => html`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${sample.active_slots} active</strong>
                              <span class="command-chip">${relativeTime(sample.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${sample.active_slot_ids.join(', ') || 'none'}</div>
                          </div>
                        </article>
                      `)}
                    </div>`
                  : html`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `
            : html`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.blockers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
              </div>`
            : html`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${PanelSemanticDetails} panelId="command.swarm" compact=${true} />
          </div>
          ${swarm && swarm.recent_messages.length > 0
            ? html`<div class="command-trace-stack">
                ${swarm.recent_messages.map(message => html`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${message.from}</strong>
                        <span class="command-chip">${relativeTime(message.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${message.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${message.content}</pre>
                  </article>
                `)}
              </div>`
            : html`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
          </div>
          ${swarm && swarm.recent_trace_events.length > 0
            ? html`<div class="command-trace-stack">
                ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
              </div>`
            : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `
}

function OperationsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${PanelSemanticDetails} panelId="command.operations" compact=${true} />
        </div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${PanelSemanticDetails} panelId="command.operations" compact=${true} />
        </div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `
}

function ChainsSurface() {
  const summary = commandPlaneChainSummary.value
  const overlays = summary?.operations ?? []
  const focusedOperationId = commandPlaneChainFocusOperationId.value
  const selectedOverlay =
    overlays.find(item => item.operation.operation_id === focusedOperationId)
    ?? overlays[0]
    ?? null
  const selectedRunId = selectedOverlay?.operation.chain?.run_id ?? null
  const run = commandPlaneChainRun.value?.run ?? selectedOverlay?.preview_run ?? null
  const isPreviewRun = !commandPlaneChainRun.value?.run && !!selectedOverlay?.preview_run

  useEffect(() => {
    if (selectedRunId) {
      void loadCommandPlaneChainRun(selectedRunId)
    } else {
      clearCommandPlaneChainRun()
    }
  }, [selectedRunId])

  return html`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${PanelSemanticDetails} panelId="command.chains" compact=${true} />
        </div>
        <article class="command-guide-card ${chainStatusTone(summary?.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${chainStatusTone(summary?.connection.status)}">${summary?.connection.status ?? 'disconnected'}</span>
          </div>
          <p>${summary?.connection.message ?? 'Chain summary is aggregated through the MASC proxy.'}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${summary?.connection.base_url ?? 'n/a'}</span>
            <span>Linked Ops</span><span>${summary?.summary?.linked_operations ?? 0}</span>
            <span>Active Chains</span><span>${summary?.summary?.active_chains ?? 0}</span>
            <span>Recent Failures</span><span>${summary?.summary?.recent_failures ?? 0}</span>
            <span>Last Event</span><span>${relativeTime(summary?.summary?.last_history_event_at)}</span>
          </div>
        </article>

        ${commandPlaneChainError.value
          ? html`<div class="empty-state error">${commandPlaneChainError.value}</div>`
          : null}

        ${commandPlaneChainLoading.value && !summary
          ? html`<div class="empty-state">Loading chain overlays…</div>`
          : overlays.length > 0
            ? html`
                <div class="command-chain-list">
                  ${overlays.map(overlay => html`
                    <${ChainOperationListItem}
                      overlay=${overlay}
                      selected=${selectedOverlay?.operation.operation_id === overlay.operation.operation_id}
                      onSelect=${() => focusCommandPlaneChainOperation(overlay.operation.operation_id)}
                    />
                  `)}
                </div>
              `
            : html`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${summary?.recent_history.length ?? 0}</span>
          </div>
          ${summary && summary.recent_history.length > 0
            ? html`
                <div class="command-card-stack">
                  ${summary.recent_history.slice(0, 6).map(item => html`<${ChainHistoryRow} item=${item} />`)}
                </div>
              `
            : html`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${PanelSemanticDetails} panelId="command.chains" compact=${true} />
        </div>
        ${selectedOverlay
          ? html`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${selectedOverlay.operation.objective}</strong>
                    <div class="command-card-sub">${selectedOverlay.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${chainStatusTone(selectedOverlay.operation.chain?.status)}">
                    ${selectedOverlay.operation.chain?.status ?? selectedOverlay.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${selectedOverlay.operation.chain?.kind ?? 'chain_dsl'}</span>
                  <span>Chain ID</span><span>${selectedOverlay.operation.chain?.chain_id ?? 'goal-driven'}</span>
                  <span>Run ID</span><span>${selectedRunId ?? 'not materialized'}</span>
                  <span>Progress</span><span>${formatPercent(selectedOverlay.runtime?.progress)}</span>
                  <span>Elapsed</span><span>${formatElapsed(selectedOverlay.runtime?.elapsed_sec)}</span>
                  <span>Updated</span><span>${relativeTime(selectedOverlay.operation.chain?.last_sync_at ?? selectedOverlay.operation.updated_at)}</span>
                </div>
                ${selectedOverlay.operation.chain?.goal
                  ? html`<div class="command-card-foot">${selectedOverlay.operation.chain.goal}</div>`
                  : null}
              </article>

              ${selectedOverlay.mermaid
                ? html`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${selectedOverlay.operation.chain?.chain_id ?? 'graph'}</span>
                      </div>
                      <${MermaidGraph} source=${selectedOverlay.mermaid} />
                    </div>
                  `
                : html`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${run?.success === false ? 'bad' : 'ok'}">
                    ${run
                      ? (run.success === false ? 'failed' : isPreviewRun ? 'preview' : 'captured')
                      : 'pending'}
                  </span>
                </div>
                ${commandPlaneChainRunLoading.value
                  ? html`<div class="empty-state">Loading run detail…</div>`
                  : commandPlaneChainRunError.value
                    ? html`<div class="empty-state error">${commandPlaneChainRunError.value}</div>`
                    : run && run.nodes.length > 0
                      ? html`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${run.chain_id}</span>
                            <span>Run</span><span>${run.run_id ?? 'preview only'}</span>
                            <span>Duration</span><span>${run.duration_ms != null ? `${run.duration_ms}ms` : 'n/a'}</span>
                            <span>Nodes</span><span>${run.nodes.length}</span>
                          </div>
                          ${isPreviewRun
                            ? html`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`
                            : null}
                          <div class="command-card-stack">
                            ${run.nodes.map(node => html`<${ChainRunNodeRow} node=${node} />`)}
                          </div>
                        `
                      : html`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `
          : html`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `
}

function TopologySurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${PanelSemanticDetails} panelId="command.topology" compact=${true} />
      </div>
      ${snapshot && snapshot.topology.units.length > 0
        ? html`${snapshot.topology.units.map(node => html`<${TopologyNode} node=${node} />`)}`
        : html`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `
}

function AlertsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${PanelSemanticDetails} panelId="command.alerts" compact=${true} />
      </div>
      ${snapshot && snapshot.alerts.alerts.length > 0
        ? html`<div class="command-card-stack">
            ${snapshot.alerts.alerts.map(alert => html`<${AlertCard} alert=${alert} />`)}
          </div>`
        : html`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `
}

function TraceSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
      </div>
      ${snapshot && snapshot.traces.events.length > 0
        ? html`<div class="command-trace-stack">
            ${snapshot.traces.events.map(event => html`<${TraceRow} event=${event} />`)}
          </div>`
        : html`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `
}

function ControlSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${PanelSemanticDetails} panelId="command.control" compact=${true} />
        </div>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${PanelSemanticDetails} panelId="command.control" compact=${true} />
        </div>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `
}

function SurfaceBody() {
  if (commandPlaneSurface.value === 'warroom') {
    return html`<${WarRoomSurface} />`
  }
  if (commandPlaneSurface.value === 'summary') {
    return html`<${SummarySurface} />`
  }
  if (commandPlaneSurface.value === 'swarm') {
    return html`<${SwarmSurface} />`
  }
  if (!commandPlaneSnapshot.value) {
    return html`<${DetailLoadingState} />`
  }
  switch (commandPlaneSurface.value) {
    case 'chains':
      return html`<${ChainsSurface} />`
    case 'topology':
      return html`<${TopologySurface} />`
    case 'alerts':
      return html`<${AlertsSurface} />`
    case 'trace':
      return html`<${TraceSurface} />`
    case 'control':
      return html`<${ControlSurface} />`
    case 'operations':
    default:
      return html`<${OperationsSurface} />`
  }
}

export function Command() {
  useEffect(() => {
    void refreshCommandPlaneCurrentSurface()
    void refreshCommandPlaneChainSummary()
    void refreshCommandPlaneHelp()
    void refreshCommandPlaneSwarm()
  }, [])

  useEffect(() => {
    if (route.value.tab !== 'command') return
    const requestedSurface = route.value.params.surface
    const requestedOperation = route.value.params.operation
    const workflowContext = workflowContextForRoute(route.value)
    if (isCommandSurface(requestedSurface)) {
      setCommandPlaneSurface(requestedSurface)
    }
    else if (workflowContext) {
      const suggestedSurface = commandSurfaceForContext(workflowContext)
      if (isCommandSurface(suggestedSurface)) {
        setCommandPlaneSurface(suggestedSurface)
      }
    }
    else if (!requestedSurface) {
      setCommandPlaneSurface('warroom')
    }
    if (requestedOperation) {
      focusCommandPlaneChainOperation(requestedOperation)
    }
    if (requestedSurface === 'swarm' || requestedSurface === 'warroom' || commandPlaneSurface.value === 'warroom') {
      void refreshCommandPlaneSwarm()
    }
    if (requestedSurface === 'warroom' || commandPlaneSurface.value === 'warroom') {
      void refreshOperatorSnapshot()
    }
  }, [
    route.value.tab,
    route.value.params.surface,
    route.value.params.operation,
    route.value.params.operation_id,
    route.value.params.run_id,
    route.value.params.source,
    route.value.params.action_type,
    route.value.params.target_type,
    route.value.params.target_id,
    route.value.params.focus_kind,
  ])

  useEffect(() => {
    let refreshTimer: ReturnType<typeof window.setTimeout> | null = null
    const scheduleRefresh = () => {
      if (refreshTimer) return
      refreshTimer = window.setTimeout(() => {
        refreshTimer = null
        void refreshCommandPlaneCurrentSurface()
        void refreshCommandPlaneChainSummary()
        if (commandPlaneSurface.value === 'swarm' || commandPlaneSurface.value === 'warroom') {
          void refreshCommandPlaneSwarm()
        }
        if (commandPlaneSurface.value === 'warroom') {
          void refreshOperatorSnapshot()
        }
      }, 250)
    }

    const es = new EventSource(chainEventsUrl())
    const listeners = CHAIN_SSE_EVENT_TYPES.map(type => {
      const handler = () => scheduleRefresh()
      es.addEventListener(type, handler)
      return { type, handler }
    })
    es.onerror = () => {
      scheduleRefresh()
    }

    return () => {
      listeners.forEach(({ type, handler }) => {
        es.removeEventListener(type, handler)
      })
      es.close()
      if (refreshTimer) {
        window.clearTimeout(refreshTimer)
      }
    }
  }, [])

  return html`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${() => {
              void fire(() => runCommandPlaneDispatchTick())
            }}
            disabled=${actionDisabled('dispatch:tick')}
          >
            ${actionDisabled('dispatch:tick') ? '정리 중...' : 'Tick 실행'}
          </button>
          <button
            class="control-btn ghost"
            onClick=${() => {
              void refreshCommandPlaneCurrentSurface()
              void refreshCommandPlaneChainSummary()
              void refreshCommandPlaneSwarm()
              if (commandPlaneSurface.value === 'warroom') {
                void refreshOperatorSnapshot()
              }
            }}
            disabled=${commandPlaneLoading.value}
          >
            ${commandPlaneLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
      </div>

      ${commandPlaneError.value
        ? html`<div class="empty-state error">${commandPlaneError.value}</div>`
        : null}
      ${commandPlaneActionError.value
        ? html`<div class="empty-state error">${commandPlaneActionError.value}</div>`
        : null}
      <${SurfaceSemanticIntro} surfaceId="command" />
      <${CommandWorkflowBanner} />
      ${commandPlaneSurface.value === 'warroom' ? null : html`<${CommandEntryStrip} />`}
      <${SurfaceTabs} />
      <${SurfaceBody} />
    </section>
  `
}
