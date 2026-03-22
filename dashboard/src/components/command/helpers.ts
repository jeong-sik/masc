import type {
  ChainHistoryEventSummary,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpStep,
  CommandPlaneSurface,
  OperatorSessionSnapshot,
  Task,
} from '../../types'
import {
  commandPlaneActionBusy,
  commandPlaneChainFocusOperationId,
  commandPlaneChainSummary,
  commandPlaneHelp,
  commandPlaneSummary,
  commandPlaneSwarm,
} from '../../command-store'
import { operatorSnapshot } from '../../operator-store'
import { route } from '../../router'
import type { DashboardWorkflowContext } from '../../workflow-context'
import { relativeTime, formatElapsed } from '../../lib/format-time'
import { toneClass, toneBorder, toneBg, chainStatusTone, sessionStatusTone, expiryTone } from '../../lib/tone'
import { prettyJson, displayStatus } from '../../lib/status-label'

// ── Pure helpers ──────────────────────────────

export { relativeTime, formatElapsed, toneClass, toneBorder, toneBg, chainStatusTone, sessionStatusTone, expiryTone, prettyJson, displayStatus }

export function alertBorderTone(tone: string): string {
  if (tone === 'warn') return 'border-[rgba(251,191,36,0.26)]'
  if (tone === 'bad') return 'border-[rgba(248,113,113,0.3)]'
  return ''
}

export function deadlineLabel(iso?: string | null): string {
  if (!iso) return '정보 없음'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.round((ts - Date.now()) / 1000)
  if (deltaSec <= 0) return '기한 지남'
  if (deltaSec < 60) return `${deltaSec}초 후`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}분 후`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}시간 후`
  return `${Math.round(deltaSec / 86400)}일 후`
}

type MermaidApi = typeof import('mermaid')['default']

let mermaidConfigured = false
export let mermaidRenderCount = 0

export function incrementMermaidRenderCount(): number {
  return ++mermaidRenderCount
}

let mermaidPromise: Promise<MermaidApi> | null = null

export async function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(module => module.default)
  }
  const mermaid = await mermaidPromise
  if (mermaidConfigured) return mermaid
  mermaid.initialize({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'strict',
  })
  mermaidConfigured = true
  return mermaid
}

export function formatPercent(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '정보 없음'
  return `${Math.round(value * 100)}%`
}

export function clampPercent(value?: number | null): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

export function ratioPercent(part?: number | null, whole?: number | null): number {
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

export function gaugeStyle(percent: number, color: string): string {
  const safePercent = clampPercent(percent)
  const angle = Math.max(10, Math.round((safePercent / 100) * 360))
  return `--gauge-angle:${angle}deg;--gauge-color:${color};`
}

export function historySummary(history?: ChainHistoryEventSummary | null): string {
  if (!history) return '최근 체인 이력이 없습니다'
  const pieces = [history.event]
  if (typeof history.duration_ms === 'number') pieces.push(`${history.duration_ms}ms`)
  if (typeof history.tokens === 'number') pieces.push(`토큰 ${history.tokens}`)
  if (history.message) pieces.push(history.message)
  return pieces.join(' · ')
}

// ── Constants ─────────────────────────────────

export type CommandSurfaceGroup = 'status' | 'history' | 'control'

export const COMMAND_SURFACE_GROUPS: Array<{ id: CommandSurfaceGroup; label: string }> = [
  { id: 'status', label: '현황' },
  { id: 'history', label: '이력' },
  { id: 'control', label: '통제' },
]

export const COMMAND_SURFACE_META: Array<{ id: CommandPlaneSurface; label: string; group: CommandSurfaceGroup }> = [
  { id: 'warroom', label: '워룸', group: 'status' },
  { id: 'summary', label: '요약', group: 'status' },
  { id: 'topology', label: '토폴로지', group: 'status' },
  { id: 'orchestra', label: '오케스트라', group: 'status' },
  { id: 'swarm', label: '스웜', group: 'status' },
  { id: 'operations', label: '작전', group: 'history' },
  { id: 'trace', label: '트레이스', group: 'history' },
  { id: 'chains', label: '체인', group: 'history' },
  { id: 'control', label: '제어', group: 'control' },
  { id: 'alerts', label: '알림', group: 'control' },
]
const COMMAND_SURFACES: CommandPlaneSurface[] = COMMAND_SURFACE_META.map(item => item.id)
export const CHAIN_SSE_EVENT_TYPES = ['chain_start', 'node_start', 'node_complete', 'chain_complete', 'chain_error']

export const COMMAND_SURFACE_GUIDE: Record<CommandPlaneSurface, { title: string; description: string }> = {
  warroom: {
    title: '실시간 워룸',
    description: '실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다.',
  },
  operations: {
    title: '현재 작전 상세',
    description: '활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다.',
  },
  orchestra: {
    title: '룸 오케스트라 맵',
    description: '룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다.',
  },
  swarm: {
    title: '스웜 실행 흐름',
    description: '레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다.',
  },
  chains: {
    title: '체인 런타임',
    description: '체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다.',
  },
  topology: {
    title: '지휘 계층',
    description: '실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다.',
  },
  alerts: {
    title: '경보 모음',
    description: '지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다.',
  },
  trace: {
    title: '최근 트레이스',
    description: '작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다.',
  },
  control: {
    title: '승인과 제어',
    description: '결정 승인과 유닛 제어를 실제로 수행하는 표면입니다.',
  },
  summary: {
    title: '지휘 요약',
    description: '전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다.',
  },
}

export function isCommandSurface(value: string | undefined): value is CommandPlaneSurface {
  return !!value && COMMAND_SURFACES.includes(value as CommandPlaneSurface)
}

// ── Route helpers (signal-dependent) ──────────

function inheritedWorkflowRouteParams(): Record<string, string> {
  const params = route.value.params
  if (params.source !== 'mission' && params.source !== 'execution') return {}
  return {
    source: params.source,
    ...(params.action_type ? { action_type: params.action_type } : {}),
    ...(params.target_type ? { target_type: params.target_type } : {}),
    ...(params.target_id ? { target_id: params.target_id } : {}),
    ...(params.focus_kind ? { focus_kind: params.focus_kind } : {}),
    ...(params.operation_id ? { operation_id: params.operation_id } : {}),
  }
}

export function surfaceRouteParams(surface: CommandPlaneSurface): Record<string, string> {
  const inherited = inheritedWorkflowRouteParams()
  const base = { ...inherited, section: 'command' }
  const swarmRunId = dashboardSwarmRunId()
  const swarmOperationId = dashboardSwarmOperationId()
  if (surface === 'operations') return base
  if (surface === 'chains') {
    const operationId = commandPlaneChainFocusOperationId.value
    return operationId ? { ...base, surface, operation: operationId } : { ...base, surface }
  }
  if (surface === 'swarm' || surface === 'warroom' || surface === 'orchestra') {
    return {
      ...base,
      surface,
      ...(swarmRunId ? { run_id: swarmRunId } : {}),
      ...(swarmOperationId ? { operation_id: swarmOperationId } : {}),
    }
  }
  return { ...base, surface }
}

export function chainEventsUrl(): string {
  const query = new URLSearchParams(window.location.search)
  const params = new URLSearchParams()
  const agent = query.get('agent') ?? query.get('agent_name')
  const token = query.get('token')
  if (agent) params.set('agent', agent)
  if (token) params.set('token', token)
  return params.toString() ? `/api/v1/chains/events?${params.toString()}` : '/api/v1/chains/events'
}

export function unitKindLabel(kind: string): string {
  switch (kind) {
    case 'company':
      return '중대'
    case 'platoon':
      return '소대'
    case 'squad':
      return '분대'
    case 'agent':
      return '에이전트'
    default:
      return kind
  }
}

export function actionDisabled(key: string): boolean {
  return commandPlaneActionBusy.value === key
}

export function currentCommandPlaneSummary() {
  return commandPlaneSummary.value
}

export function currentSurfaceRecommendation(surface: CommandPlaneSurface): {
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
        reason: '실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다.',
      }
    case 'operations':
      return {
        tool: 'masc_operation_status',
        reason: `활성 작전 ${summary?.operations.summary?.active ?? 0}개와 의존 관계를 먼저 확인합니다.`,
      }
    case 'swarm':
      return {
        tool: swarm?.recommended_next_tool ?? summary?.swarm_status?.recommended_next_action?.tool ?? 'masc_observe_traces',
        reason: summary?.swarm_status?.recommended_next_action?.reason ?? '레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다.',
      }
    case 'orchestra':
      return {
        tool: 'masc_operator_snapshot',
        reason: '룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다.',
      }
    case 'chains':
      return {
        tool: chainSummary?.operations[0]?.preview_run?.chain_id ? 'masc_chain_run_get' : 'masc_chain_snapshot',
        reason: '체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다.',
      }
    case 'topology':
      return {
        tool: 'masc_observe_topology',
        reason: '이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다.',
      }
    case 'alerts':
      return {
        tool: 'masc_observe_alerts',
        reason: '경보에서 먼저 문제가 된 유닛과 작전을 고릅니다.',
      }
    case 'trace':
      return {
        tool: 'masc_observe_traces',
        reason: '트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다.',
      }
    case 'control':
      return {
        tool: 'masc_operator_action',
        reason: '승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다.',
      }
    case 'summary':
    default:
      return {
        tool: 'masc_observe_operations',
        reason: '요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다.',
      }
  }
}

export function summaryHighlightKey(context: DashboardWorkflowContext | null): string | null {
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

export function swarmFocusKey(context: DashboardWorkflowContext | null): string | null {
  const focus = context?.focus_kind?.toLowerCase() ?? ''
  if (!focus) return null
  if (focus.includes('stale_data') || focus.includes('leader_offline') || focus.includes('roster_offline') || focus.includes('managed')) {
    return 'recommendation'
  }
  if (focus.includes('gap')) return 'gaps'
  return null
}

// ── Dashboard location helpers ────────────────

export function dashboardActorName(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  const value = params.get('agent') ?? params.get('agent_name')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function dashboardLocationParams(): URLSearchParams {
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

export function dashboardSwarmRunId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('run_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function dashboardSwarmOperationId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('operation_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function lastSeenAgeSeconds(iso?: string | null): number | null {
  if (!iso) return null
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return null
  return Math.max(0, Math.round((Date.now() - ts) / 1000))
}

export function isActiveTask(task: Task): boolean {
  return task.status === 'claimed' || task.status === 'in_progress'
}

export function findHelpStep(toolName: string): CommandPlaneHelpStep | null {
  const help = commandPlaneHelp.value
  if (!help) return null
  for (const path of help.golden_paths) {
    const matched = path.steps.find(step => step.tool === toolName)
    if (matched) return matched
  }
  return null
}

export function findHelpPath(pathId: string): CommandPlaneHelpPath | null {
  return commandPlaneHelp.value?.golden_paths.find(path => path.id === pathId) ?? null
}

export function relevantPitfalls(ids: string[]): CommandPlaneHelpPitfall[] {
  const help = commandPlaneHelp.value
  if (!help) return []
  const wanted = new Set(ids)
  return help.pitfalls.filter(pitfall => wanted.has(pitfall.id))
}

export async function fire(action: () => Promise<void>) {
  try {
    await action()
  } catch {
    // Error state is already captured in the store.
  }
}

export function normalizedStatus(value?: string | null): string {
  return value?.trim().toLowerCase() ?? ''
}

export function hasSwarmActivity(): boolean {
  const swarm = commandPlaneSwarm.value
  if (!swarm) return false
  const hasWorkerEvidence = swarm.workers.some(worker =>
    worker.joined
    || worker.live_presence
    || worker.completed
    || worker.current_task_matches_run
    || worker.heartbeat_fresh
    || worker.claim_marker_seen
    || worker.done_marker_seen
    || worker.final_marker_seen
    || !!worker.current_task
    || !!worker.bound_task_id
    || !!worker.last_message,
  )
  return Boolean(
    swarm.operation?.operation_id
    || swarm.detachment?.detachment_id
    || (swarm.summary?.joined_workers ?? 0) > 0
    || (swarm.summary?.live_workers ?? 0) > 0
    || (swarm.summary?.current_task_bound ?? 0) > 0
    || (swarm.summary?.fresh_heartbeats ?? 0) > 0
    || (swarm.summary?.claim_markers_seen ?? 0) > 0
    || (swarm.summary?.done_markers_seen ?? 0) > 0
    || (swarm.summary?.final_markers_seen ?? 0) > 0
    || hasWorkerEvidence
    || swarm.recent_messages.length > 0
    || swarm.recent_trace_events.length > 0,
  )
}

export function isSessionLive(session: OperatorSessionSnapshot): boolean {
  const normalized = normalizedStatus(session.status)
  return normalized === 'active' || normalized === 'running'
}

export function pickWarRoomSession(): OperatorSessionSnapshot | null {
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
